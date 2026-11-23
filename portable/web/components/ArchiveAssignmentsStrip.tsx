"use client"

import Link from "next/link"
import { useSearchParams } from "next/navigation"
import { type FormEvent, useEffect, useId, useMemo, useRef, useState } from "react"
import { ArrowRight, RefreshCw, Trash2, UserCheck } from "lucide-react"
import { message } from "@/lib/api"
import { ApiError } from "@/lib/http"
import {
  AssignmentConflict, bulkAssignSessions, deadlineLabel, fetchAssignmentQueue, isDueOverdue, toDueAtIso, validAssignmentVersion,
  type AssignmentPriority, type AssignmentQueueFilters, type AssignmentQueueResponse,
} from "@/lib/sessionAssignment"
import WorkspaceError from "./WorkspaceError"
import { Badge } from "./ui/badge"
import { Button } from "./ui/button"
import { Input } from "./ui/input"

type QueueMode = "me" | "high" | "unassigned" | "overdue" | "soon"

const QUEUE_FILTERS: Record<QueueMode, AssignmentQueueFilters> = {
  me: { assignee: "me", limit: 12 },
  high: { priority: "high", limit: 12 },
  unassigned: { assignee: "unassigned", limit: 12 },
  overdue: { due: "overdue", limit: 12 },
  soon: { due: "soon", limit: 12 },
}
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

function queueMode(value: string | null): QueueMode {
  return value && Object.hasOwn(QUEUE_FILTERS, value) ? value as QueueMode : "me"
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

type QueueLoad = { key: string; data?: AssignmentQueueResponse; error?: string }

export default function ArchiveAssignmentsStrip() {
  const dueHelpId = useId()
  const params = useSearchParams()
  const mode = queueMode(params.get("queue"))
  const requestedPage = queuePage(params.get("queue_page"))
  const [refreshSeq, setRefreshSeq] = useState(0)
  const requestKey = `${mode}/${requestedPage}/${refreshSeq}`
  const [response, setResponse] = useState<QueueLoad | null>(null)
  const current = response?.key === requestKey ? response : null
  const data = current?.data
  const error = current?.error
  const loading = current === null
  const statusRef = useRef<HTMLParagraphElement>(null)
  const selectVisibleRef = useRef<HTMLButtonElement>(null)
  const focusRange = useRef(false)
  const [selection, setSelection] = useState<{ key: string; versions: Record<string, string> } | null>(null)
  const [bulkEmail, setBulkEmail] = useState("")
  const [bulkPriority, setBulkPriority] = useState<AssignmentPriority>("normal")
  const [bulkDueDate, setBulkDueDate] = useState("")
  const [bulkBusy, setBulkBusy] = useState<"assign" | "clear" | null>(null)
  const [bulkStatus, setBulkStatus] = useState("")
  const [bulkError, setBulkError] = useState("")

  useEffect(() => {
    const controller = new AbortController()
    fetchAssignmentQueue({ ...QUEUE_FILTERS[mode], page: requestedPage }, controller.signal)
      .then(result => {
        if (controller.signal.aborted) return
        if (result.page !== requestedPage) {
          // A bulk action or another reviewer may have emptied the last page.
          const url = new URL(window.location.href)
          if (queueMode(url.searchParams.get("queue")) !== mode || queuePage(url.searchParams.get("queue_page")) !== requestedPage) return
          navigate(mode, result.page, true)
        }
        setResponse({ key: `${mode}/${result.page}/${refreshSeq}`, data: result })
      })
      .catch(err => {
        if (!controller.signal.aborted) setResponse({ key: requestKey, error: message(err) })
      })
    return () => controller.abort()
  }, [mode, requestedPage, refreshSeq, requestKey])

  useEffect(() => {
    if (data && focusRange.current) {
      statusRef.current?.focus({ preventScroll: true })
      focusRange.current = false
    }
  }, [data])

  function changeView(nextMode: QueueMode, page: number) {
    if (nextMode === mode && page === requestedPage) return
    focusRange.current = nextMode === mode
    setSelection(null)
    setBulkError("")
    setBulkStatus("")
    navigate(nextMode, page)
  }

  useEffect(() => { setSelection(null) }, [requestKey])
  const visibleVersions = useMemo(() => {
    const versions: Record<string, string> = {}
    for (const item of data?.items ?? []) {
      if (validAssignmentVersion(item.assignment_version)) versions[item.session_id] = item.assignment_version
    }
    return versions
  }, [data])
  const selectedVersions: Record<string, string> = data && selection?.key === requestKey ? selection.versions : {}
  const selectedIds = Object.keys(selectedVersions)
  const unversioned = Object.keys(visibleVersions).length !== (data?.items.length ?? 0)
  const allVisibleSelected = !!data?.items.length && data.items.every(item => Boolean(selectedVersions[item.session_id]))
  function toggleRow(id: string) {
    const token = visibleVersions[id]
    if (!token) return
    setSelection(current => {
      const versions: Record<string, string> = current?.key === requestKey ? { ...current.versions } : {}
      if (versions[id]) delete versions[id]
      else versions[id] = token
      return { key: requestKey, versions }
    })
  }

  async function runBulk(action: "assign" | "clear", e?: FormEvent) {
    e?.preventDefault()
    if (bulkBusy || !data) return
    if (selectedIds.length === 0) return setBulkError("Select at least one session.")
    if (selectedIds.length > 50) return setBulkError("Select at most 50 sessions per bulk action.")
    const trimmedEmail = bulkEmail.trim().toLowerCase()
    if (action === "assign") {
      if (!trimmedEmail) return setBulkError("Enter an assignee email address.")
      if (!EMAIL_RE.test(trimmedEmail)) return setBulkError("Enter a valid email address.")
    }
    setBulkBusy(action)
    setBulkError("")
    setBulkStatus("")
    try {
      const res = await bulkAssignSessions(
        action === "assign"
          ? { session_ids: selectedIds, expected_versions: selectedVersions, action, assignee_email: trimmedEmail, priority: bulkPriority, due_at: toDueAtIso(bulkDueDate) }
          : { session_ids: selectedIds, expected_versions: selectedVersions, action },
      )
      const noun = res.updated === 1 ? "session" : "sessions"
      setBulkStatus(
        action === "assign"
          ? `Assigned ${res.updated} ${noun} to ${trimmedEmail}.`
          : `Cleared assignments for ${res.updated} ${noun}.`,
      )
      focusRange.current = true
      setSelection(null)
      setRefreshSeq((n) => n + 1)
    } catch (err) {
      const unavailable = err instanceof ApiError && err.status === 404
      if (err instanceof AssignmentConflict || unavailable) {
        setSelection(null)
        setBulkError(unavailable
          ? "A selected interview is unavailable. No assignments were changed. Select the interviews again from the refreshed queue."
          : "No assignments were changed. Review the refreshed queue and select the interviews again.")
        focusRange.current = true
        setRefreshSeq(n => n + 1)
      } else setBulkError(message(err))
    } finally {
      setBulkBusy(null)
    }
  }

  const counts = response?.data?.counts ?? { assigned_to_me: 0, high_priority: 0, unassigned: 0 }
  const dueCounts = response?.data?.due_counts ?? { overdue: 0, due_soon: 0 }
  const pills: Array<{ id: QueueMode; label: string; count: number }> = [
    { id: "me", label: "Assigned to me", count: counts.assigned_to_me },
    { id: "high", label: "High priority", count: counts.high_priority },
    { id: "unassigned", label: "Unassigned", count: counts.unassigned },
    { id: "overdue", label: "Overdue", count: dueCounts.overdue },
    { id: "soon", label: "Due soon", count: dueCounts.due_soon },
  ]

  return (
    <section className="panel stack" aria-label="Assignment queues">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <span className="eyebrow">REVIEW QUEUE</span>
          <h2 className="mt-1 flex items-center gap-2 text-lg font-semibold">
            <UserCheck className="size-4 shrink-0 text-[var(--green-ink)]" aria-hidden="true" />
            <span>Assignment triage</span>
          </h2>
          {data?.viewer_email && <p className="muted text-xs">Queue for {data.viewer_email}</p>}
        </div>
        <Button
          type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8"
          disabled={loading || bulkBusy !== null} onClick={() => setRefreshSeq((n) => n + 1)}
        >
          <RefreshCw className="size-3.5" aria-hidden="true" />
          Refresh queue
        </Button>
      </div>

      <div className="flex flex-wrap items-center gap-2" role="group" aria-label="Assignment queue filters">
        {pills.map((pill) => {
          const active = mode === pill.id
          return (
            <Button
              key={pill.id} type="button" variant={active ? "default" : "outline"} size="sm"
              aria-pressed={active} className="min-h-[44px] md:min-h-8"
              disabled={bulkBusy !== null} onClick={() => changeView(pill.id, 1)}
            >
              <span>{pill.label}</span>
              <Badge variant={active ? "secondary" : "outline"}>{pill.count}</Badge>
            </Button>
          )
        })}
      </div>

      {data && data.filtered > 0 && (
        <nav aria-label="Assignment queue pages" className="flex flex-wrap items-center justify-between gap-2">
          <p ref={statusRef} tabIndex={-1} role="status" className="muted text-sm">
            {(data.page - 1) * data.limit + 1} to {(data.page - 1) * data.limit + data.items.length} of {data.filtered} assignments
          </p>
          {data.pages > 1 && <div className="flex flex-wrap gap-2">
            <Button type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8"
              disabled={data.page === 1 || bulkBusy !== null} onClick={() => changeView(mode, data.page - 1)}>Previous assignments</Button>
            <Button type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8"
              disabled={data.page === data.pages || bulkBusy !== null} onClick={() => changeView(mode, data.page + 1)}>Next assignments</Button>
          </div>}
        </nav>
      )}

      {!data && bulkError && <p role="alert" className="error">{bulkError}</p>}
      {error ? (
        <WorkspaceError text={error} retry={() => setRefreshSeq((n) => n + 1)} showAccount={false} />
      ) : loading && !data ? (
        <p className="muted text-sm" role="status" aria-live="polite">Loading assignment queues...</p>
      ) : !data || data.items.length === 0 ? (
        <div className="stack">
          <p ref={statusRef} tabIndex={-1} className="muted text-sm">No sessions in this assignment queue.</p>
          {bulkStatus && <p role="status" aria-live="polite" className="notice">{bulkStatus}</p>}
          {bulkError && <p role="alert" className="error">{bulkError}</p>}
        </div>
      ) : (
        <div className="stack">
          <div className={selectedIds.length ? "panel inset stack" : "stack"} role="region" aria-label="Bulk session assignment">
            <div className="flex flex-wrap items-center gap-2">
              <Badge variant={selectedIds.length > 0 ? "default" : "outline"}>{selectedIds.length} selected</Badge>
              <Button
                ref={selectVisibleRef} type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8"
                disabled={bulkBusy !== null || unversioned}
                onClick={() => setSelection(allVisibleSelected ? null : { key: requestKey, versions: visibleVersions })}
              >
                {allVisibleSelected ? "Clear selection" : "Select visible"}
              </Button>
              {selectedIds.length > 0 && !allVisibleSelected && (
                <Button
                  type="button" variant="ghost" size="sm" className="min-h-[44px] md:min-h-8"
                  disabled={bulkBusy !== null} onClick={() => {
                    setSelection(null)
                    selectVisibleRef.current?.focus()
                  }}
                >
                  Clear selection
                </Button>
              )}
            </div>
            {unversioned && <p className="muted" role="status">Refresh the queue to select interviews missing an assignment version.</p>}

            {selectedIds.length > 0 && <form
              className="grid gap-3 md:grid-cols-[minmax(0,1.4fr)_minmax(130px,0.8fr)_minmax(145px,0.9fr)_auto] md:items-end"
              noValidate onSubmit={(e) => void runBulk("assign", e)}
            >
              <label className="field">
                Bulk assignee email
                <Input
                  type="email" value={bulkEmail} placeholder="reviewer@example.com"
                  maxLength={254} disabled={bulkBusy !== null} onChange={(e) => setBulkEmail(e.target.value)}
                />
              </label>
              <label className="field">
                Bulk priority
                <select value={bulkPriority} disabled={bulkBusy !== null} onChange={(e) => setBulkPriority(e.target.value as AssignmentPriority)}>
                  <option value="low">Low</option>
                  <option value="normal">Normal</option>
                  <option value="high">High</option>
                </select>
              </label>
              <label className="field">
                Bulk due date (UTC)
                <Input type="date" aria-describedby={dueHelpId} value={bulkDueDate} disabled={bulkBusy !== null} onChange={(e) => setBulkDueDate(e.target.value)} />
              </label>
              <div className="flex flex-wrap items-center gap-2">
                <Button type="submit" size="sm" className="min-h-[44px] md:min-h-8" disabled={bulkBusy !== null}>
                  {bulkBusy === "assign" ? "Assigning..." : "Assign selected"}
                </Button>
                <Button
                  type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8"
                  disabled={bulkBusy !== null} onClick={() => void runBulk("clear")}
                >
                  <Trash2 className="size-3.5" aria-hidden="true" />
                  {bulkBusy === "clear" ? "Clearing..." : "Clear selected assignments"}
                </Button>
              </div>
              <small className="md:col-span-full" id={dueHelpId}>Assigning sets all selected deadlines to 23:59:59 UTC on this date. A blank date clears them.</small>
            </form>}

            {bulkStatus && <p role="status" aria-live="polite" className="notice">{bulkStatus}</p>}
            {bulkError && <p role="alert" className="error">{bulkError}</p>}
          </div>

          <ul className="grid gap-2 list-none p-0 m-0">
            {data.items.map((item) => {
              const overdue = isDueOverdue(item.due_at)
              return (
                <li key={item.session_id} className="flex items-stretch gap-2 min-w-0">
                  <label className="flex items-center justify-center rounded-lg border border-[var(--line)] bg-[var(--surface)] px-3 min-h-[44px] min-w-[44px] md:min-h-10 md:min-w-10 cursor-pointer shrink-0">
                    <input
                      type="checkbox" checked={Boolean(selectedVersions[item.session_id])} disabled={bulkBusy !== null || !visibleVersions[item.session_id]}
                      aria-label={`Select ${item.candidate || "session"} for bulk assignment`}
                      onChange={() => toggleRow(item.session_id)}
                    />
                  </label>
                  <Link
                    href={`/interviews/review/?id=${encodeURIComponent(item.session_id)}`}
                    className="flex flex-1 min-w-0 flex-col sm:flex-row sm:items-center justify-between gap-2 rounded-lg border border-[var(--line)] bg-[var(--surface)] px-3 py-2.5 transition-colors hover:bg-[var(--subtle)] min-h-[44px]"
                  >
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <strong className="max-w-full text-sm [overflow-wrap:anywhere]">{item.candidate || "Untitled interview"}</strong>
                        {item.role && <Badge variant="outline" className="max-w-full whitespace-normal [overflow-wrap:anywhere]">{item.role}</Badge>}
                        {item.priority === "high" && <Badge variant="warning">High priority</Badge>}
                        {overdue && <Badge variant="warning">Overdue</Badge>}
                        {item.review_count > 0 && <Badge variant="secondary">{item.review_count} pending</Badge>}
                      </div>
                      <p className="muted text-xs break-all">
                        {item.assignee_email ? `Assigned to ${item.assignee_email}` : "Unassigned"}
                        {item.due_at && <> · Due <time dateTime={item.due_at}>{deadlineLabel(item.due_at)}</time></>}
                      </p>
                    </div>
                    <span className="inline-flex items-center gap-1 text-xs font-semibold text-[var(--green-ink)] shrink-0">
                      Open review
                      <ArrowRight className="size-3.5" aria-hidden="true" />
                    </span>
                  </Link>
                </li>
              )
            })}
          </ul>
        </div>
      )}
    </section>
  )
}
