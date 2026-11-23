import { ApiError, errorMessage, readJson, request, type HttpOptions } from "./http"

export type ModelProvider =
  | "openai"
  | "anthropic"
  | "azure_openai"
  | "deepgram"
  | "openai_compatible"

export type ModelCapability =
  | "reference"
  | "question_planning"
  | "transcription"
  | "embedding"
  | "judge"

export type ModelStatus = "connected" | "unverified" | "error" | "disabled"

export type ModelParameters = {
  temperature: number | null
  max_tokens: number | null
  timeout_s: number | null
  fallback_priority: number
  max_retries: number
  rpm_limit: number | null
}

export type ConnectedModel = {
  id: string
  slug: string
  display_name: string
  provider: ModelProvider
  capability: ModelCapability
  model_id: string
  endpoint: string | null
  api_version: string | null
  parameters: ModelParameters
  hasKey: boolean
  key_hint: string | null
  enabled: boolean
  is_default: boolean
  status: ModelStatus
  last_error: string | null
  last_latency_ms: number | null
  last_checked_at: string | null
  created_at: string
  updated_at: string
}

export type EnvFallback = {
  provider: ModelProvider
  capability: ModelCapability
  configured: boolean
  model_id: string | null
}

export type ModelListResponse = {
  models: ConnectedModel[]
  providers: ModelProvider[]
  envFallbacks: EnvFallback[]
}

export type ProbeResult = {
  ok: boolean
  model: ConnectedModel
  detail?: string
}

export type ModelCreatePayload = {
  slug?: string
  display_name: string
  provider: ModelProvider
  capability: ModelCapability
  model_id: string
  endpoint?: string | null
  api_version?: string | null
  apiKey?: string | null
  parameters?: Partial<ModelParameters>
  enabled?: boolean
  is_default?: boolean
}

export type ModelUpdatePayload = {
  slug?: string
  display_name?: string
  capability?: ModelCapability
  model_id?: string
  endpoint?: string | null
  api_version?: string | null
  apiKey?: string | null
  clearApiKey?: boolean
  parameters?: Partial<ModelParameters>
  enabled?: boolean
  is_default?: boolean
}

export type AdminMember = {
  user: {
    id: string
    email: string
    role: "user" | "admin"
    disabled: boolean
    createdAt?: string
    trialEndsAt?: string | null
    complimentaryUntil: string | null
  }
  entitlement: {
    active: boolean
    source: string
    expiresAt?: string | null
    graceUntil?: string | null
    plan?: string | null
    subscriptionStatus?: string | null
  }
  subscription?: Record<string, unknown> | null
  lastLoginAt?: string | null
}

export type AuditEntry = {
  id: number
  at: string
  actorUserId: string | null
  action: string
  targetUserId: string | null
  details: Record<string, unknown> | null
}

export const PROVIDER_LABELS: Record<ModelProvider, string> = {
  openai: "OpenAI",
  anthropic: "Anthropic",
  azure_openai: "Azure OpenAI",
  deepgram: "Deepgram",
  openai_compatible: "OpenAI-Compatible",
}

export const CAPABILITY_LABELS: Record<ModelCapability, string> = {
  reference: "Reference answers",
  question_planning: "Question planning",
  transcription: "Transcription",
  embedding: "Embeddings",
  judge: "AI Judge",
}

export const ALLOWED_CAPABILITIES: Record<ModelProvider, ModelCapability[]> = {
  openai: ["reference", "question_planning", "embedding", "judge"],
  anthropic: ["reference", "question_planning", "judge"],
  azure_openai: ["reference", "question_planning", "embedding", "judge"],
  openai_compatible: ["reference", "question_planning", "embedding", "judge"],
  deepgram: ["transcription"],
}

export const ENDPOINT_REQUIRED_PROVIDERS: readonly ModelProvider[] = [
  "azure_openai",
  "openai_compatible",
]

export const KEY_REQUIRED_PROVIDERS: readonly ModelProvider[] = [
  "openai",
  "anthropic",
  "azure_openai",
  "deepgram",
]

/** Thrown by admin requests; components check it for 401 and 403 to send the operator back to sign in. */
export class AdminApiError extends ApiError {}

export const extractApiError = errorMessage

export function adminRequest<T>(url: string, options: HttpOptions = {}): Promise<T> {
  return request<T>(url, { ...options, errorType: AdminApiError })
}

export function listAdminModels(filters?: {
  provider?: ModelProvider
  capability?: ModelCapability
}): Promise<ModelListResponse> {
  const params = new URLSearchParams()
  if (filters?.provider) params.set("provider", filters.provider)
  if (filters?.capability) params.set("capability", filters.capability)
  const qs = params.toString()
  return adminRequest<ModelListResponse>("/api/admin/models" + (qs ? "?" + qs : ""))
}

export async function createAdminModel(payload: ModelCreatePayload): Promise<ConnectedModel> {
  const res = await adminRequest<{ model: ConnectedModel }>("/api/admin/models", {
    method: "POST",
    body: JSON.stringify(payload),
  })
  return res.model
}

export async function updateAdminModel(
  id: string,
  payload: ModelUpdatePayload,
): Promise<ConnectedModel> {
  const res = await adminRequest<{ model: ConnectedModel }>(
    `/api/admin/models/${encodeURIComponent(id)}`,
    { method: "PATCH", body: JSON.stringify(payload) },
  )
  return res.model
}

export async function toggleAdminModel(id: string, enabled: boolean): Promise<ConnectedModel> {
  const res = await adminRequest<{ model: ConnectedModel }>(
    `/api/admin/models/${encodeURIComponent(id)}/toggle`,
    { method: "POST", body: JSON.stringify({ enabled }) },
  )
  return res.model
}

export async function probeAdminModel(id: string): Promise<ProbeResult> {
  const response = await fetch(`/api/admin/models/${encodeURIComponent(id)}/probe`, {
    method: "POST",
    headers: { "X-InterviewCheck": "1", "Content-Type": "application/json" },
    cache: "no-store",
  })
  const data = (await readJson(response)) as {
    ok?: boolean
    model?: ConnectedModel
    detail?: string
  } | null
  if (!response.ok) {
    if (data?.model && response.status !== 401 && response.status !== 403) {
      return {
        ok: false,
        model: data.model,
        detail: extractApiError(data, response.status),
      }
    }
    throw new AdminApiError(response.status, extractApiError(data, response.status))
  }
  return {
    ok: Boolean(data?.ok),
    model: data!.model!,
    detail: data?.detail,
  }
}

export function deleteAdminModel(id: string): Promise<{ deleted: boolean; id: string }> {
  return adminRequest<{ deleted: boolean; id: string }>(
    `/api/admin/models/${encodeURIComponent(id)}`,
    { method: "DELETE" },
  )
}

export function listAdminUsers(
  q?: string,
  cursor?: string,
): Promise<{ users: AdminMember[]; nextCursor: string | null }> {
  const params = new URLSearchParams()
  if (q) params.set("q", q)
  if (cursor) params.set("cursor", cursor)
  const qs = params.toString()
  return adminRequest<{ users: AdminMember[]; nextCursor: string | null }>(
    "/api/integrations/admin/users" + (qs ? "?" + qs : ""),
  )
}

export function updateAdminUser(
  uid: string,
  patch: { role?: "user" | "admin"; disabled?: boolean; complimentaryUntil?: string | null },
): Promise<AdminMember> {
  return adminRequest<AdminMember>(`/api/integrations/admin/users/${encodeURIComponent(uid)}`, {
    method: "PATCH",
    body: JSON.stringify(patch),
  })
}

export function listAdminAudit(): Promise<{ entries: AuditEntry[] }> {
  return adminRequest<{ entries: AuditEntry[] }>("/api/integrations/admin/audit")
}

export function rotateOwnPassword(
  currentPassword: string,
  newPassword: string,
): Promise<{ email: string; active: boolean; admin?: boolean }> {
  return adminRequest<{ email: string; active: boolean; admin?: boolean }>(
    "/api/integrations/access/password",
    { method: "POST", body: JSON.stringify({ currentPassword, newPassword }) },
  )
}

export function parseOptionalFloat(raw: string, label: string, min: number, max: number): number | null {
  const trimmed = raw.trim()
  if (!trimmed) return null
  const val = Number(trimmed)
  if (!Number.isFinite(val) || val < min || val > max) {
    throw new Error(`${label} must be a number between ${min} and ${max}.`)
  }
  return val
}

export function parseOptionalInt(raw: string, label: string, min: number, max: number): number | null {
  const trimmed = raw.trim()
  if (!trimmed) return null
  if (!/^-?\d+$/.test(trimmed)) {
    throw new Error(`${label} must be a whole integer between ${min} and ${max}.`)
  }
  const val = Number.parseInt(trimmed, 10)
  if (!Number.isSafeInteger(val) || val < min || val > max) {
    throw new Error(`${label} must be an integer between ${min} and ${max}.`)
  }
  return val
}

