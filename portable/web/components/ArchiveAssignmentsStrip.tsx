"use client"

import Link from "next/link"
import { type FormEvent, useEffect, useMemo, useState } from "react"
import { ArrowRight, RefreshCw, Trash2, UserCheck } from "lucide-react"
import { dateLabel, message } from "@/lib/api"
import {
  bulkAssignSessions, fetchAssignmentQueue, isDueOverdue, toDueAtIso,
  type AssignmentPriority, type AssignmentQueueFilters, type AssignmentQueueResponse,
} from "@/lib/sessionAssignment"
import WorkspaceError from "./WorkspaceError"
import { Badge } from "./ui/badge"
import { Button } from "./ui/button"
import { Input } from "./ui/input"

type QueueMode = "me" | "high" | "unassigned" | "overdue"

const QUEUE_FILTERS: Record<QueueMode, AssignmentQueueFilters> = {
  me: { assignee: "me", limit: 12 },
  high: { priority: "high", limit: 12 },
  unassigned: { assignee: "unassigned", limit: 12 },
  overdue: { due: "overdue", limit: 12 },
}
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

export default function ArchiveAssignmentsStrip() {
  const [mode, setMode] = useState<QueueMode>("me")
  const [data, setData] = useState<AssignmentQueueResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState("")
  const [refreshSeq, setRefreshSeq] = useState(0)
  const [selectedIds, setSelectedIds] = useState<string[]>([])
  const [bulkEmail, setBulkEmail] = useState("")
  const [bulkPriority, setBulkPriority] = useState<AssignmentPriority>("normal")
  const [bulkDueDate, setBulkDueDate] = useState("")
  const [bulkBusy, setBulkBusy] = useState<"assign" | "clear" | null>(null)
  const [bulkStatus, setBulkStatus] = useState("")
  const [bulkError, setBulkError] = useState("")

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true)
    setError("")
    fetchAssignmentQueue(QUEUE_FILTERS[mode], controller.signal)
      .then((res) => setData(res))
      .catch((err) => { if (!(err instanceof DOMException && err.name === "AbortError")) setError(message(err)) })
      .finally(() => { if (!controller.signal.aborted) setLoading(false) })
    return () => controller.abort()
  }, [mode, refreshSeq])

  const visibleIds = useMemo(() => (data?.items ?? []).map((item) => item.session_id), [data])
  useEffect(() => { setSelectedIds((prev) => prev.filter((id) => visibleIds.includes(id))) }, [visibleIds])

  const selectedSet = useMemo(() => new Set(selectedIds), [selectedIds])
  const allVisibleSelected = visibleIds.length > 0 && visibleIds.every((id) => selectedSet.has(id))
  const toggleRow = (id: string) =>
    setSelectedIds((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]))

  async function runBulk(action: "assign" | "clear", e?: FormEvent) {
    e?.preventDefault()
    if (bulkBusy) return
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
          ? { session_ids: selectedIds, action, assignee_email: trimmedEmail, priority: bulkPriority, due_at: toDueAtIso(bulkDueDate) }
          : { session_ids: selectedIds, action },
      )
      const noun = res.updated === 1 ? "session" : "sessions"
      setBulkStatus(
        action === "assign"
          ? `Assigned ${res.updated} ${noun} to ${trimmedEmail}.`
          : `Cleared assignments for ${res.updated} ${noun}.`,
      )
      setSelectedIds([])
      setRefreshSeq((n) => n + 1)
    } catch (err) {
      setBulkError(message(err))
    } finally {
      setBulkBusy(null)
    }
  }

  const counts = data?.counts ?? { assigned_to_me: 0, high_priority: 0, unassigned: 0 }
  const dueCounts = data?.due_counts ?? { overdue: 0, due_soon: 0 }
  const pills: Array<{ id: QueueMode; label: string; count: number }> = [
    { id: "me", label: "Assigned to me", count: counts.assigned_to_me },
    { id: "high", label: "High priority", count: counts.high_priority },
    { id: "unassigned", label: "Unassigned", count: counts.unassigned },
    { id: "overdue", label: "Overdue", count: dueCounts.overdue },
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
              onClick={() => { setMode(pill.id); setBulkError(""); setBulkStatus("") }}
            >
              <span>{pill.label}</span>
              <Badge variant={active ? "secondary" : "outline"}>{pill.count}</Badge>
            </Button>
          )
        })}
      </div>

      {error ? (
        <WorkspaceError text={error} retry={() => setRefreshSeq((n) => n + 1)} showAccount={false} />
      ) : loading && !data ? (
        <p className="muted text-sm" role="status" aria-live="polite">Loading assignment queues...</p>
      ) : !data || data.items.length === 0 ? (
        <div className="stack">
          <p className="muted text-sm">No sessions in this assignment queue.</p>
          {bulkStatus && <p role="status" aria-live="polite" className="notice">{bulkStatus}</p>}
          {bulkError && <p role="alert" className="error">{bulkError}</p>}
        </div>
      ) : (
        <div className="stack">
          <div className="panel inset stack" role="region" aria-label="Bulk session assignment">
            <div className="flex flex-wrap items-center gap-2">
              <Badge variant={selectedIds.length > 0 ? "default" : "outline"}>{selectedIds.length} selected</Badge>
              <Button
                type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8"
                disabled={bulkBusy !== null || visibleIds.length === 0 || allVisibleSelected}
                onClick={() => setSelectedIds(visibleIds)}
              >
                Select visible
              </Button>
              {selectedIds.length > 0 && (
                <Button
                  type="button" variant="ghost" size="sm" className="min-h-[44px] md:min-h-8"
                  disabled={bulkBusy !== null} onClick={() => setSelectedIds([])}
                >
                  Clear selection
                </Button>
              )}
            </div>

            <form
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
                Bulk due date
                <Input type="date" value={bulkDueDate} disabled={bulkBusy !== null} onChange={(e) => setBulkDueDate(e.target.value)} />
              </label>
              <div className="flex flex-wrap items-center gap-2">
                <Button type="submit" size="sm" className="min-h-[44px] md:min-h-8" disabled={bulkBusy !== null || selectedIds.length === 0}>
                  {bulkBusy === "assign" ? "Assigning..." : "Assign selected"}
                </Button>
                <Button
                  type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8"
                  disabled={bulkBusy !== null || selectedIds.length === 0} onClick={() => void runBulk("clear")}
                >
                  <Trash2 className="size-3.5" aria-hidden="true" />
                  {bulkBusy === "clear" ? "Clearing..." : "Clear selected assignments"}
                </Button>
              </div>
            </form>

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
                      type="checkbox" checked={selectedSet.has(item.session_id)} disabled={bulkBusy !== null}
                      aria-label={`Select ${item.candidate || "session"} for bulk assignment`}
                      onChange={() => toggleRow(item.session_id)}
                    />
                  </label>
                  <Link
                    href={`/interviews/review/?id=${encodeURIComponent(item.session_id)}`}
                    className="flex flex-1 min-w-0 flex-wrap items-center justify-between gap-2 rounded-lg border border-[var(--line)] bg-[var(--surface)] px-3 py-2.5 transition-colors hover:bg-[var(--subtle)] min-h-[44px]"
                  >
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <strong className="text-sm break-words">{item.candidate || "Untitled interview"}</strong>
                        {item.role && <Badge variant="outline">{item.role}</Badge>}
                        {item.priority === "high" && <Badge variant="warning">High priority</Badge>}
                        {overdue && <Badge variant="warning">Overdue</Badge>}
                        {item.review_count > 0 && <Badge variant="secondary">{item.review_count} pending</Badge>}
                      </div>
                      <p className="muted text-xs break-all">
                        {item.assignee_email ? `Assigned to ${item.assignee_email}` : "Unassigned"}
                        {item.due_at ? ` - Due ${dateLabel(item.due_at)}` : ""}
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
