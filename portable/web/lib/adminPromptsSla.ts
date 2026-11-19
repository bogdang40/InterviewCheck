import { AdminApiError, extractApiError } from "./adminModels"

export type CircuitState = "closed" | "open" | "half_open"
export type ModelCircuitInfo = {
  state: CircuitState; failure_streak: number; consecutive_threshold: number; cooldown_seconds: number
  sla_target_ms: number; opened_at: string | null; next_retry_at: string | null
  last_failure_reason: string | null; updated_at: string | null
}
export type ModelSlaRow = {
  model_id: string; slug: string; display_name: string; provider: string; capability: string
  total_checks: number; ok_count: number; error_count: number; error_rate_pct: number | null
  p50_latency_ms: number | null; p95_latency_ms: number | null; p99_latency_ms: number | null
  sla_target_ms: number; sla_compliant: boolean | null; circuit: ModelCircuitInfo
}
export type SlaFleetSummary = {
  total_models: number; closed_circuits?: number; open_circuits: number; half_open_circuits: number
  sla_compliant_models?: number; sla_violating_models?: number; sla_breaches?: number
  total_checks?: number; error_count?: number
  p50_latency_ms: number | null; p95_latency_ms: number | null; p99_latency_ms: number | null
  error_rate_pct: number | null
}
export type ModelsSlaResponse = { available: boolean; summary: SlaFleetSummary | null; models: ModelSlaRow[] }
export type CircuitPolicyPayload = { consecutive_threshold: number; cooldown_seconds: number; sla_target_ms: number }

export const PROMPT_SLOTS = [
  "question_planning", "reference_spoken", "reference_talking_points", "reference_worked_example", "judge_rubric",
] as const
export type PromptSlot = (typeof PROMPT_SLOTS)[number]
export const PROMPT_SLOT_LABELS: Record<PromptSlot, string> = {
  question_planning: "Question planning",
  reference_spoken: "Reference: spoken answer",
  reference_talking_points: "Reference: talking points",
  reference_worked_example: "Reference: worked example",
  judge_rubric: "AI judge rubric",
}
export type PromptTemplate = {
  id: string; slot: PromptSlot; active_version: number; system_prompt: string
  output_rule: string; updated_by: string; updated_at: string; version_count: number
}
export type PromptVersion = {
  id: string; template_id: string; version_number: number; system_prompt: string; output_rule: string
  change_note: string; created_by: string; created_at: string; is_active: boolean
  diff: string; diff_from_previous: string; diff_vs_active: string
}
export type PromptUpdatePayload = {
  system_prompt: string; output_rule: string; change_note: string; expected_version: number
}
export type PromptRollbackPayload = { target_version: number; expected_version: number; change_note?: string }

async function requestJson<T>(url: string, options: RequestInit = {}): Promise<{ notMounted: boolean; data: T | null }> {
  const headers = new Headers(options.headers)
  headers.set("X-InterviewCheck", "1")
  if (options.body !== undefined && !headers.has("Content-Type")) headers.set("Content-Type", "application/json")
  const res = await fetch(url, { ...options, headers, cache: "no-store" })
  const data = await res.json().catch(() => null)
  if (res.status === 404 || res.status === 501) return { notMounted: true, data: null }
  if (!res.ok) {
    const code = data && typeof data === "object" && "error" in data ? (data as { error?: { code?: string } }).error?.code : undefined
    throw new AdminApiError(res.status, extractApiError(data, res.status), code)
  }
  return { notMounted: false, data: data as T }
}

const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null)
const str = (v: unknown): string | null => (typeof v === "string" ? v : null)

function normCircuit(raw: unknown): ModelCircuitInfo {
  const c = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>
  return {
    state: c.state === "open" || c.state === "half_open" ? c.state : "closed",
    failure_streak: num(c.failure_streak) ?? 0,
    consecutive_threshold: num(c.consecutive_threshold) ?? 3,
    cooldown_seconds: num(c.cooldown_seconds) ?? 60,
    sla_target_ms: num(c.sla_target_ms) ?? 2500,
    opened_at: str(c.opened_at), next_retry_at: str(c.next_retry_at),
    last_failure_reason: str(c.last_failure_reason), updated_at: str(c.updated_at),
  }
}

function normSlaRow(raw: Record<string, unknown>, fallbackId?: string): ModelSlaRow {
  const circuit = normCircuit(raw.circuit ?? raw)
  const target = num(raw.sla_target_ms) ?? circuit.sla_target_ms
  return {
    model_id: String(raw.model_id ?? raw.id ?? fallbackId ?? ""),
    slug: String(raw.slug ?? ""),
    display_name: String(raw.display_name ?? raw.slug ?? raw.model_id ?? "Model"),
    provider: String(raw.provider ?? ""), capability: String(raw.capability ?? ""),
    total_checks: num(raw.total_checks) ?? 0, ok_count: num(raw.ok_count) ?? 0, error_count: num(raw.error_count) ?? 0,
    error_rate_pct: num(raw.error_rate_pct),
    p50_latency_ms: num(raw.p50_latency_ms ?? raw.p50),
    p95_latency_ms: num(raw.p95_latency_ms ?? raw.p95),
    p99_latency_ms: num(raw.p99_latency_ms ?? raw.p99),
    sla_target_ms: target, sla_compliant: typeof raw.sla_compliant === "boolean" ? raw.sla_compliant : null,
    circuit: { ...circuit, sla_target_ms: target },
  }
}

export async function getModelsSla(): Promise<ModelsSlaResponse> {
  const res = await requestJson<Record<string, unknown>>("/api/admin/models/sla")
  if (res.notMounted || !res.data) return { available: false, summary: null, models: [] }
  const rawModels = res.data.models
  const models: ModelSlaRow[] = Array.isArray(rawModels)
    ? rawModels.map((item) => normSlaRow((item ?? {}) as Record<string, unknown>))
    : rawModels && typeof rawModels === "object"
      ? Object.entries(rawModels as Record<string, unknown>).map(([id, item]) => normSlaRow((item ?? {}) as Record<string, unknown>, id))
      : []
  const summary = res.data.summary && typeof res.data.summary === "object" ? (res.data.summary as SlaFleetSummary) : null
  return { available: true, summary, models }
}

export async function resetModelCircuit(modelId: string): Promise<{ circuit?: ModelCircuitInfo }> {
  const res = await requestJson<Record<string, unknown>>(`/api/admin/models/${encodeURIComponent(modelId)}/circuit/reset`, { method: "POST" })
  if (res.notMounted) throw new AdminApiError(404, "Circuit reset endpoint is not available on this server yet.")
  return { circuit: res.data?.circuit ? normCircuit(res.data.circuit) : undefined }
}

export async function updateCircuitPolicy(modelId: string, payload: CircuitPolicyPayload): Promise<{ circuit?: ModelCircuitInfo }> {
  const res = await requestJson<Record<string, unknown>>(`/api/admin/models/${encodeURIComponent(modelId)}/circuit`, {
    method: "PATCH", body: JSON.stringify(payload),
  })
  if (res.notMounted) throw new AdminApiError(404, "Circuit policy endpoint is not available on this server yet.")
  return { circuit: res.data?.circuit ? normCircuit(res.data.circuit) : undefined }
}

export async function listPromptTemplates(): Promise<{ available: boolean; prompts: PromptTemplate[] }> {
  const res = await requestJson<{ prompts?: PromptTemplate[] }>("/api/admin/prompts")
  if (res.notMounted || !res.data) return { available: false, prompts: [] }
  return { available: true, prompts: Array.isArray(res.data.prompts) ? res.data.prompts : [] }
}

export async function listPromptVersions(slot: PromptSlot): Promise<{ available: boolean; template: PromptTemplate | null; versions: PromptVersion[] }> {
  const res = await requestJson<{ template?: PromptTemplate; versions?: PromptVersion[] }>(`/api/admin/prompts/${encodeURIComponent(slot)}/versions`)
  if (res.notMounted || !res.data) return { available: false, template: null, versions: [] }
  return { available: true, template: res.data.template ?? null, versions: Array.isArray(res.data.versions) ? res.data.versions : [] }
}

export async function updatePromptTemplate(slot: PromptSlot, payload: PromptUpdatePayload): Promise<PromptTemplate> {
  const res = await requestJson<{ prompt: PromptTemplate }>(`/api/admin/prompts/${encodeURIComponent(slot)}`, {
    method: "PUT", body: JSON.stringify(payload),
  })
  if (res.notMounted || !res.data?.prompt) throw new AdminApiError(404, "Prompt template endpoint is not available on this server yet.")
  return res.data.prompt
}

export async function rollbackPromptTemplate(slot: PromptSlot, payload: PromptRollbackPayload): Promise<PromptTemplate> {
  const res = await requestJson<{ prompt: PromptTemplate }>(`/api/admin/prompts/${encodeURIComponent(slot)}/rollback`, {
    method: "POST", body: JSON.stringify(payload),
  })
  if (res.notMounted || !res.data?.prompt) throw new AdminApiError(404, "Prompt rollback endpoint is not available on this server yet.")
  return res.data.prompt
}
