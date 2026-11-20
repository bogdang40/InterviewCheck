import { AdminApiError, extractApiError } from "./adminModels"

export type HealthTimelineSourceFilter = "" | "probe" | "live"
export type HealthTimelineFilters = {
  hours?: number; bucket_minutes?: number; model_id?: string; capability?: string
  source?: HealthTimelineSourceFilter; limit?: number
}
export type HealthTimelineWindow = { hours: number; bucket_minutes: number; since: string; until: string }
export type HealthTimelineSummary = {
  total_checks: number; ok_count: number; error_count: number; uptime_pct: number | null
  avg_latency_ms: number | null; p50_latency_ms: number | null; p95_latency_ms: number | null
  p99_latency_ms: number | null; models_with_errors: number
}
export type HealthTimelineBucket = {
  bucket_start: string; total_checks: number; ok_count: number; error_count: number
  uptime_pct: number | null; avg_latency_ms: number | null; p95_latency_ms: number | null
}
export type HealthTimelineEvent = {
  id: number; model_id: string; slug: string; display_name: string; provider: string; capability: string
  source: "probe" | "live" | string; ok: boolean; http_status: number | null; latency_ms: number | null
  error: string | null; checked_at: string
}
export type HealthTimelineResponse = {
  window: HealthTimelineWindow; summary: HealthTimelineSummary
  buckets: HealthTimelineBucket[]; recent_events: HealthTimelineEvent[]
}

const numOrNull = (val: unknown): number | null => (typeof val === "number" && Number.isFinite(val) ? val : null)
const numOrZero = (val: unknown): number => (typeof val === "number" && Number.isFinite(val) ? val : 0)
const asRec = (val: unknown): Record<string, unknown> =>
  val && typeof val === "object" && !Array.isArray(val) ? (val as Record<string, unknown>) : {}

export function buildHealthTimelineParams(filters: HealthTimelineFilters = {}): URLSearchParams {
  const params = new URLSearchParams()
  if (typeof filters.hours === "number" && Number.isFinite(filters.hours) && filters.hours >= 1) {
    params.set("hours", String(Math.trunc(filters.hours)))
  }
  if (typeof filters.bucket_minutes === "number" && Number.isFinite(filters.bucket_minutes) && filters.bucket_minutes >= 5) {
    params.set("bucket_minutes", String(Math.trunc(filters.bucket_minutes)))
  }
  if (filters.model_id?.trim()) params.set("model_id", filters.model_id.trim())
  if (filters.capability?.trim()) params.set("capability", filters.capability.trim())
  if (filters.source === "probe" || filters.source === "live") params.set("source", filters.source)
  if (typeof filters.limit === "number" && Number.isFinite(filters.limit) && filters.limit >= 1) {
    params.set("limit", String(Math.trunc(filters.limit)))
  }
  return params
}

function normalizeTimeline(raw: unknown): HealthTimelineResponse {
  const root = asRec(raw), w = asRec(root.window), s = asRec(root.summary)
  const buckets = Array.isArray(root.buckets) ? root.buckets.map((b) => {
    const r = asRec(b)
    return {
      bucket_start: typeof r.bucket_start === "string" ? r.bucket_start : "",
      total_checks: numOrZero(r.total_checks), ok_count: numOrZero(r.ok_count), error_count: numOrZero(r.error_count),
      uptime_pct: numOrNull(r.uptime_pct), avg_latency_ms: numOrNull(r.avg_latency_ms), p95_latency_ms: numOrNull(r.p95_latency_ms),
    }
  }) : []
  const recent_events = Array.isArray(root.recent_events) ? root.recent_events.map((e) => {
    const r = asRec(e)
    return {
      id: numOrZero(r.id), model_id: String(r.model_id ?? ""), slug: String(r.slug ?? ""),
      display_name: String(r.display_name ?? r.slug ?? ""), provider: String(r.provider ?? ""),
      capability: String(r.capability ?? ""), source: String(r.source ?? ""), ok: Boolean(r.ok),
      http_status: numOrNull(r.http_status), latency_ms: numOrNull(r.latency_ms),
      error: typeof r.error === "string" ? r.error : null, checked_at: String(r.checked_at ?? ""),
    }
  }) : []
  return {
    window: {
      hours: numOrNull(w.hours) ?? 24, bucket_minutes: numOrNull(w.bucket_minutes) ?? 60,
      since: typeof w.since === "string" ? w.since : "", until: typeof w.until === "string" ? w.until : "",
    },
    summary: {
      total_checks: numOrZero(s.total_checks), ok_count: numOrZero(s.ok_count), error_count: numOrZero(s.error_count),
      uptime_pct: numOrNull(s.uptime_pct), avg_latency_ms: numOrNull(s.avg_latency_ms),
      p50_latency_ms: numOrNull(s.p50_latency_ms), p95_latency_ms: numOrNull(s.p95_latency_ms),
      p99_latency_ms: numOrNull(s.p99_latency_ms), models_with_errors: numOrZero(s.models_with_errors),
    },
    buckets, recent_events,
  }
}

async function throwApiError(res: Response): Promise<never> {
  const data = await res.json().catch(() => null)
  const code = data && typeof data === "object" && "error" in data ? (data as { error?: { code?: string } }).error?.code : undefined
  throw new AdminApiError(res.status, extractApiError(data, res.status), code)
}

export async function fetchHealthTimeline(filters: HealthTimelineFilters = {}, signal?: AbortSignal): Promise<HealthTimelineResponse> {
  const qs = buildHealthTimelineParams(filters).toString()
  const res = await fetch("/api/admin/models/health-timeline" + (qs ? `?${qs}` : ""), {
    method: "GET", credentials: "include", cache: "no-store", signal, headers: { "X-InterviewCheck": "1" },
  })
  if (!res.ok) await throwApiError(res)
  return normalizeTimeline(await res.json().catch(() => null))
}

export async function downloadHealthTimelineExport(filters: HealthTimelineFilters = {}, format: "csv" | "json"): Promise<string> {
  const params = buildHealthTimelineParams(filters)
  params.set("format", format)
  const res = await fetch(`/api/admin/models/health-timeline/export?${params.toString()}`, {
    method: "GET", credentials: "include", cache: "no-store", headers: { "X-InterviewCheck": "1" },
  })
  if (!res.ok) await throwApiError(res)
  const fallback = format === "csv" ? "model-health-timeline.csv" : "model-health-timeline.json"
  const match = res.headers.get("Content-Disposition") ? /filename="?([^";]+)"?/i.exec(res.headers.get("Content-Disposition") || "") : null
  const filename = match?.[1]?.split(/[\\/]/).pop()?.trim().replace(/[^a-zA-Z0-9._-]/g, "") || fallback
  const objectUrl = URL.createObjectURL(await res.blob())
  try {
    const anchor = document.createElement("a")
    anchor.href = objectUrl; anchor.download = filename; anchor.style.display = "none"
    document.body.appendChild(anchor); anchor.click(); anchor.remove()
  } finally {
    window.setTimeout(() => URL.revokeObjectURL(objectUrl), 1000)
  }
  return filename
}
