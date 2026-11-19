"use client"

import { useCallback, useEffect, useState } from "react"
import { BarChart3, RefreshCw } from "lucide-react"
import {
  fetchRoleCalibration,
  fetchRolesAnalytics,
  type ReviewerSummary,
  type RoleCalibrationResponse,
  type RolesAnalyticsResponse,
} from "@/lib/roleCalibration"
import { Badge } from "./ui/badge"
import { Button } from "./ui/button"

function formatDeltaPp(delta: number): string {
  return `${delta > 0 ? "+" : ""}${delta.toFixed(1)} pp`
}

function RateBar({ label, pct, detail, tone }: { label: string; pct: number; detail: string; tone: string }) {
  const clamped = Math.min(100, Math.max(0, pct))
  return (
    <div className="stack !gap-1">
      <div className="flex items-center justify-between gap-2 text-xs">
        <span className="font-medium">{label}</span>
        <span className="font-mono tabular-nums text-[var(--muted)]">{pct.toFixed(1)}% ({detail})</span>
      </div>
      <div className="h-2 w-full overflow-hidden rounded-full bg-[var(--subtle)] border border-[var(--line)]">
        <div className="h-full rounded-full transition-all" style={{ width: `${clamped}%`, backgroundColor: tone }} />
      </div>
    </div>
  )
}

function ReviewerTable({ rows, caption }: { rows: ReviewerSummary[]; caption: string }) {
  if (!rows.length) return <p className="muted text-sm">No reviewer dispositions recorded yet.</p>
  return (
    <div className="w-full overflow-x-auto rounded-lg border border-[var(--line)]">
      <table className="w-full border-collapse text-left text-xs sm:text-sm">
        <caption className="sr-only">{caption}</caption>
        <thead className="bg-[var(--subtle)] text-[var(--muted)]">
          <tr>
            <th className="px-3 py-2 font-medium">Reviewer</th>
            <th className="px-3 py-2 font-medium tabular-nums">Reviews</th>
            <th className="px-3 py-2 font-medium tabular-nums">Pass</th>
            <th className="px-3 py-2 font-medium tabular-nums">Concern</th>
            <th className="px-3 py-2 font-medium tabular-nums">Delta vs baseline</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((rev) => (
            <tr key={rev.reviewer_id} className="border-t border-[var(--line)]">
              <td className="px-3 py-2 font-medium break-all">{rev.reviewer_email}</td>
              <td className="px-3 py-2 tabular-nums">{rev.total_reviews}</td>
              <td className="px-3 py-2 tabular-nums">{rev.pass_rate_pct.toFixed(1)}%</td>
              <td className="px-3 py-2 tabular-nums">{rev.concern_rate_pct.toFixed(1)}%</td>
              <td className="px-3 py-2 font-mono tabular-nums">
                <Badge variant={Math.abs(rev.delta_vs_baseline_pp) >= 20 ? "warning" : "secondary"}>
                  {formatDeltaPp(rev.delta_vs_baseline_pp)}
                </Badge>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function RetryAlert({ message, disabled, onRetry }: { message: string; disabled: boolean; onRetry: () => void }) {
  return (
    <div className="error stack" role="alert">
      <p>{message}</p>
      <div>
        <Button type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8" disabled={disabled} onClick={onRetry}>
          Retry
        </Button>
      </div>
    </div>
  )
}

export default function RoleAnalyticsPanel({ refreshKey = 0 }: { refreshKey?: number }) {
  const [analytics, setAnalytics] = useState<RolesAnalyticsResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState("")
  const [selectedRoleId, setSelectedRoleId] = useState<string | null>(null)
  const [calibration, setCalibration] = useState<RoleCalibrationResponse | null>(null)
  const [calLoading, setCalLoading] = useState(false)
  const [calError, setCalError] = useState("")
  const [statusText, setStatusText] = useState("")

  const loadAnalytics = useCallback(async (signal?: AbortSignal) => {
    setLoading(true)
    setError("")
    try {
      const next = await fetchRolesAnalytics(signal)
      setAnalytics(next)
      setStatusText(`Loaded analytics for ${next.roles.length} ${next.roles.length === 1 ? "role" : "roles"}.`)
    } catch (err) {
      if (err instanceof DOMException && err.name === "AbortError") return
      setError(err instanceof Error ? err.message : "Failed to load role analytics.")
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    const controller = new AbortController()
    void loadAnalytics(controller.signal)
    return () => controller.abort()
  }, [loadAnalytics, refreshKey])

  async function loadCalibration(roleId: string) {
    setSelectedRoleId(roleId)
    setCalLoading(true)
    setCalError("")
    try {
      const next = await fetchRoleCalibration(roleId)
      setCalibration(next)
      setStatusText(`Loaded calibration breakdown for ${next.role_name}.`)
    } catch (err) {
      setCalError(err instanceof Error ? err.message : "Failed to load role calibration.")
    } finally {
      setCalLoading(false)
    }
  }

  async function inspectRole(roleId: string) {
    if (selectedRoleId === roleId) {
      setSelectedRoleId(null)
      setCalibration(null)
      setCalError("")
      setStatusText("Collapsed role calibration breakdown.")
      return
    }
    await loadCalibration(roleId)
  }

  const totals = analytics?.totals

  return (
    <section className="panel stack" aria-label="Role calibration analytics">
      <p className="sr-only" aria-live="polite">{statusText}</p>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <span className="eyebrow">CALIBRATION</span>
          <h2 className="mt-1 flex items-center gap-2">
            <BarChart3 className="size-5 shrink-0" aria-hidden="true" />
            <span>Role analytics and reviewer spread</span>
          </h2>
          <p className="muted text-sm">Pass, passage match, and concern rates across active interviews, plus reviewer calibration variance.</p>
        </div>
        <Button type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8" disabled={loading} onClick={() => void loadAnalytics()}>
          <RefreshCw aria-hidden="true" />
          Refresh analytics
        </Button>
      </div>
      {error && <RetryAlert message={error} disabled={loading} onRetry={() => void loadAnalytics()} />}
      {loading && !analytics ? (
        <p className="muted text-sm" role="status" aria-live="polite">Loading role analytics...</p>
      ) : totals && (
        <>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            {[
              ["Active sessions", String(totals.session_count)],
              ["Pass rate", `${totals.pass_rate_pct.toFixed(1)}%`],
              ["Concern rate", `${totals.concern_rate_pct.toFixed(1)}%`],
              ["Disagreements", String(totals.multi_reviewer_disagreements)],
            ].map(([label, value]) => (
              <div key={label} className="rounded-lg border border-[var(--line)] bg-[var(--subtle)] p-3">
                <div className="text-xs text-[var(--muted)]">{label}</div>
                <div className="text-xl font-semibold tabular-nums">{value}</div>
              </div>
            ))}
          </div>
          {analytics.roles.length > 0 && (
            <div className="stack">
              {analytics.roles.map((item) => {
                const isSelected = selectedRoleId === item.role_id
                return (
                  <div key={item.role_id} className="rounded-lg border border-[var(--line)] bg-[var(--surface)] p-4 stack">
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <div className="flex flex-wrap items-center gap-2 min-w-0">
                        <strong className="text-sm sm:text-base">{`${item.role_name} (v${item.version_number})`}</strong>
                        <Badge variant="secondary">{item.session_count} sessions</Badge>
                        <Badge variant={item.multi_reviewer_disagreements > 0 ? "warning" : "secondary"}>
                          {item.multi_reviewer_disagreements} disagreements
                        </Badge>
                      </div>
                      <Button type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8" onClick={() => void inspectRole(item.role_id)}>
                        {isSelected ? "Hide breakdown" : "Inspect calibration"}
                      </Button>
                    </div>
                    <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
                      <RateBar label="Pass rate" pct={item.pass_rate_pct} detail={`${item.explained_count}/${item.reviewed_count}`} tone="var(--success-text)" />
                      <RateBar label="Passage match" pct={item.match_rate_pct} detail={`${item.match_count}/${item.answer_count}`} tone="var(--green-ink)" />
                      <RateBar label="Concern rate" pct={item.concern_rate_pct} detail={`${item.concern_count}/${item.reviewed_count}`} tone="var(--attention)" />
                    </div>
                    {isSelected && (
                      <div className="border-t border-[var(--line)] pt-3 stack">
                        {calLoading ? (
                          <p className="muted text-sm" role="status" aria-live="polite">Loading role calibration...</p>
                        ) : calError ? (
                          <RetryAlert message={calError} disabled={calLoading} onRetry={() => void loadCalibration(item.role_id)} />
                        ) : calibration && calibration.role_id === item.role_id && (
                          <>
                            <h3 className="text-sm font-semibold">Reviewer spread for {calibration.role_name}</h3>
                            <ReviewerTable rows={calibration.reviewer_summary} caption={`Reviewer calibration spread for ${calibration.role_name}`} />
                            {calibration.question_breakdown.length > 0 && (
                              <div className="stack !gap-2">
                                <h3 className="text-sm font-semibold">Question breakdown</h3>
                                {calibration.question_breakdown.map((q, idx) => (
                                  <div key={idx} className="rounded-md border border-[var(--line)] bg-[var(--subtle)] p-2.5 text-xs flex flex-wrap items-center justify-between gap-2">
                                    <span className="font-medium min-w-0">{q.planned_slot !== null ? `Q${q.planned_slot}: ` : ""}{q.question}</span>
                                    <span className="font-mono tabular-nums text-[var(--muted)]">
                                      Pass {q.pass_rate_pct.toFixed(0)}% | Match {q.match_rate_pct.toFixed(0)}% | Concern {q.concern_rate_pct.toFixed(0)}% | Disagreements {q.disagreement_count}
                                    </span>
                                  </div>
                                ))}
                              </div>
                            )}
                          </>
                        )}
                      </div>
                    )}
                  </div>
                )
              })}
            </div>
          )}
          <div className="stack !gap-2">
            <h3 className="text-sm font-semibold">Workspace reviewer spread</h3>
            <ReviewerTable rows={analytics.reviewer_summary} caption="Workspace reviewer calibration spread" />
          </div>
        </>
      )}
    </section>
  )
}
