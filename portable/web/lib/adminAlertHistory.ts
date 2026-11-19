import { AdminApiError, adminRequest, extractApiError } from "./adminModels"

export type AlertDeliveryStatusFilter = "" | "ok" | "failed"
export type AlertDeliverySummary = {
  total: number; ok_count: number; failed_count: number; success_rate_pct: number; failing_rules: number
}
export type AlertDeliveryItem = {
  id: number; rule_id: string; rule_name: string | null; trigger_type: string | null
  event_key: string; ok: boolean; http_status: number | null; error: string | null; delivered_at: string
}
export type AlertDeliveryFilters = {
  rule_id?: string; status?: AlertDeliveryStatusFilter; since?: string; until?: string; before_id?: number; limit?: number
}
export type AlertDeliveryPage = { summary: AlertDeliverySummary; items: AlertDeliveryItem[]; next_before_id: number | null }
export type AlertDeliveryRetryResponse = { ok: boolean; delivery: AlertDeliveryItem }

const EMPTY_SUMMARY: AlertDeliverySummary = { total: 0, ok_count: 0, failed_count: 0, success_rate_pct: 0, failing_rules: 0 }

function normDate(raw: string | undefined, endOfDay: boolean): string | undefined {
  const trimmed = raw?.trim()
  if (!trimmed) return undefined
  return /^\d{4}-\d{2}-\d{2}$/.test(trimmed) ? `${trimmed}${endOfDay ? "T23:59:59.999Z" : "T00:00:00.000Z"}` : trimmed
}

export function buildAlertDeliveryParams(filters: AlertDeliveryFilters = {}, includeCursor = true): URLSearchParams {
  const params = new URLSearchParams()
  const ruleId = filters.rule_id?.trim()
  if (ruleId) params.set("rule_id", ruleId)
  if (filters.status === "ok" || filters.status === "failed") params.set("status", filters.status)
  const since = normDate(filters.since, false), until = normDate(filters.until, true)
  if (since) params.set("since", since)
  if (until) params.set("until", until)
  if (includeCursor && typeof filters.before_id === "number" && Number.isInteger(filters.before_id) && filters.before_id >= 1) {
    params.set("before_id", String(filters.before_id))
  }
  if (typeof filters.limit === "number" && Number.isFinite(filters.limit) && filters.limit >= 1) {
    params.set("limit", String(Math.trunc(filters.limit)))
  }
  return params
}

function normDeliveryItem(raw: Record<string, unknown>): AlertDeliveryItem {
  return {
    id: typeof raw.id === "number" ? raw.id : Number(raw.id ?? 0),
    rule_id: typeof raw.rule_id === "string" ? raw.rule_id : String(raw.rule_id ?? ""),
    rule_name: typeof raw.rule_name === "string" ? raw.rule_name : null,
    trigger_type: typeof raw.trigger_type === "string" ? raw.trigger_type : null,
    event_key: typeof raw.event_key === "string" ? raw.event_key : "",
    ok: Boolean(raw.ok),
    http_status: typeof raw.http_status === "number" ? raw.http_status : null,
    error: typeof raw.error === "string" ? raw.error : null,
    delivered_at: typeof raw.delivered_at === "string" ? raw.delivered_at : "",
  }
}

export async function listAlertDeliveries(filters: AlertDeliveryFilters = {}, signal?: AbortSignal): Promise<AlertDeliveryPage> {
  const qs = buildAlertDeliveryParams(filters, true).toString()
  const res = await fetch("/api/admin/alerts/deliveries" + (qs ? `?${qs}` : ""), {
    method: "GET", credentials: "include", cache: "no-store", signal, headers: { "X-InterviewCheck": "1" },
  })
  const data = (await res.json().catch(() => null)) as {
    summary?: Partial<AlertDeliverySummary>; items?: Record<string, unknown>[]; next_before_id?: unknown; error?: { code?: string }
  } | null
  if (!res.ok) throw new AdminApiError(res.status, extractApiError(data, res.status), data?.error?.code)
  const s = data?.summary
  return {
    summary: s ? {
      total: Number(s.total ?? 0), ok_count: Number(s.ok_count ?? 0), failed_count: Number(s.failed_count ?? 0),
      success_rate_pct: Number(s.success_rate_pct ?? 0), failing_rules: Number(s.failing_rules ?? 0),
    } : EMPTY_SUMMARY,
    items: Array.isArray(data?.items) ? data.items.map(normDeliveryItem) : [],
    next_before_id: typeof data?.next_before_id === "number" && Number.isInteger(data.next_before_id) ? data.next_before_id : null,
  }
}

export async function retryAlertDelivery(deliveryId: number): Promise<AlertDeliveryRetryResponse> {
  const data = await adminRequest<{ ok?: boolean; delivery?: Record<string, unknown> }>(
    `/api/admin/alerts/deliveries/${encodeURIComponent(String(deliveryId))}/retry`,
    { method: "POST" },
  )
  return {
    ok: Boolean(data?.ok),
    delivery: normDeliveryItem(data?.delivery && typeof data.delivery === "object" ? data.delivery : {}),
  }
}

function resolveExportName(header: string | null, format: "csv" | "json"): string {
  const fallback = format === "csv" ? "alert-deliveries.csv" : "alert-deliveries.json"
  const match = header ? /filename="?([^";]+)"?/i.exec(header) : null
  return match?.[1]?.trim().replace(/[^a-zA-Z0-9._-]/g, "") || fallback
}

export async function exportAlertDeliveries(format: "csv" | "json", filters: AlertDeliveryFilters = {}): Promise<string> {
  const params = buildAlertDeliveryParams(filters, false)
  params.set("format", format)
  const res = await fetch(`/api/admin/alerts/deliveries/export?${params.toString()}`, {
    method: "GET", credentials: "include", cache: "no-store", headers: { "X-InterviewCheck": "1" },
  })
  if (!res.ok) {
    const data = await res.json().catch(() => null)
    const code = data && typeof data === "object" && "error" in data ? (data as { error?: { code?: string } }).error?.code : undefined
    throw new AdminApiError(res.status, extractApiError(data, res.status), code)
  }
  const filename = resolveExportName(res.headers.get("Content-Disposition"), format)
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
