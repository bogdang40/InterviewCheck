import type { PermittedMaterial, Role } from "./api"

export type RubricCriterion = {
  id: string
  criterion: string
  weight: number
  expected_signals: string[]
  red_flags: string[]
}

export type CalibratedRole = Role & {
  rubric?: RubricCriterion[]
  version_number?: number
}

export type RoleSavePayload = {
  id: string
  version?: string
  name: string
  description: string
  questions: string[]
  policy: string
  permitted_sources: PermittedMaterial[]
  rubric: RubricCriterion[]
  change_note: string
}

export type ReviewerSummary = {
  reviewer_id: string
  reviewer_email: string
  total_reviews: number
  explained_count: number
  unresolved_count: number
  disclosed_count: number
  concern_count: number
  pass_rate_pct: number
  concern_rate_pct: number
  delta_vs_baseline_pp: number
}

export type RoleMetricsSummary = {
  session_count: number
  finished_count: number
  answer_count: number
  match_count: number
  no_match_count: number
  insufficient_count: number
  match_rate_pct: number
  explained_count: number
  unresolved_count: number
  disclosed_count: number
  concern_count: number
  pending_count: number
  reviewed_count: number
  pass_rate_pct: number
  concern_rate_pct: number
  multi_reviewer_disagreements: number
}

export type RoleAnalyticsItem = RoleMetricsSummary & {
  role_id: string
  role_name: string
  version_number: number
  reviewer_summary: ReviewerSummary[]
}

export type RolesAnalyticsResponse = {
  roles: RoleAnalyticsItem[]
  totals: RoleMetricsSummary & { role_count: number }
  reviewer_summary: ReviewerSummary[]
}

export type QuestionCalibrationItem = Omit<RoleMetricsSummary, "session_count" | "finished_count" | "reviewed_count" | "multi_reviewer_disagreements"> & {
  planned_slot: number | null
  question: string
  disagreement_count: number
}

export type CalibrationDisagreement = {
  answer_id: string
  session_id: string
  question: string
  planned_slot: number | null
  current_disposition: "pending" | "explained" | "unresolved" | "disclosed"
  reviewers: Array<{
    reviewer_id: string
    reviewer_email: string
    disposition: "pending" | "explained" | "unresolved" | "disclosed"
    created_at: string
  }>
}

export type RoleCalibrationResponse = {
  role_id: string
  role_name: string
  version_number: number
  summary: RoleMetricsSummary
  question_breakdown: QuestionCalibrationItem[]
  reviewer_summary: ReviewerSummary[]
  disagreements: CalibrationDisagreement[]
}

export type RoleVersionSnapshot = {
  id: string
  role_id: string
  version_number: number
  version: string
  content_sha256: string
  name: string
  description: string
  questions: string[]
  policy: string
  permitted_sources: PermittedMaterial[]
  rubric: RubricCriterion[]
  change_note: string
  created_by: string
  created_at: string
}

export type RoleVersionsResponse = {
  role_id: string
  current_version: string
  current_version_number: number
  versions: RoleVersionSnapshot[]
}

export type RoleVersionDiff = {
  against_version_number: number
  has_changes: boolean
  changed_fields: string[]
  changes: Record<string, { version: unknown; live: unknown }>
  questions: { added: string[]; removed: string[] }
  rubric: {
    added: RubricCriterion[]
    removed: RubricCriterion[]
    modified: Array<{ id: string; version: RubricCriterion; live: RubricCriterion }>
  }
  permitted_sources: { added: string[]; removed: string[] }
}

export type RoleVersionDetailResponse = {
  role_id: string
  current_version: string
  current_version_number: number
  version: RoleVersionSnapshot
  diff: RoleVersionDiff
}

export type RoleRestoreRequest = { expected_version: string; change_note?: string }
export type RoleRestoreResponse = CalibratedRole & { restored_from_version: number }

export class RoleApiError extends Error {
  status: number
  conflictHeader: string | null

  constructor(status: number, message: string, conflictHeader: string | null = null) {
    super(message)
    this.status = status
    this.conflictHeader = conflictHeader
  }
}

export function extractApiError(data: unknown, status: number): string {
  if (data && typeof data === "object") {
    const obj = data as { detail?: unknown; error?: { message?: unknown } }
    if (typeof obj.detail === "string" && obj.detail.trim()) return obj.detail
    if (Array.isArray(obj.detail) && obj.detail.length > 0) {
      const first = obj.detail[0] as { msg?: unknown; loc?: unknown }
      if (typeof first?.msg === "string") {
        const loc = Array.isArray(first.loc) ? first.loc.slice(1).join(".") : ""
        return loc ? `${loc}: ${first.msg}` : first.msg
      }
    }
    if (obj.error && typeof obj.error.message === "string" && obj.error.message.trim()) {
      return obj.error.message
    }
  }
  return `Request failed (HTTP ${status}).`
}

async function requestRoleApi<T>(url: string, options: RequestInit = {}): Promise<T> {
  const headers = new Headers(options.headers)
  headers.set("X-InterviewCheck", "1")
  if (options.body !== undefined && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json")
  }
  const response = await fetch(url, { ...options, credentials: "include", cache: "no-store", headers })
  const data = await response.json().catch(() => null)
  if (!response.ok) {
    throw new RoleApiError(
      response.status,
      extractApiError(data, response.status),
      response.headers.get("X-InterviewCheck-Conflict"),
    )
  }
  return data as T
}

export function fetchRolesAnalytics(signal?: AbortSignal): Promise<RolesAnalyticsResponse> {
  return requestRoleApi<RolesAnalyticsResponse>("/api/roles/analytics", { method: "GET", signal })
}

export function fetchRoleCalibration(roleId: string, signal?: AbortSignal): Promise<RoleCalibrationResponse> {
  return requestRoleApi<RoleCalibrationResponse>(`/api/roles/${encodeURIComponent(roleId)}/calibration`, { method: "GET", signal })
}

export function fetchRoleVersions(roleId: string, signal?: AbortSignal): Promise<RoleVersionsResponse> {
  return requestRoleApi<RoleVersionsResponse>(`/api/roles/${encodeURIComponent(roleId)}/versions`, { method: "GET", signal })
}

export function fetchRoleVersionDiff(roleId: string, versionNumber: number, signal?: AbortSignal): Promise<RoleVersionDetailResponse> {
  return requestRoleApi<RoleVersionDetailResponse>(`/api/roles/${encodeURIComponent(roleId)}/versions/${versionNumber}`, { method: "GET", signal })
}

export function restoreRoleVersion(roleId: string, versionNumber: number, payload: RoleRestoreRequest): Promise<RoleRestoreResponse> {
  return requestRoleApi<RoleRestoreResponse>(`/api/roles/${encodeURIComponent(roleId)}/versions/${versionNumber}/restore`, {
    method: "POST",
    body: JSON.stringify(payload),
  })
}
