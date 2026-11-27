import { ApiError, request } from "./http"

export const API_TOKEN_SCOPES = [
  "read:interviews",
  "write:interviews",
  "export:reports",
  "read:telemetry",
  "admin:models",
] as const

export type ApiTokenScope = (typeof API_TOKEN_SCOPES)[number]

export const SCOPE_LABELS: Record<ApiTokenScope, string> = {
  "read:interviews": "Read interviews",
  "write:interviews": "Write interviews",
  "export:reports": "Export reports",
  "read:telemetry": "Read telemetry",
  "admin:models": "Administer models (admin only)",
}

export type AccountSession = {
  id: string
  deviceName: string | null
  createdAt: string
  expiresAt: string
  lastSeenAt: string
  isCurrent: boolean
}

export type ApiTokenSummary = {
  id: string
  name: string
  tokenPrefix: string
  scopes: ApiTokenScope[]
  createdAt: string
  expiresAt: string | null
  lastUsedAt: string | null
  revokedAt?: string | null
}

export type CreatedApiToken = {
  token: string
  apiToken: ApiTokenSummary
}

export type CreateApiTokenInput = {
  name: string
  scopes: ApiTokenScope[]
  ttlDays?: number | null
}

export class AccountSecurityError extends ApiError {}

function readErrorMessage(data: unknown, status: number): string {
  if (data && typeof data === "object") {
    const obj = data as { detail?: unknown; error?: { message?: unknown } }
    if (typeof obj.detail === "string" && obj.detail.trim()) return obj.detail
    if (Array.isArray(obj.detail) && obj.detail.length > 0) {
      const first = obj.detail[0] as { msg?: unknown }
      if (typeof first?.msg === "string" && first.msg.trim()) return first.msg
    }
    if (obj.error && typeof obj.error.message === "string" && obj.error.message.trim()) {
      return obj.error.message
    }
  }
  return `Security request failed (HTTP ${status}).`
}

function securityRequest<T>(path: string, options: RequestInit = {}): Promise<T> {
  return request<T>(`/api/integrations/security/${path}`, {
    ...options,
    errorType: AccountSecurityError,
    describe: readErrorMessage,
  })
}

export async function listAccountSessions(signal?: AbortSignal): Promise<AccountSession[]> {
  const data = await securityRequest<{ sessions?: AccountSession[] }>("sessions", { signal })
  const rows = data?.sessions
  if (!Array.isArray(rows) || !rows.every(row => row && typeof row.id === "string" && typeof row.isCurrent === "boolean")
      || rows.filter(row => row.isCurrent).length !== 1) {
    throw new Error("The server did not confirm the current device session.")
  }
  return rows
}

export async function revokeAccountSession(id: string): Promise<{ revoked: boolean; id: string }> {
  const result = await securityRequest<{ revoked: boolean; id: string } | null>(
    `sessions/${encodeURIComponent(id)}`, { method: "DELETE" },
  )
  if (result?.revoked !== true || result.id !== id) throw new Error("The server did not confirm session revocation.")
  return result
}

export async function listApiTokens(signal?: AbortSignal): Promise<ApiTokenSummary[]> {
  const data = await securityRequest<{ tokens?: ApiTokenSummary[] }>("tokens", { signal })
  return Array.isArray(data?.tokens) ? data.tokens : []
}

export function createApiToken(payload: CreateApiTokenInput): Promise<CreatedApiToken> {
  return securityRequest<CreatedApiToken>("tokens", {
    method: "POST",
    body: JSON.stringify(payload),
  })
}

export function revokeApiToken(id: string): Promise<{ revoked: boolean; id: string }> {
  return securityRequest<{ revoked: boolean; id: string }>(
    `tokens/${encodeURIComponent(id)}`,
    { method: "DELETE" },
  )
}
