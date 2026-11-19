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

export class AccountSecurityError extends Error {
  status: number

  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

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

async function securityRequest<T>(path: string, options: RequestInit = {}): Promise<T> {
  const headers = new Headers(options.headers)
  headers.set("X-InterviewCheck", "1")
  if (options.body !== undefined && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json")
  }
  const response = await fetch(`/api/integrations/security/${path}`, {
    ...options,
    headers,
    cache: "no-store",
  })
  const data = await response.json().catch(() => null)
  if (!response.ok) {
    throw new AccountSecurityError(response.status, readErrorMessage(data, response.status))
  }
  return data as T
}

export async function listAccountSessions(): Promise<AccountSession[]> {
  const data = await securityRequest<{ sessions?: AccountSession[] }>("sessions")
  return Array.isArray(data?.sessions) ? data.sessions : []
}

export function revokeAccountSession(id: string): Promise<{ revoked: boolean; id: string }> {
  return securityRequest<{ revoked: boolean; id: string }>(
    `sessions/${encodeURIComponent(id)}`,
    { method: "DELETE" },
  )
}

export async function listApiTokens(): Promise<ApiTokenSummary[]> {
  const data = await securityRequest<{ tokens?: ApiTokenSummary[] }>("tokens")
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
