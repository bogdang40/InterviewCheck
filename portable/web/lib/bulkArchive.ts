import { extractApiError } from "@/lib/adminModels"
import type { Session } from "@/lib/api"
import type { InterviewPage, SessionCard } from "@/lib/interview-list"
import type { TrashedInterview } from "@/lib/trash"

export { extractApiError }

export type FeedItem = SessionCard & { tags?: string[] }
export type FeedPage = Omit<InterviewPage, "items"> & { items: FeedItem[] }
export type BulkArchiveResult = { archived: number; newly_archived: number; items: TrashedInterview[] }
export type BulkRestoreItem = { session_id: string; operation_version: string }
export type BulkRestoreResult = { restored: number; session_ids: string[]; items: Session[] }
export type BulkTagResult = { updated: number; tags_by_session: Record<string, string[]> }
export type BulkExportFormat = "csv" | "json"
export type WorkspaceTag = { tag: string; count: number }

export class BulkApiError extends Error {
  constructor(public status: number, message: string) {
    super(message)
  }
}

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

export function sanitizeDownloadFilename(header: string | null, format: BulkExportFormat): string {
  const fallback = format === "json" ? "interviews-bulk.json" : "interviews-bulk.csv"
  if (!header) return fallback
  let candidate = ""
  const extMatch = /filename\*\s*=\s*(?:utf-8''|[^']*''|)([^;]+)/i.exec(header)
  if (extMatch?.[1]) {
    const raw = extMatch[1].trim().replace(/^["']|["']$/g, "")
    try { candidate = decodeURIComponent(raw) } catch { candidate = raw }
  } else {
    const plainMatch = /filename\s*=\s*"([^"]+)"|filename\s*=\s*([^;\s]+)/i.exec(header)
    candidate = (plainMatch?.[1] || plainMatch?.[2] || "").trim()
  }
  const base = (candidate.split(/[\\/]/).pop() || "").trim()
  const cleaned = base.replace(/[^a-zA-Z0-9._-]/g, "-").replace(/-+/g, "-").replace(/^[.-]+|[.-]+$/g, "")
  if (!cleaned || cleaned === "." || cleaned === "..") return fallback
  const expectedExt = `.${format}`
  const withExt = cleaned.toLowerCase().endsWith(expectedExt)
    ? cleaned
    : `${cleaned.replace(/\.[a-z0-9]+$/i, "")}${expectedExt}`
  return withExt.slice(0, 120) || fallback
}

async function bulkFetch(path: string, body: unknown): Promise<Response> {
  const response = await fetch("/api/" + path, {
    method: "POST", credentials: "include", cache: "no-store",
    headers: { "Content-Type": "application/json", "X-InterviewCheck": "1" },
    body: JSON.stringify(body),
  })
  if (!response.ok) {
    const data = await response.json().catch(() => null)
    throw new BulkApiError(response.status, extractApiError(data, response.status))
  }
  return response
}

const bulkJson = async <T,>(path: string, body: unknown): Promise<T> => (await (await bulkFetch(path, body)).json()) as T

export const bulkArchive = (sessionIds: string[], confirmCount: number) =>
  bulkJson<BulkArchiveResult>("interviews/bulk/archive", { session_ids: sessionIds, confirm_count: confirmCount })

export const bulkRestore = (items: BulkRestoreItem[]) =>
  bulkJson<BulkRestoreResult>("interviews/bulk/restore", { items })

export const bulkTag = (sessionIds: string[], add: string[], remove: string[]) =>
  bulkJson<BulkTagResult>("interviews/bulk/tag", { session_ids: sessionIds, add, remove })

export async function bulkExport(sessionIds: string[], format: BulkExportFormat): Promise<string> {
  const response = await bulkFetch("interviews/bulk/export", { session_ids: sessionIds, format })
  const filename = sanitizeDownloadFilename(response.headers.get("Content-Disposition"), format)
  const objectUrl = URL.createObjectURL(await response.blob())
  try {
    const anchor = document.createElement("a")
    anchor.href = objectUrl; anchor.download = filename; anchor.style.display = "none"
    document.body.appendChild(anchor); anchor.click(); anchor.remove()
  } finally {
    window.setTimeout(() => URL.revokeObjectURL(objectUrl), 1000)
  }
  return filename
}

export async function fetchWorkspaceTags(signal?: AbortSignal): Promise<WorkspaceTag[] | null> {
  try {
    const response = await fetch("/api/interviews/tags", {
      method: "GET", credentials: "include", cache: "no-store", signal, headers: { "X-InterviewCheck": "1" },
    })
    if (!response.ok) return null
    const data = (await response.json().catch(() => null)) as { tags?: unknown } | null
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
