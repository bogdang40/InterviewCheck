export type TotpStatus = {
  enabled: boolean
  verifiedAt: string | null
  remainingBackupCodes: number
  supported?: boolean
}
export type TotpSetup = { secret: string; otpauthUri: string; issuer: string }
export type TotpVerifyResult = { enabled: boolean; verifiedAt: string; backupCodes: string[] }
export type TotpBackupRegenerateResult = { backupCodes: string[] }
export type TotpDisableResult = { enabled: boolean }
export type LoginWithTotpResult<T> = { ok: true; account: T } | { ok: false; totpRequired: true; message: string }

export class TotpApiError extends Error {
  status: number
  code?: string
  constructor(status: number, message: string, code?: string) {
    super(message)
    this.status = status
    this.code = code
  }
}

export function isTotpUnsupported(err: unknown): boolean {
  return err instanceof TotpApiError && (err.status === 404 || err.status === 501)
}

function readErrorInfo(data: unknown, status: number): { message: string; code?: string } {
  if (data && typeof data === "object") {
    const obj = data as { detail?: unknown; code?: unknown; error?: { code?: unknown; message?: unknown } }
    const code = typeof obj.error?.code === "string" ? obj.error.code : typeof obj.code === "string" ? obj.code : undefined
    if (typeof obj.error?.message === "string" && obj.error.message.trim()) return { message: obj.error.message, code }
    if (typeof obj.detail === "string" && obj.detail.trim()) return { message: obj.detail, code }
    if (Array.isArray(obj.detail) && obj.detail.length > 0) {
      const first = obj.detail[0] as { msg?: unknown }
      if (typeof first?.msg === "string" && first.msg.trim()) return { message: first.msg, code }
    }
  }
  return { message: `Two-factor authentication request failed (HTTP ${status}).` }
}

async function totpRequest<T>(path: string, options: RequestInit = {}): Promise<T> {
  const headers = new Headers(options.headers)
  headers.set("X-InterviewCheck", "1")
  if (options.body !== undefined && !headers.has("Content-Type")) headers.set("Content-Type", "application/json")
  const response = await fetch(`/api/integrations/security/totp/${path}`, { ...options, headers, cache: "no-store" })
  const data = await response.json().catch(() => null)
  if (!response.ok) {
    const info = readErrorInfo(data, response.status)
    throw new TotpApiError(response.status, info.message, info.code)
  }
  return data as T
}

export async function getTotpStatus(signal?: AbortSignal): Promise<TotpStatus> {
  try {
    return { ...(await totpRequest<TotpStatus>("status", { signal })), supported: true }
  } catch (err) {
    if (isTotpUnsupported(err)) return { enabled: false, verifiedAt: null, remainingBackupCodes: 0, supported: false }
    throw err
  }
}

export function startTotpSetup(): Promise<TotpSetup> {
  return totpRequest<TotpSetup>("setup", { method: "POST", body: JSON.stringify({}) })
}

export function verifyTotpSetup(code: string): Promise<TotpVerifyResult> {
  return totpRequest<TotpVerifyResult>("verify", { method: "POST", body: JSON.stringify({ code }) })
}

export function disableTotp(currentPassword: string, code: string): Promise<TotpDisableResult> {
  return totpRequest<TotpDisableResult>("disable", { method: "POST", body: JSON.stringify({ currentPassword, code }) })
}

export function regenerateBackupCodes(code: string): Promise<TotpBackupRegenerateResult> {
  return totpRequest<TotpBackupRegenerateResult>("backup-codes/regenerate", { method: "POST", body: JSON.stringify({ code }) })
}

export async function submitAccessAuth<T>(action: "login" | "signup", payload: Record<string, unknown>): Promise<LoginWithTotpResult<T>> {
  const response = await fetch(`/api/integrations/access/${action}`, {
    method: "POST",
    headers: { "X-InterviewCheck": "1", "Content-Type": "application/json" },
    body: JSON.stringify(payload),
    cache: "no-store",
  })
  const data = await response.json().catch(() => null)
  if (!response.ok) {
    const info = readErrorInfo(data, response.status)
    const totpHeader = response.headers.get("X-InterviewCheck-TOTP")?.toLowerCase() === "required"
    if (response.status === 401 && action === "login" && (totpHeader || info.code === "totp_required")) {
      return { ok: false, totpRequired: true, message: info.message }
    }
    throw new TotpApiError(response.status, info.message, info.code)
  }
  return { ok: true, account: data as T }
}
