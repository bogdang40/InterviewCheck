import { AdminApiError, extractApiError, type AuditEntry } from "@/lib/adminModels"

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

function readErrorCode(data: unknown): string | undefined {
  if (data && typeof data === "object" && "error" in data) {
    const err = (data as { error?: { code?: unknown } }).error
    if (typeof err?.code === "string") return err.code
  }
  return undefined
}

export async function listAdminAuditEntries(
  filters: AdminAuditFilters = {},
  signal?: AbortSignal,
): Promise<AdminAuditPage> {
  const qs = buildAuditParams(filters, true).toString()
  const response = await fetch("/api/integrations/admin/audit" + (qs ? "?" + qs : ""), {
    method: "GET",
    credentials: "include",
    cache: "no-store",
    signal,
    headers: { "X-InterviewCheck": "1" },
  })
  const data = (await response.json().catch(() => null)) as {
    entries?: AuditEntry[]
    nextBeforeId?: unknown
  } | null
  if (!response.ok) {
    const msg =
      response.status === 429 && extractApiError(data, response.status).startsWith("Request failed")
        ? "Audit log rate limit exceeded. Wait a moment and try again."
        : extractApiError(data, response.status)
    throw new AdminApiError(response.status, msg, readErrorCode(data))
  }
  return {
    entries: Array.isArray(data?.entries) ? data.entries : [],
    nextBeforeId:
      typeof data?.nextBeforeId === "number" && Number.isInteger(data.nextBeforeId)
        ? data.nextBeforeId
        : null,
  }
}

function resolveDownloadName(header: string | null, format: "csv" | "json"): string {
  const fallback = format === "csv" ? "audit-log.csv" : "audit-log.json"
  if (!header) return fallback
  const match = /filename="?([^";]+)"?/i.exec(header)
  const sanitized = match?.[1]?.trim().replace(/[^a-zA-Z0-9._-]/g, "")
  return sanitized || fallback
}

export async function exportAdminAudit(
  format: "csv" | "json",
  filters: AdminAuditFilters = {},
): Promise<string> {
  const params = buildAuditParams(filters, false)
  params.set("format", format)
  const response = await fetch("/api/integrations/admin/audit/export?" + params.toString(), {
    method: "GET",
    credentials: "include",
    cache: "no-store",
    headers: { "X-InterviewCheck": "1" },
  })
  if (!response.ok) {
    const data = await response.json().catch(() => null)
    const extracted = extractApiError(data, response.status)
    const msg =
      response.status === 429 && extracted.startsWith("Request failed")
        ? "Audit export rate limit exceeded. Wait a moment and try again."
        : extracted
    throw new AdminApiError(response.status, msg, readErrorCode(data))
  }
  const filename = resolveDownloadName(response.headers.get("Content-Disposition"), format)
  const blob = await response.blob()
  const objectUrl = URL.createObjectURL(blob)
  try {
    const anchor = document.createElement("a")
    anchor.href = objectUrl
    anchor.download = filename
    anchor.style.display = "none"
    document.body.appendChild(anchor)
    anchor.click()
    anchor.remove()
  } finally {
    window.setTimeout(() => URL.revokeObjectURL(objectUrl), 1000)
  }
  return filename
}
