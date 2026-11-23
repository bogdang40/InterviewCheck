"use client"

import Link from "next/link"
import { type FormEvent, useCallback, useEffect, useId, useMemo, useRef, useState } from "react"
import { ArrowRight, RefreshCw, Trash2, UserCheck } from "lucide-react"
import { message } from "@/lib/api"
import { ApiError } from "@/lib/http"
import {
  AssignmentConflict, bulkAssignSessions, deadlineLabel, isDueOverdue, toDueAtIso, validAssignmentVersion,
  type AssignmentPriority, type AssignmentQueueResponse,
} from "@/lib/sessionAssignment"
import { useAssignmentQueue, type QueueMode } from "@/lib/useAssignmentQueue"
import WorkspaceError from "./WorkspaceError"
import { Badge } from "./ui/badge"
import { Button } from "./ui/button"
import { Input } from "./ui/input"

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
type Selection = { key: string; versions: Record<string, string>; snapshot: AssignmentQueueResponse }

export default function ArchiveAssignmentsStrip() {
  const dueHelpId = useId()
  const queueElement = useRef<HTMLElement>(null)
  const statusRef = useRef<HTMLParagraphElement>(null)
  const selectVisibleRef = useRef<HTMLButtonElement>(null)
  const focusRange = useRef(false)
  const [selection, setSelectionState] = useState<Selection | null>(null)
  const selected = useRef<Selection | null>(null)
  const writing = useRef(false)
  const accessEpoch = useRef(0)
  const removedFocus = useRef<HTMLElement | null>(null)
  const [bulkEmail, setBulkEmail] = useState("")
  const [bulkPriority, setBulkPriority] = useState<AssignmentPriority>("normal")
  const [bulkDueDate, setBulkDueDate] = useState("")
  const [bulkBusy, setBulkBusy] = useState<"assign" | "clear" | null>(null)
  const [bulkStatus, setBulkStatus] = useState("")
  const [bulkError, setBulkError] = useState("")

  const isFrozen = useCallback(() => !!selected.current || writing.current, [])
  const beforeBackgroundUpdate = useCallback(() => {
    const active = document.activeElement
    removedFocus.current = active instanceof HTMLElement && queueElement.current?.contains(active) ? active : null
  }, [])
  const onAccessDenied = useCallback(() => {
    accessEpoch.current += 1
    selected.current = null
    writing.current = false
    removedFocus.current = null
    focusRange.current = false
    setSelectionState(null)
    setBulkBusy(null)
    setBulkEmail("")
    setBulkPriority("normal")
    setBulkDueDate("")
    setBulkStatus("")
    setBulkError("")
  }, [])
  const queue = useAssignmentQueue(isFrozen, beforeBackgroundUpdate, onAccessDenied)
  const { key: requestKey, mode, requestedPage, loading, error } = queue
  const pinned = selection?.key === requestKey ? selection : null
  const data = pinned?.snapshot ?? queue.data
  const stale = (!!queue.notice && !queue.notice.error) || (!!pinned && pinned.snapshot !== queue.data)
  useEffect(() => {
    if (!pinned && !bulkBusy && stale) queue.resumeIfDeferred()
  }, [pinned, bulkBusy, stale, queue.resumeIfDeferred])

  const setSelection = useCallback((next: Selection | null) => {
    selected.current = next
    setSelectionState(next)
  }, [])

  useEffect(() => {
    if (!data) return
    if (focusRange.current) {
      statusRef.current?.focus({ preventScroll: true })
      focusRange.current = false
    } else if (removedFocus.current && !removedFocus.current.isConnected && document.activeElement === document.body) {
      statusRef.current?.focus({ preventScroll: true })
    }
    removedFocus.current = null
  }, [data])

  function changeView(nextMode: QueueMode, page: number) {
    if (nextMode === mode && page === requestedPage) return
    focusRange.current = nextMode === mode
    setSelection(null)
    setBulkError("")
    setBulkStatus("")
    queue.changePage(nextMode, page)
  }

  useEffect(() => { setSelection(null) }, [requestKey, setSelection])
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
    if (!token || !data) return
    const current = selected.current
    const versions: Record<string, string> = current?.key === requestKey ? { ...current.versions } : {}
    if (versions[id]) delete versions[id]
    else versions[id] = token
    setSelection(Object.keys(versions).length ? { key: requestKey, versions, snapshot: data } : null)
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
    writing.current = true
    const epoch = accessEpoch.current
    setBulkBusy(action)
    setBulkError("")
    setBulkStatus("")
    try {
      const res = await bulkAssignSessions(
        action === "assign"
          ? { session_ids: selectedIds, expected_versions: selectedVersions, action, assignee_email: trimmedEmail, priority: bulkPriority, due_at: toDueAtIso(bulkDueDate) }
          : { session_ids: selectedIds, expected_versions: selectedVersions, action },
      )
      if (epoch !== accessEpoch.current) return
      const noun = res.updated === 1 ? "session" : "sessions"
      setBulkStatus(
        action === "assign"
          ? `Assigned ${res.updated} ${noun} to ${trimmedEmail}.`
          : `Cleared assignments for ${res.updated} ${noun}.`,
      )
      focusRange.current = true
      setSelection(null)
      queue.refresh()
    } catch (err) {
      if (epoch !== accessEpoch.current) return
      if (err instanceof ApiError && (err.status === 401 || err.status === 403)) {
        queue.denyAccess(err)
        return
      }
      const unavailable = err instanceof ApiError && err.status === 404
      if (err instanceof AssignmentConflict || unavailable) {
        setSelection(null)
        setBulkError(unavailable
          ? "A selected interview is unavailable. No assignments were changed. Select the interviews again from the refreshed queue."
          : "No assignments were changed. Review the refreshed queue and select the interviews again.")
        focusRange.current = true
        queue.refresh()
      } else setBulkError(message(err))
    } finally {
      if (epoch === accessEpoch.current) {
        writing.current = false
        setBulkBusy(null)
      }
    }
  }

  const counts = (data ?? queue.previousData)?.counts ?? { assigned_to_me: 0, high_priority: 0, unassigned: 0 }
  const dueCounts = (data ?? queue.previousData)?.due_counts ?? { overdue: 0, due_soon: 0 }
  const pills: Array<{ id: QueueMode; label: string; count: number }> = [
    { id: "me", label: "Assigned to me", count: counts.assigned_to_me },
    { id: "high", label: "High priority", count: counts.high_priority },
    { id: "unassigned", label: "Unassigned", count: counts.unassigned },
    { id: "overdue", label: "Overdue", count: dueCounts.overdue },
    { id: "soon", label: "Due soon", count: dueCounts.due_soon },
  ]

  return (
    <section ref={queueElement} className="panel stack" aria-label="Assignment queues">
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
          disabled={loading || bulkBusy !== null} onClick={() => {
            if (selected.current) focusRange.current = true
            setSelection(null)
            queue.refresh()
          }}
        >
          <RefreshCw className="size-3.5" aria-hidden="true" />
          {pinned ? "Refresh and reselect" : "Refresh queue"}
        </Button>
      </div>
      {stale && <p role="status" className="notice">Queue may have changed. Refresh the queue and reselect interviews to use the latest assignments.</p>}
      {queue.notice?.error && <p role="status" className="notice">Could not refresh the queue. {queue.notice.error}</p>}

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
        <WorkspaceError text={error} retry={queue.refresh} showAccount={queue.denied} />
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
                onClick={() => setSelection(allVisibleSelected ? null : { key: requestKey, versions: visibleVersions, snapshot: data })}
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
