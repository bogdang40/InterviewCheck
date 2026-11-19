import { adminRequest, type ConnectedModel, type ModelCapability } from "./adminModels"

export type TelemetrySource = "probe" | "live"

export type ModelTelemetrySummary = {
  total_checks: number
  ok_count: number
  error_count: number
  uptime_pct: number | null
  avg_latency_ms: number | null
  p95_latency_ms: number | null
  last_checked_at: string | null
  last_source: TelemetrySource | null
}

export type FleetTelemetrySummary = {
  total_models: number
  enabled_models: number
  connected_models: number
  error_models: number
  total_checks: number
  ok_checks: number
  uptime_pct: number | null
  avg_latency_ms: number | null
}

export type FleetTelemetryResponse = {
  summary: FleetTelemetrySummary
  models: Record<string, ModelTelemetrySummary>
}

export type ModelHealthCheck = {
  id: number
  model_id: string
  source: TelemetrySource
  ok: boolean
  http_status: number | null
  latency_ms: number | null
  error: string | null
  checked_at: string
}

export type ModelHealthResponse = {
  model: ConnectedModel
  summary: ModelTelemetrySummary
  history: ModelHealthCheck[]
}

export function getFleetTelemetry(): Promise<FleetTelemetryResponse> {
  return adminRequest<FleetTelemetryResponse>("/api/admin/models/telemetry")
}

export function getModelHealth(id: string, limit = 25): Promise<ModelHealthResponse> {
  const safeLimit = Math.max(1, Math.min(50, Math.trunc(limit)))
  return adminRequest<ModelHealthResponse>(
    `/api/admin/models/${encodeURIComponent(id)}/health?limit=${safeLimit}`,
  )
}

function compareText(a: string, b: string): number {
  if (a === b) return 0
  return a < b ? -1 : 1
}

export function computeFallbackRanks(models: ConnectedModel[]): Record<string, number> {
  const grouped = new Map<ModelCapability, ConnectedModel[]>()
  for (const model of models) {
    if (!model.enabled) continue
    const list = grouped.get(model.capability)
    if (list) list.push(model)
    else grouped.set(model.capability, [model])
  }

  const ranks: Record<string, number> = {}
  for (const candidates of grouped.values()) {
    candidates.sort((a, b) => {
      const defaultDiff = Number(b.is_default) - Number(a.is_default)
      if (defaultDiff !== 0) return defaultDiff
      const priA = a.parameters?.fallback_priority ?? 100
      const priB = b.parameters?.fallback_priority ?? 100
      if (priA !== priB) return priA - priB
      const updatedDiff = compareText(b.updated_at, a.updated_at)
      if (updatedDiff !== 0) return updatedDiff
      return compareText(a.id, b.id)
    })
    candidates.forEach((model, index) => {
      ranks[model.id] = index + 1
    })
  }
  return ranks
}

export function formatLatency(ms: number | null | undefined): string {
  if (ms === null || ms === undefined || !Number.isFinite(ms)) return "Not recorded"
  return `${Math.round(ms)} ms`
}

export function formatUptime(pct: number | null | undefined): string {
  if (pct === null || pct === undefined || !Number.isFinite(pct)) return "No checks"
  return `${pct.toFixed(1)}%`
}
