"use client"

import { useCallback, useEffect, useId, useRef, useState } from "react"
import { RefreshCw, X } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { AdminApiError, type ConnectedModel } from "@/lib/adminModels"
import {
  formatLatency,
  formatUptime,
  getModelHealth,
  type ModelHealthResponse,
} from "@/lib/adminTelemetry"
import { useDialogFocusTrap } from "@/lib/useDialogFocusTrap"

function formatCheckedAt(iso: string | null): string {
  if (!iso) return "Never"
  const date = new Date(iso)
  return Number.isNaN(date.getTime()) ? iso : date.toLocaleString()
}

function formatSourceLabel(source: "probe" | "live" | null): string {
  if (source === "live") return "Live traffic"
  if (source === "probe") return "Admin probe"
  return "No checks"
}

export function ModelHealthDrawer({
  model,
  onClose,
  onAuthInvalid,
}: {
  model: ConnectedModel
  onClose: () => void
  onAuthInvalid: (msg: string) => void
}) {
  const titleId = useId()
  const dialogRef = useRef<HTMLDivElement>(null)
  const [data, setData] = useState<ModelHealthResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState("")
  const mountedRef = useRef(true)

  useDialogFocusTrap({
    open: true,
    containerRef: dialogRef,
    onClose,
  })

  const load = useCallback(async () => {
    setLoading(true)
    setError("")
    try {
      const res = await getModelHealth(model.id, 25)
      if (!mountedRef.current) return
      setData(res)
    } catch (err) {
      if (!mountedRef.current) return
      if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) {
        onAuthInvalid(err.message)
        onClose()
        return
      }
      setError(err instanceof Error ? err.message : "Could not load model health history.")
    } finally {
      if (mountedRef.current) setLoading(false)
    }
  }, [model.id, onAuthInvalid, onClose])

  useEffect(() => {
    mountedRef.current = true
    void load()
    return () => {
      mountedRef.current = false
    }
  }, [load])

  const summary = data?.summary
  const history = data?.history ?? []

  return (
    <div
      className="admin-modal-backdrop"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose()
      }}
    >
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        tabIndex={-1}
        className="panel admin-modal admin-health-drawer"
      >
        <div className="admin-modal-head">
          <div>
            <h2 id={titleId}>Health history: {model.display_name}</h2>
            <span className="admin-mono">
              {model.slug} · {model.model_id}
            </span>
          </div>
          <div className="admin-drawer-actions">
            <Button
              type="button"
              variant="outline"
              size="sm"
              disabled={loading}
              onClick={() => void load()}
            >
              <RefreshCw size={14} aria-hidden="true" />
              Refresh
            </Button>
            <Button
              type="button"
              variant="ghost"
              size="icon-sm"
              aria-label="Close health drawer"
              onClick={onClose}
            >
              <X size={16} aria-hidden="true" />
            </Button>
          </div>
        </div>

        {error && (
          <p role="alert" className="error">
            {error}
          </p>
        )}

        {loading && !data ? (
          <p role="status" className="muted">
            Loading health history...
          </p>
        ) : (
          <>
            <section className="admin-health-summary" aria-label="Model health summary">
              <article className="panel inset admin-metric">
                <span className="admin-metric-label">Uptime</span>
                <strong>{formatUptime(summary?.uptime_pct)}</strong>
                <small>
                  {summary ? `${summary.ok_count} / ${summary.total_checks} ok` : "0 / 0 ok"}
                </small>
              </article>
              <article className="panel inset admin-metric">
                <span className="admin-metric-label">Avg latency</span>
                <strong>{formatLatency(summary?.avg_latency_ms)}</strong>
                <small>Mean response time</small>
              </article>
              <article className="panel inset admin-metric">
                <span className="admin-metric-label">P95 latency</span>
                <strong>{formatLatency(summary?.p95_latency_ms)}</strong>
                <small>95th percentile</small>
              </article>
              <article className="panel inset admin-metric">
                <span className="admin-metric-label">Last source</span>
                <strong>{formatSourceLabel(summary?.last_source ?? null)}</strong>
                <small>{formatCheckedAt(summary?.last_checked_at ?? null)}</small>
              </article>
            </section>

            {!history.length ? (
              <p className="panel inset muted">
                No health checks recorded yet. Run Test connection or route live traffic to record telemetry.
              </p>
            ) : (
              <div className="admin-table-wrap">
                <table className="admin-table">
                  <thead>
                    <tr>
                      <th>Checked at</th>
                      <th>Source</th>
                      <th>Result</th>
                      <th>Latency</th>
                      <th>Details</th>
                    </tr>
                  </thead>
                  <tbody>
                    {history.map((check) => {
                      const ok = Boolean(check.ok)
                      return (
                        <tr key={check.id}>
                          <td className="admin-mono">{formatCheckedAt(check.checked_at)}</td>
                          <td>
                            <Badge variant={check.source === "live" ? "default" : "secondary"}>
                              {check.source}
                            </Badge>
                          </td>
                          <td>
                            <div className="row">
                              <Badge variant={ok ? "success" : "destructive"}>
                                {ok ? "OK" : "Failed"}
                              </Badge>
                              {check.http_status != null && (
                                <span className="admin-mono">HTTP {check.http_status}</span>
                              )}
                            </div>
                          </td>
                          <td className="admin-mono">{formatLatency(check.latency_ms)}</td>
                          <td className="admin-mono">
                            {check.error ? check.error : ok ? "Healthy" : "Check failed"}
                          </td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  )
}
