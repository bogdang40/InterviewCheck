import type { Session } from "@/lib/api"
import { downloadResponse } from "@/lib/download"
import { ApiError, request, send } from "@/lib/http"
import type { InterviewPage, SessionCard } from "@/lib/interview-list"
import type { TrashedInterview } from "@/lib/trash"

export type FeedItem = SessionCard & { tags?: string[] }
export type FeedPage = Omit<InterviewPage, "items"> & { items: FeedItem[] }
export type BulkArchiveResult = { archived: number; newly_archived: number; items: TrashedInterview[] }
export type BulkRestoreItem = { session_id: string; operation_version: string }
export type BulkRestoreResult = { restored: number; session_ids: string[]; items: Session[] }
export type BulkTagResult = { updated: number; tags_by_session: Record<string, string[]> }
export type BulkExportFormat = "csv" | "json"
export type WorkspaceTag = { tag: string; count: number }

export class BulkApiError extends ApiError {}

export function parseTagList(raw: string): string[] {
  const seen = new Set<string>()
  const tags: string[] = []
  for (const part of raw.split(",")) {
    const tag = part.trim()
    if (!tag) continue
    if (tag.length > 32 || /[\x00-\x1f\x7f]/.test(tag)) {
      throw new Error("Each tag must be 1 to 32 characters without control characters.")
    }
    if (!seen.has(tag)) { seen.add(tag); tags.push(tag) }
  }
  if (tags.length > 10) throw new Error("Specify at most 10 tags at a time.")
  return tags
}

function bulkFetch(path: string, body: unknown): Promise<Response> {
  return send("/api/" + path, { method: "POST", json: body, errorType: BulkApiError })
}

const bulkJson = <T,>(path: string, body: unknown): Promise<T> =>
  request<T>("/api/" + path, { method: "POST", json: body, errorType: BulkApiError })

export const bulkArchive = (sessionIds: string[], confirmCount: number) =>
  bulkJson<BulkArchiveResult>("interviews/bulk/archive", { session_ids: sessionIds, confirm_count: confirmCount })

export const bulkRestore = (items: BulkRestoreItem[]) =>
  bulkJson<BulkRestoreResult>("interviews/bulk/restore", { items })

export const bulkTag = (sessionIds: string[], add: string[], remove: string[]) =>
  bulkJson<BulkTagResult>("interviews/bulk/tag", { session_ids: sessionIds, add, remove })

export async function bulkExport(sessionIds: string[], format: BulkExportFormat): Promise<string> {
  const response = await bulkFetch("interviews/bulk/export", { session_ids: sessionIds, format })
  return downloadResponse(response, `interviews-bulk.${format}`)
}

export async function fetchWorkspaceTags(signal?: AbortSignal): Promise<WorkspaceTag[] | null> {
  try {
    const data = await request<{ tags?: unknown } | null>("/api/interviews/tags", { signal })
    if (!data || !Array.isArray(data.tags)) return null
    return data.tags
      .filter((t): t is WorkspaceTag => Boolean(t && typeof (t as WorkspaceTag).tag === "string" && typeof (t as WorkspaceTag).count === "number"))
      .map((t) => ({ tag: t.tag.trim(), count: t.count }))
      .filter((t) => t.tag.length > 0)
  } catch (err) {
    if (err instanceof DOMException && err.name === "AbortError") throw err
    return null
  }
}

export function mergeWorkspaceTags(workspaceTags: WorkspaceTag[] | null, items: FeedItem[], activeTag = ""): WorkspaceTag[] {
  const counts = new Map<string, number>()
  if (workspaceTags !== null) {
    for (const entry of workspaceTags) counts.set(entry.tag, entry.count)
  } else {
    for (const item of items) {
      for (const tag of item.tags ?? []) counts.set(tag, (counts.get(tag) ?? 0) + 1)
    }
  }
  if (activeTag && !counts.has(activeTag)) counts.set(activeTag, 0)
  return Array.from(counts.entries())
    .map(([tag, count]) => ({ tag, count }))
    .sort((a, b) => (workspaceTags !== null ? b.count - a.count : 0) || a.tag.localeCompare(b.tag))
}

export function toggleSelection(ids: string[], id: string, checked: boolean, max = 100): string[] {
  if (!checked) return ids.filter((item) => item !== id)
  return ids.includes(id) || ids.length >= max ? ids : [...ids, id]
}

export function pruneSelection(ids: string[], visibleIds: string[]): string[] {
  const visible = new Set(visibleIds)
  const next = ids.filter((id) => visible.has(id))
  return next.length === ids.length ? ids : next
}

export function collectTags(items: FeedItem[], activeTag = ""): string[] {
  return mergeWorkspaceTags(null, items, activeTag).map((entry) => entry.tag)
}
