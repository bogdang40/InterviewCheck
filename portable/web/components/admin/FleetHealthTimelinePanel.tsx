"use client"

import { useCallback, useEffect, useRef, useState } from "react"
import { Activity, Download, RefreshCw } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  downloadHealthTimelineExport, fetchHealthTimeline,
  type HealthTimelineResponse, type HealthTimelineSourceFilter,
} from "@/lib/adminHealthTimeline"
import { AdminApiError, CAPABILITY_LABELS, PROVIDER_LABELS, type ConnectedModel } from "@/lib/adminModels"
import { formatLatency, formatUptime } from "@/lib/adminTelemetry"

type Props = { models: ConnectedModel[]; refreshTick?: number; onAuthInvalid: (msg: string) => void }
type WindowPreset = { id: "1h" | "24h" | "7d" | "30d"; label: string; hours: number; bucketMinutes: number }

const WINDOW_PRESETS: readonly WindowPreset[] = [
  { id: "1h", label: "Last 1h (5m buckets)", hours: 1, bucketMinutes: 5 },
  { id: "24h", label: "Last 24h (1h buckets)", hours: 24, bucketMinutes: 60 },
  { id: "7d", label: "Last 7d (6h buckets)", hours: 168, bucketMinutes: 360 },
  { id: "30d", label: "Last 30d (24h buckets)", hours: 720, bucketMinutes: 1440 },
]
const fmtTime = (iso: string | null | undefined) =>
  !iso ? "-" : Number.isNaN(new Date(iso).getTime()) ? iso : new Date(iso).toLocaleString()
const fmtShortMs = (ms: number | null | undefined) =>
  ms === null || ms === undefined || !Number.isFinite(ms) ? "-" : `${Math.round(ms)}`

export function FleetHealthTimelinePanel({ models, refreshTick = 0, onAuthInvalid }: Props) {
  const [windowId, setWindowId] = useState<WindowPreset["id"]>("24h")
  const [modelId, setModelId] = useState("")
  const [source, setSource] = useState<HealthTimelineSourceFilter>("")
  const [timeline, setTimeline] = useState<HealthTimelineResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [exporting, setExporting] = useState<"csv" | "json" | null>(null)
  const [error, setError] = useState("")
  const [notice, setNotice] = useState("")
  const seqRef = useRef(0)

  const preset = WINDOW_PRESETS.find((w) => w.id === windowId) ?? WINDOW_PRESETS[1]

  useEffect(() => {
    if (modelId && models.length > 0 && !models.some((m) => m.id === modelId)) setModelId("")
  }, [modelId, models])

  const handleErr = useCallback((err: unknown, fallback: string) => {
    if (err instanceof DOMException && err.name === "AbortError") return
    if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) { onAuthInvalid(err.message); return }
    setError(err instanceof Error ? err.message : fallback)
  }, [onAuthInvalid])

  const loadTimeline = useCallback(async (signal?: AbortSignal) => {
    const seq = ++seqRef.current
    setLoading(true); setError("")
    try {
      const next = await fetchHealthTimeline(
        { hours: preset.hours, bucket_minutes: preset.bucketMinutes, model_id: modelId, source, limit: 50 },
        signal,
      )
      if (seq === seqRef.current) setTimeline(next)
    } catch (err) {
      if (seq === seqRef.current) handleErr(err, "Could not load fleet health timeline.")
    } finally {
      if (seq === seqRef.current) setLoading(false)
    }
  }, [preset.hours, preset.bucketMinutes, modelId, source, handleErr])

  useEffect(() => {
    const controller = new AbortController()
    void loadTimeline(controller.signal)
    return () => controller.abort()
  }, [loadTimeline, refreshTick])

  async function handleExport(format: "csv" | "json") {
    if (exporting !== null) return
    setExporting(format); setError(""); setNotice("")
    try {
      const filename = await downloadHealthTimelineExport(
        { hours: preset.hours, bucket_minutes: preset.bucketMinutes, model_id: modelId, source },
        format,
      )
      setNotice(`Exported ${filename}.`)
    } catch (err) {
      handleErr(err, `Could not export timeline as ${format.toUpperCase()}.`)
    } finally {
      setExporting(null)
    }
  }

  const summary = timeline?.summary
  const buckets = timeline?.buckets ?? []
  const events = timeline?.recent_events ?? []
  const busy = loading || exporting !== null
  const pTriplet = summary && (summary.p50_latency_ms !== null || summary.p95_latency_ms !== null || summary.p99_latency_ms !== null)
    ? `${fmtShortMs(summary.p50_latency_ms)} / ${fmtShortMs(summary.p95_latency_ms)} / ${fmtShortMs(summary.p99_latency_ms)} ms`
    : "Not recorded"

  return (
    <section className="panel stack" aria-label="Fleet health timeline">
      <div className="spread">
        <div>
          <h3 className="admin-sim-heading"><Activity size={17} aria-hidden="true" />Fleet health timeline</h3>
          <p className="muted">Time-bucketed probe and live health checks, latency percentiles, and CSV or JSON export.</p>
        </div>
        <div className="row">
          <Button type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8" disabled={busy} onClick={() => void loadTimeline()}>
            <RefreshCw size={14} aria-hidden="true" />Refresh timeline
          </Button>
          <Button type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8" disabled={busy} onClick={() => void handleExport("csv")}>
            <Download size={14} aria-hidden="true" />Export timeline CSV
          </Button>
          <Button type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8" disabled={busy} onClick={() => void handleExport("json")}>
            <Download size={14} aria-hidden="true" />Export timeline JSON
          </Button>
        </div>
      </div>

      <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
        <label className="field">
          Window
          <select aria-label="Timeline window" className="min-h-[44px] md:min-h-8" value={windowId} onChange={(e) => setWindowId(e.target.value as WindowPreset["id"])}>
            {WINDOW_PRESETS.map((w) => <option key={w.id} value={w.id}>{w.label}</option>)}
          </select>
        </label>
        <label className="field">
          Model
          <select aria-label="Filter timeline by model" className="min-h-[44px] md:min-h-8" value={modelId} onChange={(e) => setModelId(e.target.value)}>
            <option value="">All models</option>
            {models.map((m) => <option key={m.id} value={m.id}>{m.display_name}</option>)}
          </select>
        </label>
        <label className="field">
          Source
          <select aria-label="Filter timeline by source" className="min-h-[44px] md:min-h-8" value={source} onChange={(e) => setSource(e.target.value as HealthTimelineSourceFilter)}>
            <option value="">All</option>
            <option value="probe">probe</option>
            <option value="live">live</option>
          </select>
        </label>
      </div>

      {error && <p role="alert" className="error">{error}</p>}
      {notice && <p role="status" aria-live="polite" className="notice">{notice}</p>}

      <div className="admin-summary-grid" aria-label="Health timeline summary">
        <article className="panel inset admin-metric">
          <span className="admin-metric-label">Total checks</span>
          <strong>{summary?.total_checks ?? 0}</strong>
          <small>{summary?.ok_count ?? 0} ok, {summary?.error_count ?? 0} failed</small>
        </article>
        <article className="panel inset admin-metric">
          <span className="admin-metric-label">Uptime</span>
          <strong>{formatUptime(summary?.uptime_pct)}</strong>
          <small>{preset.label}</small>
        </article>
        <article className="panel inset admin-metric">
          <span className="admin-metric-label">P50 / P95 / P99</span>
          <strong style={{ fontSize: "clamp(18px, 1.7vw, 24px)" }}>{pTriplet}</strong>
          <small>Avg {formatLatency(summary?.avg_latency_ms)}</small>
        </article>
        <article className={`panel inset admin-metric${(summary?.models_with_errors ?? 0) > 0 ? " attention" : ""}`}>
          <span className="admin-metric-label">Models with errors</span>
          <strong>{summary?.models_with_errors ?? 0}</strong>
          <small>{summary?.error_count ?? 0} failed checks in window</small>
        </article>
      </div>

      {loading && !timeline ? (
        <p role="status" className="muted">Loading fleet health timeline...</p>
      ) : (
        <>
          {buckets.length > 0 ? (
            <div className="admin-table-wrap" aria-label="Health timeline buckets">
              <table className="admin-table">
                <thead><tr><th>Bucket</th><th>Checks</th><th>Uptime</th><th>Avg / P95</th><th>Availability</th></tr></thead>
                <tbody>
                  {buckets.map((b) => {
                    const pct = b.uptime_pct ?? 0
                    const tone = b.uptime_pct === null ? "" : pct < 80 ? " over" : pct < 99 ? " warn" : ""
                    return (
                      <tr key={b.bucket_start}>
                        <td className="admin-mono">{fmtTime(b.bucket_start)}</td>
                        <td className="admin-mono">{b.ok_count}/{b.total_checks} ok ({b.error_count} err)</td>
                        <td>{formatUptime(b.uptime_pct)}</td>
                        <td className="admin-mono">{formatLatency(b.avg_latency_ms)} / {formatLatency(b.p95_latency_ms)}</td>
                        <td>
                          <div className="admin-meter-track" role="progressbar" aria-label={`Bucket uptime ${fmtTime(b.bucket_start)}`} aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(pct)}>
                            <div className={`admin-meter-fill${tone}`} style={{ width: `${Math.max(0, Math.min(100, pct))}%` }} />
                          </div>
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          ) : (
            <p className="muted">No health-check buckets recorded for the selected window and filters.</p>
          )}

          {events.length > 0 ? (
            <div className="admin-table-wrap" aria-label="Recent health check events">
              <table className="admin-table">
                <thead><tr><th>Checked at</th><th>Model</th><th>Source</th><th>Status</th><th>Latency</th><th>Error</th></tr></thead>
                <tbody>
                  {events.map((ev) => (
                    <tr key={ev.id}>
                      <td className="admin-mono">{fmtTime(ev.checked_at)}</td>
                      <td>
                        <div>{ev.display_name || ev.slug}</div>
                        <div className="admin-mono">
                          {PROVIDER_LABELS[ev.provider as keyof typeof PROVIDER_LABELS] ?? ev.provider} / {CAPABILITY_LABELS[ev.capability as keyof typeof CAPABILITY_LABELS] ?? ev.capability}
                        </div>
                      </td>
                      <td><Badge variant="outline">{ev.source || "-"}</Badge></td>
                      <td><Badge variant={ev.ok ? "success" : "destructive"}>{ev.ok ? "OK" : "Error"}{ev.http_status !== null ? ` (${ev.http_status})` : ""}</Badge></td>
                      <td className="admin-mono">{formatLatency(ev.latency_ms)}</td>
                      <td>{ev.error || "-"}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <p className="muted">No health check events match the selected filters.</p>
          )}
        </>
      )}
    </section>
  )
}
