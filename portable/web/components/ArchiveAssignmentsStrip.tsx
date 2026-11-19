"use client"

import Link from "next/link"
import { useEffect, useState } from "react"
import { ArrowRight, RefreshCw, UserCheck } from "lucide-react"
import { dateLabel, message } from "@/lib/api"
import {
  fetchAssignmentQueue,
  type AssignmentQueueFilters,
  type AssignmentQueueResponse,
} from "@/lib/sessionAssignment"
import WorkspaceError from "./WorkspaceError"
import { Badge } from "./ui/badge"
import { Button } from "./ui/button"

type QueueMode = "me" | "high" | "unassigned"

const QUEUE_FILTERS: Record<QueueMode, AssignmentQueueFilters> = {
  me: { assignee: "me", limit: 12 },
  high: { priority: "high", limit: 12 },
  unassigned: { assignee: "unassigned", limit: 12 },
}

export default function ArchiveAssignmentsStrip() {
  const [mode, setMode] = useState<QueueMode>("me")
  const [data, setData] = useState<AssignmentQueueResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState("")
  const [refreshSeq, setRefreshSeq] = useState(0)

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true)
    setError("")
    fetchAssignmentQueue(QUEUE_FILTERS[mode], controller.signal)
      .then((res) => setData(res))
      .catch((err) => {
        if (!(err instanceof DOMException && err.name === "AbortError")) setError(message(err))
      })
      .finally(() => {
        if (!controller.signal.aborted) setLoading(false)
      })
    return () => controller.abort()
  }, [mode, refreshSeq])

  const counts = data?.counts ?? { assigned_to_me: 0, high_priority: 0, unassigned: 0 }
  const pills: Array<{ id: QueueMode; label: string; count: number }> = [
    { id: "me", label: "Assigned to me", count: counts.assigned_to_me },
    { id: "high", label: "High priority", count: counts.high_priority },
    { id: "unassigned", label: "Unassigned", count: counts.unassigned },
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
          {data?.viewer_email && (
            <p className="muted text-xs">Queue for {data.viewer_email}</p>
          )}
        </div>
        <Button
          type="button"
          variant="outline"
          size="sm"
          className="min-h-[44px] md:min-h-8"
          disabled={loading}
          onClick={() => setRefreshSeq((n) => n + 1)}
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
              key={pill.id}
              type="button"
              variant={active ? "default" : "outline"}
              size="sm"
              aria-pressed={active}
              className="min-h-[44px] md:min-h-8"
              onClick={() => setMode(pill.id)}
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
        <p className="muted text-sm" role="status" aria-live="polite">
          Loading assignment queues...
        </p>
      ) : !data || data.items.length === 0 ? (
        <p className="muted text-sm">No sessions in this assignment queue.</p>
      ) : (
        <ul className="grid gap-2 list-none p-0 m-0">
          {data.items.map((item) => (
            <li key={item.session_id} className="min-w-0">
              <Link
                href={`/interviews/review/?id=${encodeURIComponent(item.session_id)}`}
                className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-[var(--line)] bg-[var(--surface)] px-3 py-2.5 transition-colors hover:bg-[var(--subtle)] min-h-[44px]"
              >
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <strong className="text-sm break-words">{item.candidate || "Untitled interview"}</strong>
                    {item.role && <Badge variant="outline">{item.role}</Badge>}
                    {item.priority === "high" && <Badge variant="warning">High priority</Badge>}
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
          ))}
        </ul>
      )}
    </section>
  )
}
