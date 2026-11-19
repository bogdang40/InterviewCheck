"use client"

import { Activity, AlertTriangle, CheckCircle2, Cpu, Gauge, Layers } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import {
  CAPABILITY_LABELS,
  PROVIDER_LABELS,
  type ConnectedModel,
  type EnvFallback,
} from "@/lib/adminModels"
import {
  formatLatency,
  formatUptime,
  type FleetTelemetrySummary,
} from "@/lib/adminTelemetry"

export function ModelSummaryCards({
  models,
  envFallbacks,
  telemetry,
}: {
  models: ConnectedModel[]
  envFallbacks: EnvFallback[]
  telemetry?: FleetTelemetrySummary | null
}) {
  const defaultCount = models.filter((m) => m.is_default).length
  const enabledCount = models.filter((m) => m.enabled).length
  const connectedCount = models.filter((m) => m.status === "connected").length
  const errorCount = models.filter((m) => m.status === "error").length
  const configuredFallbacks = envFallbacks.filter((f) => f.configured).length
  const totalChecks = telemetry?.total_checks ?? 0
  const okChecks = telemetry?.ok_checks ?? 0

  return (
    <div className="stack">
      <section className="admin-summary-grid" aria-label="Model registry summary">
        <article className="panel admin-metric">
          <div className="admin-metric-label">
            <span>Connected models</span>
            <Cpu size={15} aria-hidden="true" />
          </div>
          <strong>{models.length}</strong>
          <small>{defaultCount} default slots</small>
        </article>
        <article className="panel admin-metric">
          <div className="admin-metric-label">
            <span>Enabled</span>
            <CheckCircle2 size={15} aria-hidden="true" />
          </div>
          <strong>{enabledCount}</strong>
          <small>{connectedCount} verified</small>
        </article>
        <article className={`panel admin-metric${errorCount > 0 ? " attention" : ""}`}>
          <div className="admin-metric-label">
            <span>Attention needed</span>
            <AlertTriangle size={15} aria-hidden="true" />
          </div>
          <strong>{errorCount}</strong>
          <small>Probe or credential errors</small>
        </article>
        <article className="panel admin-metric">
          <div className="admin-metric-label">
            <span>Env fallbacks</span>
            <Layers size={15} aria-hidden="true" />
          </div>
          <strong>{configuredFallbacks}</strong>
          <small>Active when no DB model exists</small>
        </article>
      </section>
      <section className="admin-telemetry-strip" aria-label="Fleet telemetry summary">
        <article className="panel admin-metric">
          <div className="admin-metric-label">
            <span>Fleet uptime</span>
            <Activity size={15} aria-hidden="true" />
          </div>
          <strong>{formatUptime(telemetry?.uptime_pct)}</strong>
          <small>
            {okChecks} / {totalChecks} checks passed
          </small>
        </article>
        <article className="panel admin-metric">
          <div className="admin-metric-label">
            <span>Fleet avg latency</span>
            <Gauge size={15} aria-hidden="true" />
          </div>
          <strong>{formatLatency(telemetry?.avg_latency_ms)}</strong>
          <small>{totalChecks} checks recorded</small>
        </article>
      </section>
      <details className="panel inset">
        <summary>Environment fallbacks ({configuredFallbacks} configured)</summary>
        <div className="admin-table-wrap">
          <table className="admin-table">
            <thead>
              <tr>
                <th>Provider</th>
                <th>Capability</th>
                <th>Model ID</th>
                <th>Server status</th>
                <th>Registry override</th>
              </tr>
            </thead>
            <tbody>
              {envFallbacks.map((item) => {
                const overridden = models.some(
                  (m) => m.provider === item.provider && m.capability === item.capability,
                )
                return (
                  <tr key={`${item.provider}-${item.capability}`}>
                    <td>{PROVIDER_LABELS[item.provider] ?? item.provider}</td>
                    <td>{CAPABILITY_LABELS[item.capability] ?? item.capability}</td>
                    <td className="admin-mono">{item.model_id || "-"}</td>
                    <td>
                      <Badge variant={item.configured ? "success" : "secondary"}>
                        {item.configured ? "Configured" : "Not configured"}
                      </Badge>
                    </td>
                    <td>
                      {overridden ? (
                        <Badge variant="default">Overridden by registry</Badge>
                      ) : (
                        <span className="muted">Fallback eligible</span>
                      )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      </details>
    </div>
  )
}
