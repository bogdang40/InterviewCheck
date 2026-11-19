"use client"

import Link from "next/link"
import { useEffect, useState } from "react"
import { Download, ExternalLink, RefreshCw, Scale } from "lucide-react"
import { message, type Disposition } from "@/lib/api"
import {
  downloadCalibrationExport,
  fetchCalibrationDisagreements,
  type CalibrationDisagreementsResponse,
  type CalibrationExportFormat,
} from "@/lib/calibrationQueue"
import WorkspaceError from "./WorkspaceError"
import { Badge } from "./ui/badge"
import { Button } from "./ui/button"

const DISPOSITION_VARIANT: Record<Disposition, "secondary" | "success" | "warning" | "destructive"> = {
  pending: "secondary",
  explained: "success",
  unresolved: "warning",
  disclosed: "destructive",
}

const DISPOSITION_LABEL: Record<Disposition, string> = {
  pending: "Pending",
  explained: "Explained",
  unresolved: "Unresolved",
  disclosed: "Disclosed",
}

function dispositionBadgeVariant(value: string): "secondary" | "success" | "warning" | "destructive" {
  return value in DISPOSITION_VARIANT ? DISPOSITION_VARIANT[value as Disposition] : "secondary"
}

function dispositionLabel(value: string): string {
  return value in DISPOSITION_LABEL ? DISPOSITION_LABEL[value as Disposition] : value
}

export default function CalibrationQueuePanel({ roles }: { roles: Array<{ id: string; name: string }> }) {
  const [roleId, setRoleId] = useState("")
  const [data, setData] = useState<CalibrationDisagreementsResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState("")
  const [exportBusy, setExportBusy] = useState<CalibrationExportFormat | null>(null)
  const [exportError, setExportError] = useState("")
  const [notice, setNotice] = useState("")
  const [refreshSeq, setRefreshSeq] = useState(0)

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true)
    setError("")
    fetchCalibrationDisagreements(roleId, 50, controller.signal)
      .then((next) => setData(next))
      .catch((err) => {
        if (!(err instanceof DOMException && err.name === "AbortError")) setError(message(err))
      })
      .finally(() => {
        if (!controller.signal.aborted) setLoading(false)
      })
    return () => controller.abort()
  }, [roleId, refreshSeq])

  async function handleExport(format: CalibrationExportFormat) {
    if (exportBusy) return
    setExportBusy(format)
    setExportError("")
    setNotice("")
    try {
      const filename = await downloadCalibrationExport(roleId, format)
      setNotice(`Exported calibration queue to ${filename}.`)
    } catch (err) {
      setExportError(message(err))
    } finally {
      setExportBusy(null)
    }
  }

  const summary = data?.summary
  const totalDisagreements = summary?.total_disagreed_answers ?? 0

  return (
    <section className="panel stack" aria-label="Reviewer calibration disagreement queue">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <span className="eyebrow">CALIBRATION QUEUE</span>
          <div className="mt-1 flex flex-wrap items-center gap-2">
            <h2 className="flex items-center gap-2">
              <Scale className="size-5 shrink-0" aria-hidden="true" />
              <span>Reviewer disagreement queue</span>
            </h2>
            <Badge variant={totalDisagreements > 0 ? "warning" : "secondary"}>
              {totalDisagreements} {totalDisagreements === 1 ? "disagreement" : "disagreements"}
            </Badge>
          </div>
          <p className="muted text-sm">
            Inspect exchanges where reviewers recorded differing dispositions and jump straight into review.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Button type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8" disabled={loading} onClick={() => setRefreshSeq((n) => n + 1)}>
            <RefreshCw className="size-3.5" aria-hidden="true" />
            Refresh queue
          </Button>
          <Button type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8" disabled={loading || exportBusy !== null} onClick={() => void handleExport("csv")}>
            <Download className="size-3.5" aria-hidden="true" />
            {exportBusy === "csv" ? "Exporting CSV..." : "Export CSV"}
          </Button>
          <Button type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8" disabled={loading || exportBusy !== null} onClick={() => void handleExport("json")}>
            <Download className="size-3.5" aria-hidden="true" />
            {exportBusy === "json" ? "Exporting JSON..." : "Export JSON"}
          </Button>
        </div>
      </div>

      <div className="flex flex-wrap items-end justify-between gap-3">
        <label className="field min-w-[220px] max-w-xs flex-1">
          Filter by role
          <select aria-label="Filter calibration queue by role" value={roleId} onChange={(e) => setRoleId(e.target.value)}>
            <option value="">All roles</option>
            {roles.map((r) => (
              <option key={r.id} value={r.id}>
                {r.name}
              </option>
            ))}
          </select>
        </label>
        {summary && (
          <div className="flex flex-wrap items-center gap-2 text-xs text-[var(--muted)]">
            <span>{summary.roles_with_disagreements} roles affected</span>
            <span>|</span>
            <span>{summary.reviewer_count} active reviewers</span>
          </div>
        )}
      </div>

      {notice && <p role="status" aria-live="polite" className="notice">{notice}</p>}
      {exportError && <p role="alert" className="error">{exportError}</p>}

      {error ? (
        <WorkspaceError text={error} retry={() => setRefreshSeq((n) => n + 1)} showAccount={false} />
      ) : loading && !data ? (
        <p className="muted text-sm" role="status" aria-live="polite">
          Loading calibration disagreements...
        </p>
      ) : !data || data.items.length === 0 ? (
        <p className="muted text-sm">No multi-reviewer disagreements found for this filter.</p>
      ) : (
        <ul className="stack list-none p-0 m-0">
          {data.items.map((item) => (
            <li key={item.answer_id} className="rounded-lg border border-[var(--line)] bg-[var(--surface)] p-4 stack">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div className="min-w-0 flex-1 stack !gap-1.5">
                  <div className="flex flex-wrap items-center gap-2">
                    <Badge variant="outline">{item.role_name || "Unassigned role"}</Badge>
                    <span className="font-semibold text-sm">{item.candidate}</span>
                    <Badge variant={dispositionBadgeVariant(item.current_disposition)}>
                      Current: {dispositionLabel(item.current_disposition)}
                    </Badge>
                  </div>
                  <p className="text-sm font-medium break-words">{item.question}</p>
                </div>
                <Button asChild variant="outline" size="sm" className="min-h-[44px] md:min-h-8 shrink-0">
                  <Link href={`/interviews/review/?id=${encodeURIComponent(item.session_id)}&answer=${encodeURIComponent(item.answer_id)}`}>
                    <span>Review exchange</span>
                    <ExternalLink className="size-3.5" aria-hidden="true" />
                  </Link>
                </Button>
              </div>
              <div className="flex flex-wrap items-center gap-2">
                {item.reviewers.map((rev, idx) => (
                  <Badge
                    key={`${rev.reviewer_email}-${idx}`}
                    variant={dispositionBadgeVariant(rev.disposition)}
                    className="max-w-full whitespace-normal break-all text-left"
                  >
                    {rev.reviewer_email}: {dispositionLabel(rev.disposition)}
                  </Badge>
                ))}
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
