import { adminRequest } from "./adminModels"

export const MAX_ATTEMPTS = 1_000_000
const path = "/api/admin/usage/ai-allowance"

export type AttemptAllowance = {
  monthly_limit: number | null
  revision: number
  month: string
  used: number
  remaining: number | null
  tracking_started_at: string
  next_reset_at: string
}

function count(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
}

function validStamp(value: unknown): value is string {
  return typeof value === "string" && value.endsWith("Z") && Number.isFinite(Date.parse(value))
}

function parseReport(raw: unknown): AttemptAllowance {
  if (raw && typeof raw === "object") {
    const r = raw as Record<string, unknown>
    const limit = r.monthly_limit
    if ((limit === null || (count(limit) && limit <= MAX_ATTEMPTS)) && count(r.revision) && r.revision >= 1
      && count(r.used) && r.remaining === (limit === null ? null : Math.max(0, limit - r.used))
      && typeof r.month === "string" && /^\d{4}-(0[1-9]|1[0-2])$/.test(r.month)
      && validStamp(r.tracking_started_at) && validStamp(r.next_reset_at)) {
      return raw as AttemptAllowance
    }
  }
  throw new Error("The server returned an incomplete allowance report.")
}

export async function getAllowance(): Promise<AttemptAllowance> {
  return parseReport(await adminRequest<unknown>(path))
}

export async function saveAllowance(monthlyLimit: number | null, revision: number): Promise<AttemptAllowance> {
  const report = parseReport(await adminRequest<unknown>(path, {
    method: "PUT", json: { monthly_limit: monthlyLimit, expected_revision: revision },
  }))
  if (report.monthly_limit !== monthlyLimit || report.revision !== revision + 1) {
    throw new Error("The server did not confirm the requested allowance change.")
  }
  return report
}
