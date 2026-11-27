import { downloadResponse } from "./download"
import { send } from "./http"
import {
  AdminApiError,
  adminRequest,
  type ConnectedModel,
  type ModelCapability,
  type ModelParameters,
} from "./adminModels"
import { type FleetTelemetryResponse } from "./adminTelemetry"

export type ModelBudgetParameters = {
  daily_token_limit?: number | null
  monthly_cost_limit_usd?: number | null
  input_cost_per_1m_usd?: number | null
  output_cost_per_1m_usd?: number | null
}

export type ExtendedModelParameters = ModelParameters & ModelBudgetParameters

export type SimulatedChainCandidate = {
  rank: number | null
  source: "registry" | "env" | string
  id: string | null
  slug: string | null
  display_name: string | null
  provider: string
  model_id: string | null
  status: string | null
  is_default: boolean
  fallback_priority: number | null
  rpm_remaining: number | null
  budget_status: "ok" | "daily_token_limit_exceeded" | "monthly_cost_limit_exceeded" | string
  eligible: boolean
  skip_reason: string | null
}

export type SimulateChainPayload = {
  capability: ModelCapability
  provider?: string
  allow_reference_fallback?: boolean
}

export type SimulateChainResponse = {
  capability: ModelCapability
  provider_filter: string | null
  active_chain: SimulatedChainCandidate[]
  skipped: SimulatedChainCandidate[]
  would_fail_503: boolean
  would_fail_429: boolean
  failure_reason: "no_candidate" | "circuit_open" | "workspace_allowance" | "model_budget" | "model_rpm" | null
}

export type ModelUsageSummary = {
  model_id: string
  daily_tokens: number
  daily_input_tokens: number
  daily_output_tokens: number
  daily_requests: number
  daily_errors: number
  daily_cost_usd: number
  monthly_cost_usd: number
  daily_token_limit: number | null
  monthly_cost_limit_usd: number | null
  budget_status: string
}

export type FleetUsageSummary = {
  daily_tokens: number
  monthly_cost_usd: number
  daily_requests: number
  daily_errors: number
}

export type TranscriptionReadiness = {
  ready: boolean
  active_provider: string | null
  active_model: string | null
  candidate_count: number
}

export type DiagnosticsData = {
  usageSummary: FleetUsageSummary
  usageByModel: Record<string, ModelUsageSummary>
  telemetry: FleetTelemetryResponse
  transcription: TranscriptionReadiness
  generated_at: string
}

type UnknownRecord = Record<string, unknown>

const asRecord = (val: unknown): UnknownRecord =>
  val && typeof val === "object" && !Array.isArray(val) ? (val as UnknownRecord) : {}

const numOrNull = (val: unknown): number | null =>
  typeof val === "number" && Number.isFinite(val) ? val : null

const numOrZero = (val: unknown): number =>
  typeof val === "number" && Number.isFinite(val) ? val : 0

export function readBudgetParameters(params: ModelParameters | null | undefined): ModelBudgetParameters {
  const ext = (params ?? {}) as ExtendedModelParameters
  return {
    daily_token_limit: numOrNull(ext.daily_token_limit),
    monthly_cost_limit_usd: numOrNull(ext.monthly_cost_limit_usd),
    input_cost_per_1m_usd: numOrNull(ext.input_cost_per_1m_usd),
    output_cost_per_1m_usd: numOrNull(ext.output_cost_per_1m_usd),
  }
}

export function formatCompactTokens(tokens: number): string {
  if (tokens >= 1_000_000) return `${(tokens / 1_000_000).toFixed(1)}M`
  if (tokens >= 1_000) return `${(tokens / 1_000).toFixed(1)}k`
  return String(Math.round(tokens))
}

export function formatUsd(usd: number): string {
  if (!Number.isFinite(usd)) return "$0.00"
  return usd > 0 && usd < 0.01 ? `$${usd.toFixed(4)}` : `$${usd.toFixed(2)}`
}

const budgetCurrency = new Intl.NumberFormat("en-US", {
  style: "currency", currency: "USD", maximumFractionDigits: 8,
})

export const formatBudgetUsd = (value: number) => budgetCurrency.format(value)

export function formatModelBudgetBadge(
  model: ConnectedModel,
  usage?: ModelUsageSummary,
): { label: string; overLimit: boolean } | null {
  const budget = readBudgetParameters(model.parameters)
  const { daily_token_limit: dailyLimit = null, monthly_cost_limit_usd: monthlyLimit = null } = usage ?? budget
  const dailyTokens = usage?.daily_tokens ?? 0
  const monthlyCost = usage?.monthly_cost_usd ?? 0
  const hasRates = budget.input_cost_per_1m_usd != null || budget.output_cost_per_1m_usd != null
  if (dailyLimit === null && monthlyLimit === null && !hasRates && dailyTokens === 0 && monthlyCost === 0) return null
  const overLimit =
    (dailyLimit !== null && dailyTokens >= dailyLimit) ||
    (monthlyLimit !== null && monthlyCost >= monthlyLimit) ||
    (usage?.budget_status != null && usage.budget_status !== "ok")
  const parts: string[] = []
  if (dailyLimit !== null) parts.push(`${formatCompactTokens(dailyTokens)}/${formatCompactTokens(dailyLimit)} tok`)
  else if (dailyTokens > 0) parts.push(`${formatCompactTokens(dailyTokens)} tok`)
  if (monthlyLimit !== null) parts.push(`${formatBudgetUsd(monthlyCost)}/${formatBudgetUsd(monthlyLimit)}`)
  else if (monthlyCost > 0) parts.push(formatUsd(monthlyCost))
  if (!parts.length && hasRates) {
    parts.push(`Rates ${formatUsd(budget.input_cost_per_1m_usd ?? 0)}/${formatUsd(budget.output_cost_per_1m_usd ?? 0)} per 1M`)
  }
  return { label: `Budget: ${parts.join(" · ")}`, overLimit }
}

export function computeFleetP95Latency(telemetry: FleetTelemetryResponse | null | undefined): number | null {
  if (!telemetry) return null
  const direct = numOrNull((telemetry.summary as UnknownRecord)?.p95_latency_ms)
  if (direct !== null) return direct
  const p95s = Object.values(telemetry.models ?? {})
    .map((m) => m.p95_latency_ms)
    .filter((v): v is number => typeof v === "number" && Number.isFinite(v))
  return p95s.length ? Math.max(...p95s) : null
}

function normalizeModelUsage(id: string, raw: UnknownRecord): ModelUsageSummary {
  const inputTok = numOrZero(raw.daily_input_tokens ?? raw.input_tokens)
  const outputTok = numOrZero(raw.daily_output_tokens ?? raw.output_tokens)
  return {
    model_id: typeof raw.model_id === "string" ? raw.model_id : id,
    daily_tokens: numOrNull(raw.daily_tokens ?? raw.today_tokens) ?? inputTok + outputTok,
    daily_input_tokens: inputTok,
    daily_output_tokens: outputTok,
    daily_requests: numOrZero(raw.daily_requests ?? raw.request_count),
    daily_errors: numOrZero(raw.daily_errors ?? raw.error_count),
    daily_cost_usd: numOrZero(raw.daily_cost_usd ?? raw.estimated_cost_usd),
    monthly_cost_usd: numOrZero(raw.monthly_cost_usd ?? raw.month_cost_usd ?? raw.estimated_cost_usd),
    daily_token_limit: numOrNull(raw.daily_token_limit),
    monthly_cost_limit_usd: numOrNull(raw.monthly_cost_limit_usd),
    budget_status: typeof raw.budget_status === "string" ? raw.budget_status : "ok",
  }
}

export function normalizeDiagnostics(raw: UnknownRecord): DiagnosticsData {
  const usageObj = asRecord(raw.usage)
  const rawModels = usageObj.models
  const usageByModel: Record<string, ModelUsageSummary> = {}
  if (Array.isArray(rawModels)) {
    for (const item of rawModels) {
      const rec = asRecord(item)
      const id = String(rec.model_id ?? rec.id ?? "")
      if (id) usageByModel[id] = normalizeModelUsage(id, rec)
    }
  } else {
    for (const [id, val] of Object.entries(asRecord(rawModels))) {
      usageByModel[id] = normalizeModelUsage(id, asRecord(val))
    }
  }
  const summarySrc = Object.keys(asRecord(usageObj.summary)).length ? asRecord(usageObj.summary) : usageObj
  const entries = Object.values(usageByModel)
  const transObj = asRecord(raw.transcription)
  return {
    usageSummary: {
      daily_tokens: numOrNull(summarySrc.daily_tokens ?? summarySrc.total_daily_tokens) ?? entries.reduce((s, m) => s + m.daily_tokens, 0),
      monthly_cost_usd: numOrNull(summarySrc.monthly_cost_usd ?? summarySrc.total_monthly_cost_usd) ?? entries.reduce((s, m) => s + m.monthly_cost_usd, 0),
      daily_requests: numOrNull(summarySrc.daily_requests ?? summarySrc.total_requests) ?? entries.reduce((s, m) => s + m.daily_requests, 0),
      daily_errors: numOrNull(summarySrc.daily_errors ?? summarySrc.total_errors) ?? entries.reduce((s, m) => s + m.daily_errors, 0),
    },
    usageByModel,
    telemetry: raw.telemetry as FleetTelemetryResponse,
    transcription: {
      ready: Boolean(transObj.ready),
      active_provider: typeof transObj.active_provider === "string" ? transObj.active_provider : null,
      active_model: typeof transObj.active_model === "string" ? transObj.active_model : null,
      candidate_count: numOrZero(transObj.candidate_count),
    },
    generated_at: typeof raw.generated_at === "string" ? raw.generated_at : new Date().toISOString(),
  }
}

export function simulateModelChain(payload: SimulateChainPayload): Promise<SimulateChainResponse> {
  return adminRequest<SimulateChainResponse>("/api/admin/models/simulate-chain", {
    method: "POST",
    body: JSON.stringify(payload),
  })
}

export async function getAdminDiagnostics(): Promise<DiagnosticsData> {
  return normalizeDiagnostics(await adminRequest<UnknownRecord>("/api/admin/models/diagnostics"))
}

export async function downloadDiagnosticBundle(): Promise<string> {
  const response = await send("/api/admin/diagnostics/bundle", { errorType: AdminApiError })
  return downloadResponse(response, "interviewcheck-diagnostics.json")
}
