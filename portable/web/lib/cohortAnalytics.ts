import { extractApiError } from "@/lib/adminModels"
import { sanitizeDownloadFilename } from "@/lib/bulkArchive"

export type CohortLifecycle = "" | "active" | "finished" | "archived"
export type CohortExportFormat = "csv" | "json"
export type CohortFilters = { roleId?: string; tag?: string; lifecycle?: CohortLifecycle; since?: string; until?: string }
export type CohortRoleOption = { id: string; name: string }

export type CohortSummary = {
  session_count: number; active_count: number; finished_count: number; archived_count: number
  answer_count: number; reviewed_count: number; pass_rate_pct: number; concern_rate_pct: number
  avg_scorecard_pct: number | null; scored_session_count: number
}

export type CohortScoreBucket = { range: string; label: string; count: number }
export type CohortTimelinePoint = { date: string; sessions: number; finished: number; explained: number; concerns: number }
export type CohortTagBreakdown = { tag: string; session_count: number; pass_rate_pct: number; avg_scorecard_pct: number | null }

export type CohortCandidateRow = {
  session_id: string; candidate: string; role: string; role_id: string | null
  lifecycle: string; created_at: string; ended_at: string | null; tags: string[]
  answer_count: number; match_count: number; explained_count: number; concern_count: number
  pending_count: number; weighted_score_pct: number | null
}

export type CohortAnalyticsResponse = {
  summary: CohortSummary; score_buckets: CohortScoreBucket[]
  timeline: CohortTimelinePoint[]; tag_breakdown: CohortTagBreakdown[]; candidates: CohortCandidateRow[]
}

function toIsoBoundary(dateText: string, endOfDay: boolean): string {
  const trimmed = dateText.trim()
  if (!trimmed) return ""
  return /^\d{4}-\d{2}-\d{2}$/.test(trimmed) ? `${trimmed}T${endOfDay ? "23:59:59" : "00:00:00"}Z` : trimmed
}

export function buildCohortQuery(filters: CohortFilters, format?: CohortExportFormat): string {
  const params = new URLSearchParams()
  const roleId = filters.roleId?.trim() || ""
  const tag = filters.tag?.trim().slice(0, 32) || ""
  const since = filters.since ? toIsoBoundary(filters.since, false) : ""
  const until = filters.until ? toIsoBoundary(filters.until, true) : ""
  if (roleId) params.set("role_id", roleId)
  if (tag) params.set("tag", tag)
  if (filters.lifecycle) params.set("lifecycle", filters.lifecycle)
  if (since) params.set("since", since)
  if (until) params.set("until", until)
  if (format) params.set("format", format)
  const qs = params.toString()
  return qs ? `?${qs}` : ""
}

async function fetchCohortApi(path: string, signal?: AbortSignal): Promise<Response> {
  const response = await fetch(`/api/${path}`, {
    method: "GET",
    credentials: "include",
    cache: "no-store",
    signal,
    headers: { "X-InterviewCheck": "1" },
  })
  if (!response.ok) {
    const data = await response.json().catch(() => null)
    throw new Error(extractApiError(data, response.status))
  }
  return response
}

export async function fetchCohortRoles(signal?: AbortSignal): Promise<CohortRoleOption[]> {
  const data = await (await fetchCohortApi("roles", signal)).json().catch(() => null)
  if (!Array.isArray(data)) return []
  return data
    .filter((item): item is CohortRoleOption => Boolean(item && typeof item.id === "string" && typeof item.name === "string"))
    .map((item) => ({ id: item.id, name: item.name }))
}

export async function fetchCohortAnalytics(
  filters: CohortFilters,
  signal?: AbortSignal,
): Promise<CohortAnalyticsResponse> {
  return (await (await fetchCohortApi(`analytics/cohorts${buildCohortQuery(filters)}`, signal)).json()) as CohortAnalyticsResponse
}

export async function downloadCohortExport(filters: CohortFilters, format: CohortExportFormat): Promise<string> {
  const response = await fetchCohortApi(`analytics/cohorts/export${buildCohortQuery(filters, format)}`)
  const disposition = response.headers.get("Content-Disposition")
  const filename = disposition ? sanitizeDownloadFilename(disposition, format) : `cohort-analytics.${format}`
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
