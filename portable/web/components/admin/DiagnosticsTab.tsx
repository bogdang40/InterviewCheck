"use client"

import { useCallback, useEffect, useRef, useState } from "react"
import { Activity, Download, Mic, RefreshCw, Square } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  computeFleetP95Latency,
  downloadDiagnosticBundle,
  formatCompactTokens,
  formatUsd,
  getAdminDiagnostics,
  readBudgetParameters,
  type DiagnosticsData,
} from "@/lib/adminDiagnostics"
import { AdminApiError, CAPABILITY_LABELS, PROVIDER_LABELS, type ConnectedModel } from "@/lib/adminModels"
import { formatLatency, formatUptime } from "@/lib/adminTelemetry"
import { FleetHealthTimelinePanel } from "./FleetHealthTimelinePanel"
import { KeyRotationCard } from "./KeyRotationCard"

type AudioCheck = {
  stream?: MediaStream
  context?: AudioContext
  source?: MediaStreamAudioSourceNode
  analyser?: AnalyserNode
  interval?: number
  timeout?: number
  peak: number
  ended: () => void
}

function MeterBar({ label, value, limit, text }: { label: string; value: number; limit: number | null; text: string }) {
  const max = limit && limit > 0 ? limit : Math.max(value, 1)
  const pct = limit && limit > 0 ? Math.min(100, Math.round((value / limit) * 100)) : value > 0 ? 100 : 0
  const tone = limit && limit > 0 ? (value >= limit ? " over" : value >= limit * 0.8 ? " warn" : "") : ""
  return (
    <div className="admin-diag-bar">
      <div className="spread"><span className="admin-mono">{label}</span><span className="admin-mono">{text}</span></div>
      <div className="admin-meter-track" role="progressbar" aria-label={label} aria-valuemin={0} aria-valuemax={Number(max.toFixed(2))} aria-valuenow={Number(Math.min(max, value).toFixed(2))}>
        <div className={`admin-meter-fill${tone}`} style={{ width: `${pct}%` }} />
      </div>
    </div>
  )
}

export function DiagnosticsTab({ models, onAuthInvalid }: { models: ConnectedModel[]; onAuthInvalid: (msg: string) => void }) {
  const [data, setData] = useState<DiagnosticsData | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState("")
  const [audioPhase, setAudioPhase] = useState<"idle" | "checking" | "done">("idle")
  const [audioLevel, setAudioLevel] = useState(-72)
  const [audioStatus, setAudioStatus] = useState("")
  const [audioMeta, setAudioMeta] = useState("")
  const [keyRefreshTick, setKeyRefreshTick] = useState(0)
  const [exporting, setExporting] = useState(false)
  const [exportStatus, setExportStatus] = useState("")
  const mountedRef = useRef(true)
  const audioRef = useRef<AudioCheck | null>(null)

  const handleExportBundle = useCallback(async () => {
    if (exporting) return
    setExporting(true); setError(""); setExportStatus("")
    try {
      const filename = await downloadDiagnosticBundle()
      if (mountedRef.current) setExportStatus(`Downloaded diagnostic bundle (${filename}).`)
    } catch (err) {
      if (!mountedRef.current) return
      if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) { onAuthInvalid(err.message); return }
      setError(err instanceof Error ? err.message : "Could not export diagnostic bundle.")
    } finally {
      if (mountedRef.current) setExporting(false)
    }
  }, [exporting, onAuthInvalid])

  const stopAudioCheck = useCallback((message: string, updateState = true) => {
    const check = audioRef.current
    if (!check) return
    audioRef.current = null
    window.clearInterval(check.interval)
    window.clearTimeout(check.timeout)
    check.stream?.getTracks().forEach((t) => { t.removeEventListener("ended", check.ended); t.stop() })
    check.source?.disconnect()
    check.analyser?.disconnect()
    if (check.context && check.context.state !== "closed") void check.context.close().catch(() => {})
    if (updateState && mountedRef.current) { setAudioPhase("done"); setAudioStatus(message) }
  }, [])

  const load = useCallback(async () => {
    setLoading(true); setError("")
    try {
      const next = await getAdminDiagnostics()
      if (mountedRef.current) setData(next)
    } catch (err) {
      if (!mountedRef.current) return
      if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) { onAuthInvalid(err.message); return }
      setError(err instanceof Error ? err.message : "Could not load diagnostics.")
    } finally {
      if (mountedRef.current) setLoading(false)
    }
  }, [onAuthInvalid])

  useEffect(() => {
    mountedRef.current = true
    void load()
    const onHide = () => { if (document.hidden) stopAudioCheck("Audio diagnostic stopped because the tab was hidden.") }
    document.addEventListener("visibilitychange", onHide)
    return () => { mountedRef.current = false; document.removeEventListener("visibilitychange", onHide); stopAudioCheck("", false) }
  }, [load, stopAudioCheck])

  async function startAudioCheck() {
    if (audioRef.current) return
    const check: AudioCheck = { peak: -Infinity, ended: () => stopAudioCheck("Audio input track ended.") }
    audioRef.current = check
    setAudioPhase("checking"); setAudioLevel(-72); setAudioMeta("")
    setAudioStatus("Requesting microphone permission for Web Audio diagnostic…")
    try {
      const devices = navigator.mediaDevices
      if (typeof AudioContext === "undefined" || !devices?.getUserMedia) {
        stopAudioCheck("Web Audio API or MediaDevices is unavailable in this browser."); return
      }
      const context = new AudioContext()
      check.context = context
      const stream = await devices.getUserMedia({ audio: true })
      if (audioRef.current !== check) { stream.getTracks().forEach((t) => t.stop()); return }
      check.stream = stream
      const tracks = stream.getAudioTracks().filter((t) => t.readyState === "live")
      if (!tracks.length) { stopAudioCheck("No live microphone track returned."); return }
      tracks.forEach((t) => t.addEventListener("ended", check.ended, { once: true }))
      if (context.state === "suspended") await context.resume()
      const source = context.createMediaStreamSource(new MediaStream(tracks))
      const analyser = context.createAnalyser()
      analyser.fftSize = 1024
      source.connect(analyser)
      check.source = source; check.analyser = analyser
      setAudioMeta(`${tracks[0].label || "Microphone"} · ${context.sampleRate} Hz`)
      setAudioStatus("Sampling audio input level for 3 seconds…")
      const frame = new Float32Array(analyser.fftSize)
      const sample = () => {
        analyser.getFloatTimeDomainData(frame)
        let sq = 0
        for (const v of frame) sq += v * v
        const rms = Math.sqrt(sq / frame.length)
        const db = rms > 0 ? 20 * Math.log10(rms) : -Infinity
        check.peak = Math.max(check.peak, db)
        if (mountedRef.current) setAudioLevel(Math.max(-72, Math.min(0, db)))
      }
      sample()
      check.interval = window.setInterval(sample, 100)
      check.timeout = window.setTimeout(() => {
        stopAudioCheck(check.peak >= -55 ? `Audio input verified. Peak ${Math.round(check.peak)} dBFS.` : "Microphone connected, but signal remained quiet (-55 dBFS or below).")
      }, 3000)
    } catch (err) {
      stopAudioCheck(err instanceof Error ? `Audio check failed: ${err.message}` : "Audio check failed.")
    }
  }

  const summary = data?.telemetry?.summary
  const fleetP95 = computeFleetP95Latency(data?.telemetry)
  const checkErrors = summary ? Math.max(0, summary.total_checks - summary.ok_checks) : 0
  const trans = data?.transcription

  return (
    <section className="stack" aria-label="System and model diagnostics">
      <div className="panel inset spread">
        <div>
          <h2>Diagnostics &amp; usage</h2>
          <p className="muted">Daily token budgets, monthly estimated spend thresholds, fleet P95 latency, transcription readiness, and local audio capture.</p>
        </div>
        <div className="row">
          <Button type="button" variant="outline" size="sm" disabled={exporting} onClick={() => void handleExportBundle()}>
            <Download size={14} aria-hidden="true" />
            {exporting ? "Exporting..." : "Export diagnostic bundle"}
          </Button>
          <Button type="button" variant="outline" size="sm" disabled={loading} onClick={() => { setKeyRefreshTick((n) => n + 1); void load() }}>
            <RefreshCw size={14} aria-hidden="true" />
            {loading ? "Refreshing…" : "Refresh diagnostics"}
          </Button>
        </div>
      </div>

      {error && <p role="alert" className="error">{error}</p>}
      {exportStatus && <p role="status" aria-live="polite" className="notice">{exportStatus}</p>}

      <div className="admin-summary-grid" aria-label="Fleet diagnostic summary">
        <article className="panel admin-metric">
          <div className="admin-metric-label"><span>Fleet P95 latency</span><Activity size={15} aria-hidden="true" /></div>
          <strong>{formatLatency(fleetP95)}</strong>
          <small>Avg {formatLatency(summary?.avg_latency_ms)} · Uptime {formatUptime(summary?.uptime_pct)}</small>
        </article>
        <article className={`panel admin-metric${checkErrors > 0 || (summary?.error_models ?? 0) > 0 ? " attention" : ""}`}>
          <div className="admin-metric-label"><span>Fleet errors</span></div>
          <strong>{checkErrors}</strong>
          <small>{summary?.error_models ?? 0} models in error · {data?.usageSummary.daily_errors ?? 0} request errors today</small>
        </article>
        <article className="panel admin-metric">
          <div className="admin-metric-label"><span>Daily tokens &amp; spend</span></div>
          <strong>{formatCompactTokens(data?.usageSummary.daily_tokens ?? 0)}</strong>
          <small>Estimated monthly spend {formatUsd(data?.usageSummary.monthly_cost_usd ?? 0)} · {data?.usageSummary.daily_requests ?? 0} reqs today</small>
        </article>
        <article className="panel admin-metric">
          <div className="admin-metric-label"><span>Transcription pipeline</span></div>
          <div className="admin-model-title">
            <Badge variant={trans?.ready ? "success" : "warning"}>{trans?.ready ? "Ready" : "Not ready"}</Badge>
            <span className="admin-mono">{trans?.candidate_count ?? 0} candidates</span>
          </div>
          <small className="admin-mono">{trans?.active_provider ? `${trans.active_provider}${trans.active_model ? ` · ${trans.active_model}` : ""}` : "No active transcription provider"}</small>
        </article>
      </div>

      <section className="panel stack" aria-label="Per-model usage and budgets">
        <h3>Per-model token and cost usage</h3>
        {loading && !data ? (
          <p role="status" className="muted">Loading usage diagnostics…</p>
        ) : !models.length ? (
          <p className="muted">No connected models registered yet.</p>
        ) : (
          <div className="admin-diag-list">
            {models.map((m) => {
              const u = data?.usageByModel[m.id]
              const t = data?.telemetry?.models?.[m.id]
              const cfg = readBudgetParameters(m.parameters)
              const dailyLim = u?.daily_token_limit ?? cfg.daily_token_limit ?? null
              const monthlyLim = u?.monthly_cost_limit_usd ?? cfg.monthly_cost_limit_usd ?? null
              const dailyTok = u?.daily_tokens ?? 0
              const monthlyUsd = u?.monthly_cost_usd ?? 0
              return (
                <article key={m.id} className="panel inset admin-diag-card">
                  <div className="spread">
                    <div className="admin-model-title">
                      <strong>{m.display_name}</strong>
                      <Badge variant="outline">{PROVIDER_LABELS[m.provider] ?? m.provider}</Badge>
                      <Badge variant="secondary">{CAPABILITY_LABELS[m.capability] ?? m.capability}</Badge>
                    </div>
                    <span className="admin-mono">P95 {formatLatency(t?.p95_latency_ms)} · Errors {t?.error_count ?? 0}</span>
                  </div>
                  <div className="admin-diag-bars">
                    <MeterBar label={`Daily tokens (${m.slug})`} value={dailyTok} limit={dailyLim} text={dailyLim ? `${dailyTok.toLocaleString()} / ${dailyLim.toLocaleString()}` : `${dailyTok.toLocaleString()} (No limit)`} />
                    <MeterBar label={`Monthly estimated spend (${m.slug})`} value={monthlyUsd} limit={monthlyLim} text={monthlyLim ? `${formatUsd(monthlyUsd)} / ${formatUsd(monthlyLim)}` : `${formatUsd(monthlyUsd)} (No threshold)`} />
                  </div>
                </article>
              )
            })}
          </div>
        )}
      </section>

      <section className="panel stack admin-audio-diag" aria-label="Audio input diagnostic">
        <div className="spread">
          <div>
            <h3>Browser audio-input diagnostic</h3>
            <p className="muted">Verify local Web Audio API capture (AudioContext + AnalyserNode) before live sessions.</p>
          </div>
          <div className="row">
            <Button type="button" size="sm" variant="outline" disabled={audioPhase === "checking"} onClick={() => void startAudioCheck()}>
              <Mic size={14} aria-hidden="true" />
              {audioPhase === "checking" ? "Checking…" : "Run audio input check"}
            </Button>
            {audioPhase === "checking" && (
              <Button type="button" size="sm" variant="ghost" onClick={() => stopAudioCheck("Audio diagnostic stopped.")}>
                <Square size={14} aria-hidden="true" />
                Stop audio check
              </Button>
            )}
          </div>
        </div>
        {audioPhase === "checking" && (
          <label className="field">
            Live input level (dBFS)
            <meter className="admin-audio-meter" min={-72} max={0} value={audioLevel} aria-label="Diagnostic audio input level in dBFS" />
          </label>
        )}
        {audioMeta && <span className="admin-mono">{audioMeta}</span>}
        {audioStatus && <p role="status" className="notice">{audioStatus}</p>}
      </section>

      <FleetHealthTimelinePanel models={models} refreshTick={keyRefreshTick} onAuthInvalid={onAuthInvalid} />

      <KeyRotationCard onAuthInvalid={onAuthInvalid} refreshSignal={keyRefreshTick} />
    </section>
  )
}
