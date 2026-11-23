import { request } from "./http"

export type AssignmentPriority = "low" | "normal" | "high"

export type SessionAssignment = {
  session_id: string; assignee_email: string; assigned_by: string
  priority: AssignmentPriority; due_at: string | null; updated_at: string
}

export type SessionAssignmentResponse = { assignment: SessionAssignment | null; suggested_reviewers: string[] }
export type SessionAssignmentInput = { assignee_email: string; priority?: AssignmentPriority; due_at?: string | null }

export type AssignmentQueueItem = {
  session_id: string; candidate: string; role: string; lifecycle: string; review_count: number
  assignee_email: string | null; assigned_by: string | null; priority: AssignmentPriority | string
  due_at: string | null; updated_at: string | null
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

export function toDueAtIso(dateValue: string): string | null {
  const trimmed = dateValue.trim()
  if (!trimmed) return null
  return /^\d{4}-\d{2}-\d{2}$/.test(trimmed) ? `${trimmed}T23:59:59Z` : trimmed
}

export function toDateInputValue(isoValue: string | null | undefined): string {
  return isoValue ? isoValue.slice(0, 10) : ""
}

export function isDueOverdue(dueAt: string | null | undefined, nowMs = Date.now()): boolean {
  if (!dueAt) return false
  const parsed = Date.parse(dueAt)
  return Number.isFinite(parsed) && parsed < nowMs
}

export async function fetchSessionAssignment(sessionId: string, signal?: AbortSignal): Promise<SessionAssignmentResponse> {
  const data = await request<Partial<SessionAssignmentResponse>>(
    `/api/sessions/${encodeURIComponent(sessionId)}/assignment`,
    { method: "GET", signal },
  )
  return {
    assignment: data?.assignment ?? null,
    suggested_reviewers: Array.isArray(data?.suggested_reviewers) ? data.suggested_reviewers : [],
  }
}

export async function saveSessionAssignment(sessionId: string, payload: SessionAssignmentInput): Promise<SessionAssignment> {
  const data = await request<{ assignment: SessionAssignment }>(
    `/api/sessions/${encodeURIComponent(sessionId)}/assignment`,
    { method: "PUT", body: JSON.stringify(payload) },
  )
  return data.assignment
}

export function clearSessionAssignment(sessionId: string): Promise<{ cleared: boolean; session_id: string }> {
  return request<{ cleared: boolean; session_id: string }>(
    `/api/sessions/${encodeURIComponent(sessionId)}/assignment`,
    { method: "DELETE" },
  )
}

export async function fetchAssignmentQueue(
  filters: AssignmentQueueFilters = {},
  signal?: AbortSignal,
): Promise<AssignmentQueueResponse> {
  const params = new URLSearchParams()
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
  const data = await request<Partial<BulkSessionAssignmentResult>>(
    "/api/interviews/assignments/bulk",
    { method: "POST", body: JSON.stringify(payload) },
  )
  return {
    action: data?.action === "clear" ? "clear" : "assign",
    updated: typeof data?.updated === "number" ? data.updated : 0,
    assignments: Array.isArray(data?.assignments) ? data.assignments : undefined,
    cleared_ids: Array.isArray(data?.cleared_ids) ? data.cleared_ids : undefined,
  }
}
