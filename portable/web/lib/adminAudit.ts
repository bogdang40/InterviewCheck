import { AdminApiError, adminRequest, type AuditEntry } from "@/lib/adminModels"
import { downloadResponse } from "@/lib/download"
import { errorMessage, send } from "@/lib/http"

export type AuditCategory = "all" | "models" | "accounts"

export type AdminAuditFilters = {
  q?: string
  category?: AuditCategory
  action?: string
  actor?: string
  since?: string
  until?: string
  before_id?: number
  limit?: number
}

export type AdminAuditPage = {
  entries: AuditEntry[]
  nextBeforeId: number | null
}

function normalizeBoundary(raw: string | undefined, endOfDay: boolean): string | undefined {
  const trimmed = raw?.trim()
  if (!trimmed) return undefined
  if (/^\d{4}-\d{2}-\d{2}$/.test(trimmed)) {
    return `${trimmed}${endOfDay ? "T23:59:59.999Z" : "T00:00:00.000Z"}`
  }
  return trimmed
}

export function buildAuditParams(
  filters: AdminAuditFilters = {},
  includeCursor = true,
): URLSearchParams {
  const params = new URLSearchParams()
  const q = filters.q?.trim()
  if (q) params.set("q", q)
  if (filters.category) params.set("category", filters.category)
  const action = filters.action?.trim()
  if (action) params.set("action", action)
  const actor = filters.actor?.trim()
  if (actor) params.set("actor", actor)
  const since = normalizeBoundary(filters.since, false)
  if (since) params.set("since", since)
  const until = normalizeBoundary(filters.until, true)
  if (until) params.set("until", until)
  if (
    includeCursor &&
    typeof filters.before_id === "number" &&
    Number.isInteger(filters.before_id) &&
    filters.before_id >= 1
  ) {
    params.set("before_id", String(filters.before_id))
  }
  if (typeof filters.limit === "number" && Number.isFinite(filters.limit) && filters.limit >= 1) {
    params.set("limit", String(Math.trunc(filters.limit)))
  }
  return params
}

/** A 429 without its own explanation gets a hint about the audit rate limit. */
function rateLimitAware(hint: string) {
  return (data: unknown, status: number) => {
    const extracted = errorMessage(data, status)
    return status === 429 && extracted.startsWith("Request failed") ? hint : extracted
  }
}

export async function listAdminAuditEntries(
  filters: AdminAuditFilters = {},
  signal?: AbortSignal,
): Promise<AdminAuditPage> {
  const qs = buildAuditParams(filters, true).toString()
  const data = await adminRequest<{ entries?: AuditEntry[]; nextBeforeId?: unknown } | null>(
    "/api/integrations/admin/audit" + (qs ? "?" + qs : ""),
    { signal, describe: rateLimitAware("Audit log rate limit exceeded. Wait a moment and try again.") },
  )
  return {
    entries: Array.isArray(data?.entries) ? data.entries : [],
    nextBeforeId:
      typeof data?.nextBeforeId === "number" && Number.isInteger(data.nextBeforeId)
        ? data.nextBeforeId
        : null,
  }
}

export async function exportAdminAudit(
  format: "csv" | "json",
  filters: AdminAuditFilters = {},
): Promise<string> {
  const params = buildAuditParams(filters, false)
  params.set("format", format)
  const response = await send("/api/integrations/admin/audit/export?" + params.toString(), {
    errorType: AdminApiError,
    describe: rateLimitAware("Audit export rate limit exceeded. Wait a moment and try again."),
  })
  return downloadResponse(response, `audit-log.${format}`)
}
