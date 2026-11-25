import { adminRequest } from "./adminModels"

export type UsageDay = {
  day: string
  visitors: number
  home: number
  sample: number
  signin_page: number
  signins: number
  new_accounts: number
  interviews: number
  answers: number
  reviews: number
  ai_requests: number
  ai_errors: number
  ai_tokens: number
  ai_cost_usd: number
}

export type UsageTotals = Omit<UsageDay, "day">

export type UsagePerson = {
  email: string
  role: string
  disabled: boolean
  operator: boolean
  created_at: string | null
  last_login_at: string | null
  signins: number
  active_sessions: number
}

export type UsageEvent = { at: string | null; email: string | null; action: "auth.login" | "auth.signup" | string }

export type UsageModel = {
  name: string
  provider: string
  capability: string
  model_id: string
  enabled: boolean
  has_key: boolean
  requests: number
  errors: number
  tokens: number
  cost_usd: number
}

export type UsageResponse = {
  days: number
  first_day: string
  last_day: string
  timezone: string
  tracking_since: string | null
  totals: UsageTotals
  daily: UsageDay[]
  accounts_available: boolean
  accounts_total: number | null
  people: UsagePerson[]
  recent: UsageEvent[]
  models: UsageModel[]
  ai_setup: {
    connected: number
    enabled: number
    with_key: number
    env_fallbacks: { provider: string; capability: string }[]
  }
}

export const USAGE_PERIODS = [7, 30, 90, 365] as const

export function getAdminUsage(days: number): Promise<UsageResponse> {
  return adminRequest<UsageResponse>(`/api/admin/usage?days=${days}`)
}

/** "Tue, Nov 24" for a UTC calendar day. */
export function formatUsageDay(day: string): string {
  const date = new Date(`${day}T12:00:00Z`)
  return date.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric", timeZone: "UTC" })
}

export function formatWhen(iso: string | null): string {
  if (!iso) return "Never"
  const date = new Date(iso)
  return Number.isNaN(date.getTime()) ? "Unknown" : date.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })
}

/** True when the day has anything worth a row in the daily table. */
export function hasActivity(day: UsageDay): boolean {
  return Object.entries(day).some(([key, value]) => key !== "day" && typeof value === "number" && value > 0)
}
