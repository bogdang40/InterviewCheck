import { useCallback, useEffect, useRef, useState } from "react"
import { useSearchParams } from "next/navigation"
import { message } from "./api"
import { type ApiError, isAccessDenied } from "./http"
import { onAssignmentChange } from "./assignmentChanges"
import { fetchAssignmentQueue, type AssignmentQueueFilters, type AssignmentQueueResponse } from "./sessionAssignment"

export type QueueMode = "me" | "high" | "unassigned" | "overdue" | "soon"
const FILTERS: Record<QueueMode, AssignmentQueueFilters> = {
  me: { assignee: "me" }, high: { priority: "high" }, unassigned: { assignee: "unassigned" },
  overdue: { due: "overdue" }, soon: { due: "soon" },
}
const MAX_TIMEOUT = 2_147_483_647
type Snapshot = { key: string; data?: AssignmentQueueResponse; error?: string; deadline?: number; denied?: boolean }
type Notice = { key: string; error?: string }

function queueMode(value: string | null): QueueMode {
  return value && Object.hasOwn(FILTERS, value) ? value as QueueMode : "me"
}
function queuePage(value: string | null) {
  const page = Number(value)
  return Number.isSafeInteger(page) && page > 0 && page <= 2147483647 ? page : 1
}
function navigate(mode: QueueMode, page: number, replace = false) {
  const url = new URL(window.location.href)
  if (mode === "me") url.searchParams.delete("queue")
  else url.searchParams.set("queue", mode)
  if (page === 1) url.searchParams.delete("queue_page")
  else url.searchParams.set("queue_page", String(page))
  if (url.href === window.location.href) return
  if (replace) window.history.replaceState(null, "", url)
  else window.history.pushState(null, "", url)
}

export function useAssignmentQueue(isFrozen: () => boolean, beforeBackgroundUpdate: () => void,
  onAccessDenied: () => void) {
  const params = useSearchParams()
  const mode = queueMode(params.get("queue"))
  const requestedPage = queuePage(params.get("queue_page"))
  const [generation, setGeneration] = useState(0)
  const key = `${mode}/${requestedPage}/${generation}`
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null)
  const latest = useRef<Snapshot | null>(null)
  const clampedPage = useRef<string | null>(null)
  const cancel = useRef<(() => void) | undefined>(undefined)
  const revoke = useRef<((error: ApiError) => void) | undefined>(undefined)
  const resume = useRef<(() => void) | undefined>(undefined)
  const resumeIfDeferred = useCallback(() => resume.current?.(), [])
  const [notice, setNotice] = useState<Notice | null>(null)

  useEffect(() => {
    const controller = new AbortController()
    const pathname = window.location.pathname
    let reading = false
    let queued = false
    let deferred = false
    let timer: number | undefined
    let scheduled: number | undefined
    function defer() {
      deferred = true
      setNotice(old => old?.key === key && !old.error ? old : { key })
    }
    function current() {
      const url = new URL(window.location.href)
      return !controller.signal.aborted && url.pathname === pathname && queueMode(url.searchParams.get("queue")) === mode
        && queuePage(url.searchParams.get("queue_page")) === requestedPage
    }
    function signal() {
      if (!current() || document.visibilityState === "hidden") return
      window.clearTimeout(timer)
      if (isFrozen()) { defer(); return }
      if (reading) { queued = true; return }
      if (scheduled === undefined) scheduled = window.setTimeout(() => {
        scheduled = undefined
        void read(true)
      }, 32)
    }
    function arm(deadline?: number) {
      window.clearTimeout(timer)
      if (deadline === undefined || document.visibilityState === "hidden") return
      const delay = Math.max(1, Math.ceil(deadline - performance.now()))
      timer = window.setTimeout(delay > MAX_TIMEOUT ? () => arm(deadline) : signal, Math.min(delay, MAX_TIMEOUT))
    }
    async function read(background: boolean) {
      if (!current() || (background && document.visibilityState === "hidden")) return
      if (background && isFrozen()) { defer(); return }
      reading = true
      try {
        const result = await fetchAssignmentQueue({ ...FILTERS[mode], page: requestedPage, limit: 12 }, controller.signal)
        if (!current()) return
        if (background && isFrozen()) { defer(); return }
        if (background) beforeBackgroundUpdate()
        const next: Snapshot = {
          key: `${mode}/${result.page}/${generation}`, data: result,
          deadline: result.next_transition_ms === null ? undefined : performance.now() + result.next_transition_ms,
        }
        latest.current = next
        deferred = false
        setNotice(null)
        setSnapshot(next)
        if (result.page !== requestedPage) {
          clampedPage.current = next.key
          navigate(mode, result.page, true)
        }
        else arm(next.deadline)
      } catch (err) {
        if (!current()) return
        queued = false // A failed background read waits for a new signal or an explicit refresh.
        if (isAccessDenied(err)) {
          deny(err)
        } else if (background && latest.current?.key === key && latest.current.data) {
          if (isFrozen()) defer()
          else setNotice({ key, error: message(err) })
        } else {
          const failure = { key, error: message(err) }
          latest.current = failure
          setSnapshot(failure)
        }
      } finally {
        reading = false
        if (queued && current()) { queued = false; signal() }
      }
    }
    function visible() {
      if (document.visibilityState === "hidden") {
        window.clearTimeout(timer)
        window.clearTimeout(scheduled)
        scheduled = undefined
      } else if (!reading || latest.current?.key === key) signal()
    }
    function stop() {
      controller.abort()
      window.clearTimeout(timer)
      window.clearTimeout(scheduled)
    }
    function deny(error: ApiError) {
      stop()
      const denied = { key, denied: true, error: message(error) }
      latest.current = denied
      setSnapshot(denied)
      setNotice(null)
      onAccessDenied()
    }
    cancel.current = stop
    revoke.current = deny
    resume.current = () => {
      if (!deferred || isFrozen()) return
      deferred = false
      signal()
    }
    const unsubscribe = onAssignmentChange(signal)
    document.addEventListener("visibilitychange", visible)
    window.addEventListener("pageshow", visible)
    // A server-clamped page already supplied its snapshot before the URL changed.
    if (clampedPage.current === key && latest.current?.key === key && latest.current.data) arm(latest.current.deadline)
    else void read(false)
    clampedPage.current = null
    return () => {
      stop()
      unsubscribe()
      document.removeEventListener("visibilitychange", visible)
      window.removeEventListener("pageshow", visible)
      cancel.current = undefined
      revoke.current = undefined
      resume.current = undefined
    }
  }, [mode, requestedPage, generation, key, isFrozen, beforeBackgroundUpdate, onAccessDenied])

  function refresh() { cancel.current?.(); setGeneration(n => n + 1) }
  function changePage(nextMode: QueueMode, nextPage: number) { cancel.current?.(); navigate(nextMode, nextPage) }
  const current = snapshot?.key === key ? snapshot : null
  return {
    key, mode, requestedPage, data: current?.data, error: current?.error, previousData: snapshot?.data,
    loading: !current, denied: !!current?.denied, notice: notice?.key === key ? notice : null, refresh, changePage,
    denyAccess: (error: ApiError) => revoke.current?.(error), resumeIfDeferred,
  }
}
