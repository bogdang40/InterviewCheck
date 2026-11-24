import { ApiError, errorMessage, request } from "./http"
import { announceAssignmentChange } from "./assignmentChanges"

export type AssignmentPriority = "low" | "normal" | "high"

export type SessionAssignment = {
  session_id: string; assignee_email: string; assigned_by: string
  priority: AssignmentPriority; due_at: string | null; updated_at: string
}

export type SessionAssignmentResponse = { assignment: SessionAssignment | null; version: string | null; suggested_reviewers: string[] }
export type SessionAssignmentInput = { assignee_email: string; priority?: AssignmentPriority; due_at?: string | null }

export type AssignmentQueueItem = {
  session_id: string; candidate: string; role: string; lifecycle: string; review_count: number
  assignee_email: string | null; assigned_by: string | null; priority: AssignmentPriority | string
  due_at: string | null; updated_at: string | null
  assignment_version?: string
}

export type DueFilter = "" | "overdue" | "soon"

export type AssignmentQueueCounts = { assigned_to_me: number; high_priority: number; unassigned: number }
export type AssignmentDueCounts = { overdue: number; due_soon: number }
export type AssignmentQueueResponse = {
  page: number
  pages: number
  filtered: number
  limit: number
  viewer_email: string
  next_transition_ms: number | null
  counts: AssignmentQueueCounts
  due_counts: AssignmentDueCounts
  items: AssignmentQueueItem[]
}
export type AssignmentQueueFilters = {
  assignee?: string
  priority?: "" | AssignmentPriority
  due?: DueFilter
  limit?: number
  page?: number
}

export type BulkSessionAssignmentInput = {
  session_ids: string[]
  expected_versions: Record<string, string>
  action: "assign" | "clear"
  assignee_email?: string | null
  priority?: AssignmentPriority
  due_at?: string | null
}

export type BulkSessionAssignmentResult = {
  action: "assign" | "clear"
  updated: number
  assignments?: SessionAssignment[]
  cleared_ids?: string[]
}

function deadlineInstant(value: string): string {
  // The queue treats old dates without an offset as UTC. Keep the original
  // fractional seconds for writes; JavaScript Date would round to milliseconds.
  const naive = /^(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}:\d{2}(?::\d{2}(?:[.,]\d+)?)?))?$/.exec(value)
  return naive ? `${naive[1]}T${(naive[2] ?? "00:00:00").replace(",", ".")}Z` : value
}

export function toDueAtIso(dateValue: string, storedDeadline?: string | null): string | null {
  const trimmed = dateValue.trim()
  if (!trimmed) return null
  if (storedDeadline && toDateInputValue(storedDeadline) === trimmed) return deadlineInstant(storedDeadline)
  return /^\d{4}-\d{2}-\d{2}$/.test(trimmed) ? `${trimmed}T23:59:59Z` : trimmed
}

export function toDateInputValue(isoValue: string | null | undefined): string {
  if (!isoValue) return ""
  const instant = new Date(deadlineInstant(isoValue))
  return Number.isFinite(instant.getTime()) ? instant.toISOString().slice(0, 10) : ""
}

const utcDeadline = new Intl.DateTimeFormat(undefined, {
  timeZone: "UTC", year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit",
  hourCycle: "h23",
})

export function deadlineLabel(isoValue: string): string {
  const instant = new Date(deadlineInstant(isoValue))
  return Number.isFinite(instant.getTime()) ? `${utcDeadline.format(instant)} UTC` : "Unknown deadline"
}

export function isDueOverdue(dueAt: string | null | undefined, nowMs = Date.now()): boolean {
  if (!dueAt) return false
  const parsed = Date.parse(deadlineInstant(dueAt))
  return Number.isFinite(parsed) && parsed < nowMs
}

export function validAssignmentVersion(value: unknown): value is string {
  return typeof value === "string" && /^[a-f0-9]{64}$/.test(value)
}

export class AssignmentConflict extends ApiError {}

function assignmentError(response: Response, data: unknown) {
  if (response.status === 409 && response.headers.get("X-InterviewCheck-Conflict") === "assignment-version") {
    const detail = (data as { detail?: { message?: unknown } } | null)?.detail
    return new AssignmentConflict(409, typeof detail?.message === "string" ? detail.message : "The assignment changed.")
  }
  return new ApiError(response.status, errorMessage(data, response.status))
}

export async function fetchSessionAssignment(sessionId: string, signal?: AbortSignal): Promise<SessionAssignmentResponse> {
  const data = await request<Partial<SessionAssignmentResponse>>(
    `/api/sessions/${encodeURIComponent(sessionId)}/assignment?include_version=true`,
    { method: "GET", signal },
  )
  return {
    assignment: data?.assignment ?? null,
    version: validAssignmentVersion(data?.version) ? data.version : null,
    suggested_reviewers: Array.isArray(data?.suggested_reviewers) ? data.suggested_reviewers : [],
  }
}

export async function saveSessionAssignment(sessionId: string, payload: SessionAssignmentInput, version: string) {
  if (!validAssignmentVersion(version)) throw new Error("Refresh the assignment before saving changes.")
  const data = await request<{ assignment: SessionAssignment; version?: string }>(
    `/api/sessions/${encodeURIComponent(sessionId)}/assignment`,
    { method: "PUT", json: { ...payload, expected_version: version }, toError: assignmentError },
  )
  announceAssignmentChange()
  return { assignment: data.assignment, version: validAssignmentVersion(data.version) ? data.version : null }
}

export async function clearSessionAssignment(sessionId: string, version: string) {
  if (!validAssignmentVersion(version)) throw new Error("Refresh the assignment before clearing it.")
  const data = await request<{ version?: string }>(
    `/api/sessions/${encodeURIComponent(sessionId)}/assignment?expected_version=${encodeURIComponent(version)}`,
    { method: "DELETE", toError: assignmentError },
  )
  announceAssignmentChange()
  return { assignment: null, version: validAssignmentVersion(data.version) ? data.version : null }
}

export async function fetchAssignmentQueue(
  filters: AssignmentQueueFilters = {},
  signal?: AbortSignal,
): Promise<AssignmentQueueResponse> {
  const params = new URLSearchParams({ include_versions: "true", include_transition: "true" })
  if (filters.assignee) params.set("assignee", filters.assignee)
  if (filters.priority) params.set("priority", filters.priority)
  if (filters.due) params.set("due", filters.due)
  if (typeof filters.limit === "number" && Number.isFinite(filters.limit) && filters.limit >= 1) {
    params.set("limit", String(Math.trunc(filters.limit)))
  }
  if (typeof filters.page === "number" && Number.isFinite(filters.page) && filters.page >= 1) {
    params.set("page", String(Math.trunc(filters.page)))
  }
  const qs = params.toString()
  const data = await request<Partial<AssignmentQueueResponse>>(
    `/api/interviews/assignments${qs ? `?${qs}` : ""}`,
    { method: "GET", signal },
  )
  return {
    page: data?.page ?? 1,
    pages: data?.pages ?? 1,
    filtered: data?.filtered ?? data?.items?.length ?? 0,
    limit: data?.limit ?? filters.limit ?? 50,
    viewer_email: typeof data?.viewer_email === "string" ? data.viewer_email : "",
    next_transition_ms: typeof data?.next_transition_ms === "number" && Number.isSafeInteger(data.next_transition_ms) &&
      data.next_transition_ms > 0 ? data.next_transition_ms : null,
    counts: {
      assigned_to_me: data?.counts?.assigned_to_me ?? 0,
      high_priority: data?.counts?.high_priority ?? 0,
      unassigned: data?.counts?.unassigned ?? 0,
    },
    due_counts: {
      overdue: data?.due_counts?.overdue ?? 0,
      due_soon: data?.due_counts?.due_soon ?? 0,
    },
    items: Array.isArray(data?.items) ? data.items : [],
  }
}

export async function bulkAssignSessions(
  payload: BulkSessionAssignmentInput,
): Promise<BulkSessionAssignmentResult> {
  if (Object.keys(payload.expected_versions).length !== payload.session_ids.length ||
      payload.session_ids.some(id => !validAssignmentVersion(payload.expected_versions[id]))) {
    throw new Error("Refresh the queue and reselect the interviews before changing assignments.")
  }
  const data = await request<Partial<BulkSessionAssignmentResult>>(
    "/api/interviews/assignments/bulk",
    { method: "POST", json: payload, toError: assignmentError },
  )
  announceAssignmentChange()
  return {
    action: data?.action === "clear" ? "clear" : "assign",
    updated: typeof data?.updated === "number" ? data.updated : 0,
    assignments: Array.isArray(data?.assignments) ? data.assignments : undefined,
    cleared_ids: Array.isArray(data?.cleared_ids) ? data.cleared_ids : undefined,
  }
}
