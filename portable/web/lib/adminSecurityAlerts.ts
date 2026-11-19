import { adminRequest } from "./adminModels"

export const ALERT_TRIGGER_TYPES = [
  "model_error_streak", "model_uptime_below", "budget_pct_threshold", "probe_failed",
] as const

export type AlertTriggerType = (typeof ALERT_TRIGGER_TYPES)[number]

export const ALERT_TRIGGER_LABELS: Record<AlertTriggerType, string> = {
  model_error_streak: "Model error streak",
  model_uptime_below: "Model uptime below (%)",
  budget_pct_threshold: "Budget usage above (%)",
  probe_failed: "Model probe failed",
}

export type RateLimitEntry = {
  id: string; source: string; limiter: string; keyHash: string; key: string
  hits: number; max: number | null; remaining: number; resetAt: string
}

export type AdminUserSession = {
  id: string; deviceName: string | null; createdAt: string; expiresAt: string; lastSeenAt: string
}

export type AlertRule = {
  id: string; name: string; trigger_type: AlertTriggerType; threshold_value: number
  capability_filter: string | null; webhook_url: string; has_secret: boolean
  secret_hint: string | null; enabled: boolean; cooldown_minutes: number
  last_triggered_at: string | null; created_at: string; updated_at: string
}

export type AlertDelivery = {
  id: number; rule_id: string; event_key: string; ok: boolean
  http_status: number | null; error: string | null; delivered_at: string
}

export type AlertRulePayload = {
  name: string; trigger_type: AlertTriggerType; threshold_value: number
  capability_filter?: string | null; webhook_url: string; signing_secret?: string | null
  clear_signing_secret?: boolean; cooldown_minutes?: number; enabled?: boolean
}

export type AlertEvaluateResponse = { evaluated?: number; triggered?: number; deliveries?: AlertDelivery[] }
export type AlertTestResponse = { ok: boolean; delivery?: AlertDelivery; http_status?: number | null; error?: string | null; detail?: string }

function normRateLimit(raw: Record<string, unknown>, idx: number): RateLimitEntry {
  const keyHash = typeof raw.keyHash === "string" ? raw.keyHash : ""
  const key = typeof raw.maskedKey === "string" ? raw.maskedKey : typeof raw.key === "string" ? raw.key : "unknown"
  const hits = typeof raw.hits === "number" ? raw.hits : typeof raw.count === "number" ? raw.count : 0
  return {
    id: `${String(raw.limiter ?? "rl")}:${keyHash || key}:${idx}`,
    source: typeof raw.source === "string" ? raw.source : "limiter",
    limiter: typeof raw.limiter === "string" ? raw.limiter : "credential",
    keyHash, key, hits,
    max: typeof raw.max === "number" ? raw.max : null,
    remaining: typeof raw.remaining === "number" ? raw.remaining : 0,
    resetAt: typeof raw.resetAt === "string" ? raw.resetAt : "",
  }
}

function normRule(raw: Record<string, unknown>): AlertRule {
  return {
    ...(raw as unknown as AlertRule),
    enabled: Boolean(raw.enabled),
    has_secret: Boolean(raw.has_secret ?? raw.secret_hint),
    secret_hint: typeof raw.secret_hint === "string" ? raw.secret_hint : null,
    capability_filter: typeof raw.capability_filter === "string" ? raw.capability_filter : null,
  }
}

function normDelivery(raw: Record<string, unknown>): AlertDelivery {
  return { ...(raw as unknown as AlertDelivery), ok: Boolean(raw.ok) }
}

export async function listAdminRateLimits(): Promise<RateLimitEntry[]> {
  const data = await adminRequest<{ entries?: Record<string, unknown>[] }>("/api/integrations/admin/security/rate-limits")
  return Array.isArray(data?.entries) ? data.entries.map(normRateLimit) : []
}

export function clearAdminRateLimits(filter?: { key?: string; keyHash?: string }): Promise<{ cleared: number }> {
  const params = new URLSearchParams()
  if (filter?.keyHash) params.set("keyHash", filter.keyHash)
  else if (filter?.key) params.set("key", filter.key)
  const qs = params.toString()
  return adminRequest<{ cleared: number }>(`/api/integrations/admin/security/rate-limits${qs ? `?${qs}` : ""}`, { method: "DELETE" })
}

export async function listAdminUserSessions(uid: string): Promise<AdminUserSession[]> {
  const data = await adminRequest<{ sessions?: AdminUserSession[] }>(`/api/integrations/admin/security/users/${encodeURIComponent(uid)}/sessions`)
  return Array.isArray(data?.sessions) ? data.sessions : []
}

export function revokeAdminUserSessions(uid: string, sessionId?: string): Promise<{ userId: string; revokedCount: number }> {
  return adminRequest<{ userId: string; revokedCount: number }>(
    `/api/integrations/admin/security/users/${encodeURIComponent(uid)}/revoke-sessions`,
    { method: "POST", body: JSON.stringify(sessionId ? { sessionId } : {}) },
  )
}

export async function listAlertRules(): Promise<{ rules: AlertRule[]; deliveries: AlertDelivery[] }> {
  const data = await adminRequest<{ rules?: Record<string, unknown>[]; deliveries?: Record<string, unknown>[] }>("/api/admin/alerts")
  return {
    rules: Array.isArray(data?.rules) ? data.rules.map(normRule) : [],
    deliveries: Array.isArray(data?.deliveries) ? data.deliveries.map(normDelivery) : [],
  }
}

export async function createAlertRule(payload: AlertRulePayload): Promise<AlertRule> {
  const data = await adminRequest<Record<string, unknown>>("/api/admin/alerts", { method: "POST", body: JSON.stringify(payload) })
  return normRule(data.rule && typeof data.rule === "object" ? (data.rule as Record<string, unknown>) : data)
}

export async function updateAlertRule(id: string, payload: Partial<AlertRulePayload>): Promise<AlertRule> {
  const data = await adminRequest<Record<string, unknown>>(`/api/admin/alerts/${encodeURIComponent(id)}`, { method: "PATCH", body: JSON.stringify(payload) })
  return normRule(data.rule && typeof data.rule === "object" ? (data.rule as Record<string, unknown>) : data)
}

export function deleteAlertRule(id: string): Promise<{ deleted: boolean; id: string }> {
  return adminRequest<{ deleted: boolean; id: string }>(`/api/admin/alerts/${encodeURIComponent(id)}`, { method: "DELETE" })
}

export async function evaluateAlertRules(): Promise<AlertEvaluateResponse> {
  const data = await adminRequest<AlertEvaluateResponse>("/api/admin/alerts/evaluate", { method: "POST" })
  return { ...data, deliveries: Array.isArray(data?.deliveries) ? data.deliveries.map((d) => normDelivery(d as unknown as Record<string, unknown>)) : undefined }
}

export async function testAlertRule(id: string): Promise<AlertTestResponse> {
  const data = await adminRequest<AlertTestResponse>(`/api/admin/alerts/${encodeURIComponent(id)}/test`, { method: "POST" })
  return { ...data, ok: Boolean(data?.ok), delivery: data?.delivery ? normDelivery(data.delivery as unknown as Record<string, unknown>) : undefined }
}
