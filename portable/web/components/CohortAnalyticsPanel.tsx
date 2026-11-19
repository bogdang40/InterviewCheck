"use client"

import Link from "next/link"
import { useEffect, useState } from "react"
import { BarChart3, Download, RefreshCw, X } from "lucide-react"
import { dateLabel, message } from "@/lib/api"
import {
  downloadCohortExport, fetchCohortAnalytics, fetchCohortRoles,
  type CohortAnalyticsResponse, type CohortExportFormat, type CohortFilters,
  type CohortLifecycle, type CohortRoleOption,
} from "@/lib/cohortAnalytics"
import { interviewURL } from "@/lib/workspace"
import styles from "./CohortAnalyticsPanel.module.css"
import WorkspaceError from "./WorkspaceError"
import { Badge } from "./ui/badge"
import { Button } from "./ui/button"
import { Input } from "./ui/input"

const formatPct = (value: number | null) => (value === null ? "N/A" : `${value.toFixed(1)}%`)
const lifecycleVariant = (lifecycle: string): "default" | "success" | "secondary" =>
  lifecycle === "finished" ? "success" : lifecycle === "active" ? "default" : "secondary"

export default function CohortAnalyticsPanel() {
  const [roleId, setRoleId] = useState("")
  const [tag, setTag] = useState("")
  const [lifecycle, setLifecycle] = useState<CohortLifecycle>("")
  const [since, setSince] = useState("")
  const [until, setUntil] = useState("")
  const [roles, setRoles] = useState<CohortRoleOption[]>([])
  const [data, setData] = useState<CohortAnalyticsResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState("")
  const [exportBusy, setExportBusy] = useState<CohortExportFormat | null>(null)
  const [exportError, setExportError] = useState("")
  const [exportNotice, setExportNotice] = useState("")
  const [refreshSeq, setRefreshSeq] = useState(0)

  const invalidRange = Boolean(since && until && since > until)
  const filters: CohortFilters = { roleId, tag, lifecycle, since, until }
  const hasFilters = Boolean(roleId || tag.trim() || lifecycle || since || until)

  useEffect(() => {
    const controller = new AbortController()
    fetchCohortRoles(controller.signal).then(setRoles).catch(() => {})
    return () => controller.abort()
  }, [])

  useEffect(() => {
    if (invalidRange) {
      setLoading(false)
      setError("The start date must be on or before the end date.")
      return
    }
    const controller = new AbortController()
    setLoading(true)
    setError("")
    fetchCohortAnalytics({ roleId, tag, lifecycle, since, until }, controller.signal)
      .then(setData)
      .catch((err) => {
        if (!(err instanceof DOMException && err.name === "AbortError")) setError(message(err))
      })
      .finally(() => { if (!controller.signal.aborted) setLoading(false) })
    return () => controller.abort()
  }, [roleId, tag, lifecycle, since, until, invalidRange, refreshSeq])

  function clearFilters() {
    setRoleId(""); setTag(""); setLifecycle(""); setSince(""); setUntil("")
  }

  async function handleExport(format: CohortExportFormat) {
    if (exportBusy || invalidRange) return
    setExportBusy(format); setExportError(""); setExportNotice("")
    try {
      const filename = await downloadCohortExport(filters, format)
      setExportNotice(`Exported cohort analytics to ${filename}.`)
    } catch (err) {
      setExportError(message(err))
    } finally {
      setExportBusy(null)
    }
  }

  const maxBucket = data ? Math.max(1, ...data.score_buckets.map((b) => b.count)) : 1
  const summary = data?.summary
  const metricCards = summary ? [
    ["Sessions", String(summary.session_count), `${summary.active_count} active / ${summary.finished_count} finished / ${summary.archived_count} archived`],
    ["Reviewed answers", `${summary.reviewed_count} / ${summary.answer_count}`, "Dispositions recorded"],
    ["Pass rate", formatPct(summary.pass_rate_pct), "Explained of reviewed"],
    ["Concern rate", formatPct(summary.concern_rate_pct), "Unresolved or disclosed"],
    ["Avg scorecard", formatPct(summary.avg_scorecard_pct), `${summary.scored_session_count} scored sessions`],
  ] : []

  return (
    <section className={`panel ${styles.panel}`} aria-labelledby="cohort-analytics-heading">
      <div className={styles.header}>
        <div className={styles.headerText}>
          <span className="eyebrow">COHORT ANALYTICS</span>
          <h2 id="cohort-analytics-heading" className="flex items-center gap-2">
            <BarChart3 className="size-5 shrink-0" aria-hidden="true" />
            <span>Cohort analytics and scorecard calibration</span>
          </h2>
          <p className="muted text-sm">Filter interview cohorts by role, tag, lifecycle, and date window, then export CSV or JSON reports.</p>
        </div>
        <div className={styles.headerActions}>
          <Button type="button" variant="outline" size="sm" disabled={loading} onClick={() => setRefreshSeq((n) => n + 1)}>
            <RefreshCw aria-hidden="true" />Refresh
          </Button>
          <Button type="button" variant="outline" size="sm" disabled={!!exportBusy || invalidRange} onClick={() => void handleExport("csv")}>
            <Download aria-hidden="true" />{exportBusy === "csv" ? "Exporting CSV..." : "Export CSV"}
          </Button>
          <Button type="button" variant="outline" size="sm" disabled={!!exportBusy || invalidRange} onClick={() => void handleExport("json")}>
            <Download aria-hidden="true" />{exportBusy === "json" ? "Exporting JSON..." : "Export JSON"}
          </Button>
        </div>
      </div>

      <div className={styles.filters} role="region" aria-label="Cohort filters">
        <label className={`field ${styles.filterField}`}>
          Role
          <select aria-label="Filter cohort by role" value={roleId} onChange={(e) => setRoleId(e.target.value)}>
            <option value="">All roles</option>
            {roles.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
          </select>
        </label>
        <label className={`field ${styles.filterField}`}>
          Tag
          <Input type="search" maxLength={32} placeholder="Exact tag" value={tag} onChange={(e) => setTag(e.target.value)} />
        </label>
        <label className={`field ${styles.filterField}`}>
          Lifecycle
          <select aria-label="Filter cohort by lifecycle" value={lifecycle} onChange={(e) => setLifecycle(e.target.value as CohortLifecycle)}>
            <option value="">All lifecycles</option>
            <option value="active">In progress</option>
            <option value="finished">Finished</option>
            <option value="archived">Archived</option>
          </select>
        </label>
        <label className={`field ${styles.filterField}`}>
          Since date
          <Input type="date" aria-label="Cohort start date" value={since} onChange={(e) => setSince(e.target.value)} />
        </label>
        <label className={`field ${styles.filterField}`}>
          Until date
          <Input type="date" aria-label="Cohort end date" value={until} onChange={(e) => setUntil(e.target.value)} />
        </label>
      </div>

      {hasFilters && (
        <div>
          <Button type="button" variant="ghost" size="sm" onClick={clearFilters}>
            <X aria-hidden="true" />Clear cohort filters
          </Button>
        </div>
      )}

      {exportError && <p className="error" role="alert">{exportError}</p>}
      {exportNotice && <p className="notice" role="status">{exportNotice}</p>}
      {error && <WorkspaceError text={error} retry={() => setRefreshSeq((n) => n + 1)} />}
      {loading && !data && !error && <p className="muted text-sm" role="status">Loading cohort analytics...</p>}

      {data && summary && !error && (
        <>
          <div className={styles.metrics}>
            {metricCards.map(([label, value, sub]) => (
              <div key={label} className={styles.metricCard}>
                <span className={styles.metricLabel}>{label}</span>
                <strong className={styles.metricValue}>{value}</strong>
                <span className={styles.metricSub}>{sub}</span>
              </div>
            ))}
          </div>

          {summary.session_count === 0 ? (
            <div className={styles.emptyBox}>
              <strong>No interviews match this cohort</strong>
              <p className="muted text-sm">Adjust or clear the cohort filters to inspect sessions and scorecards.</p>
              {hasFilters && <Button type="button" variant="outline" size="sm" onClick={clearFilters}>Clear filters</Button>}
            </div>
          ) : (
            <>
              <div className={styles.chartsGrid}>
                <div className={styles.cardBox}>
                  <h3 className={styles.cardTitle}>Scorecard distribution</h3>
                  <div className={styles.histogram} aria-label="Scorecard distribution histogram">
                    {data.score_buckets.map((bucket) => {
                      const pct = Math.round((bucket.count / maxBucket) * 100)
                      return (
                        <div key={bucket.range} className={styles.bucketRow}>
                          <div className={styles.bucketMeta}><span>{bucket.label}</span><span>{bucket.count}</span></div>
                          <div className={styles.barTrack} role="presentation">
                            <div className={styles.barFill} style={{ width: `${bucket.count > 0 ? Math.max(4, pct) : 0}%` }} />
                          </div>
                        </div>
                      )
                    })}
                  </div>
                  {summary.scored_session_count === 0 && <p className="muted text-xs">No saved scorecards in this cohort yet.</p>}
                </div>

                <div className={styles.cardBox}>
                  <h3 className={styles.cardTitle}>Tag breakdown</h3>
                  {data.tag_breakdown.length === 0 ? (
                    <p className="muted text-sm">No tagged interviews in this cohort.</p>
                  ) : (
                    <div className={styles.tableWrap}>
                      <table className={styles.table}>
                        <caption className="sr-only">Cohort performance by tag</caption>
                        <thead><tr><th>Tag</th><th>Sessions</th><th>Pass rate</th><th>Avg score</th></tr></thead>
                        <tbody>
                          {data.tag_breakdown.map((row) => (
                            <tr key={row.tag}>
                              <td data-label="Tag"><button type="button" className={styles.tagButton} onClick={() => setTag(row.tag)}>{row.tag}</button></td>
                              <td data-label="Sessions" className="tabular-nums">{row.session_count}</td>
                              <td data-label="Pass rate" className="tabular-nums">{formatPct(row.pass_rate_pct)}</td>
                              <td data-label="Avg score" className="tabular-nums">{formatPct(row.avg_scorecard_pct)}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  )}
                </div>
              </div>

              {data.timeline.length > 0 && (
                <div className={styles.cardBox}>
                  <h3 className={styles.cardTitle}>Daily activity timeline</h3>
                  <div className={styles.tableWrap}>
                    <table className={styles.table}>
                      <caption className="sr-only">Daily cohort timeline</caption>
                      <thead><tr><th>Date (UTC)</th><th>Sessions</th><th>Finished</th><th>Explained</th><th>Concerns</th></tr></thead>
                      <tbody>
                        {data.timeline.map((pt) => (
                          <tr key={pt.date}>
                            <td data-label="Date (UTC)" className="tabular-nums">{pt.date}</td>
                            <td data-label="Sessions" className="tabular-nums">{pt.sessions}</td>
                            <td data-label="Finished" className="tabular-nums">{pt.finished}</td>
                            <td data-label="Explained" className="tabular-nums">{pt.explained}</td>
                            <td data-label="Concerns" className="tabular-nums">{pt.concerns}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </div>
              )}

              <div className={styles.cardBox}>
                <h3 className={styles.cardTitle}>Candidate pipeline ({data.candidates.length})</h3>
                <div className={styles.tableWrap}>
                  <table className={styles.table}>
                    <caption className="sr-only">Cohort candidate pipeline</caption>
                    <thead>
                      <tr>
                        <th>Candidate</th><th>Role</th><th>Lifecycle</th><th>Tags</th>
                        <th>Answers</th><th>Matches</th><th>Concerns</th><th>Scorecard</th>
                      </tr>
                    </thead>
                    <tbody>
                      {data.candidates.map((row) => (
                        <tr key={row.session_id}>
                          <td data-label="Candidate">
                            <Link className={styles.candidateLink} href={interviewURL(row.session_id)}>
                              {row.candidate || "Unnamed candidate"}
                            </Link>
                            <div className="muted text-xs">{dateLabel(row.created_at)}</div>
                          </td>
                          <td data-label="Role">{row.role || "Role unspecified"}</td>
                          <td data-label="Lifecycle"><Badge variant={lifecycleVariant(row.lifecycle)}>{row.lifecycle}</Badge></td>
                          <td data-label="Tags">
                            <div className={styles.tagRow}>
                              {row.tags.length ? row.tags.map((t) => <span key={t} className={styles.tagPill}>{t}</span>) : <span className="muted">None</span>}
                            </div>
                          </td>
                          <td data-label="Answers" className="tabular-nums">{row.answer_count}</td>
                          <td data-label="Matches" className="tabular-nums">{row.match_count}</td>
                          <td data-label="Concerns" className="tabular-nums">{row.concern_count}</td>
                          <td data-label="Scorecard" className="tabular-nums">{formatPct(row.weighted_score_pct)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            </>
          )}
        </>
      )}
    </section>
  )
}
