import { downloadResponse } from "@/lib/download"
import { request, send } from "@/lib/http"

export type CompareCounts = {
  match: number; no_match: number; insufficient: number
  pending: number; explained: number; unresolved: number; disclosed: number
}

export type CompareSessionSummary = {
  id: string; candidate: string; role: string; role_id: string | null
  lifecycle: string; created_at: string; ended_at: string | null
  consent: boolean; policy: string; answer_count: number; counts: CompareCounts
}

export type CompareSlotCell = {
  session_id?: string; answer_id: string; question: string
  status: "match" | "no_match" | "insufficient" | string
  disposition: "pending" | "explained" | "unresolved" | "disclosed" | string
  passage_count: number; excerpt?: string | null; note?: string | null
}

export type CompareSlotRow = {
  slot: number | "unslotted" | string; label?: string; planned_question?: string | null
  cells?: Record<string, CompareSlotCell | null>
  sessions?: Record<string, CompareSlotCell | null>
  answers?: Record<string, CompareSlotCell | null>
  entries?: CompareSlotCell[]
}

export type CompareRubricCriterion = {
  id?: string; criterion: string; weight?: number
  expected_signals?: string[]; red_flags?: string[]
}

export type CompareResponse = {
  sessions: CompareSessionSummary[]; slots: CompareSlotRow[]
  rubric_criteria?: CompareRubricCriterion[]
}

export type CompareInput = { session_ids: string[]; include_excerpts: boolean; include_notes: boolean }

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function parseCompareIds(raw: string | null | undefined): {
  ids: string[]; ignoredCount: number; truncatedCount: number
} {
  if (!raw) return { ids: [], ignoredCount: 0, truncatedCount: 0 }
  const seen = new Set<string>()
  const valid: string[] = []
  let ignoredCount = 0
  for (const part of raw.split(",")) {
    const id = part.trim()
    if (!id) continue
    if (!UUID_RE.test(id)) { ignoredCount += 1; continue }
    const lower = id.toLowerCase()
    if (!seen.has(lower)) { seen.add(lower); valid.push(id) }
  }
  return { ids: valid.slice(0, 6), ignoredCount, truncatedCount: Math.max(0, valid.length - 6) }
}

export function buildComparePageUrl(ids: string[]): string {
  const clean = ids.filter((id) => UUID_RE.test(id)).slice(0, 6)
  return clean.length ? "/interviews/compare/?ids=" + clean.map(encodeURIComponent).join(",") : "/interviews/compare/"
}

export function buildComparePrintUrl(
  ids: string[],
  options?: { includeExcerpts?: boolean; includeNotes?: boolean },
): string {
  const clean = ids.filter((id) => UUID_RE.test(id)).slice(0, 6)
  const parts = ["ids=" + clean.map(encodeURIComponent).join(",")]
  if (options?.includeExcerpts) parts.push("include_excerpts=true")
  if (options?.includeNotes) parts.push("include_notes=true")
  return "/api/interviews/compare/print?" + parts.join("&")
}

export function compareInterviews(input: CompareInput, signal?: AbortSignal): Promise<CompareResponse> {
  return request<CompareResponse>("/api/interviews/compare", { method: "POST", json: input, signal })
}

export async function downloadCompareDossier(input: CompareInput): Promise<string> {
  const response = await send("/api/interviews/compare/dossier", { method: "POST", json: { ...input, format: "markdown" } })
  return downloadResponse(response, "candidate-comparison.md")
}

export function getSlotCell(row: CompareSlotRow, sessionId: string): CompareSlotCell | null {
  const direct = row.cells?.[sessionId] ?? row.sessions?.[sessionId] ?? row.answers?.[sessionId]
  if (direct !== undefined) return direct
  return row.entries?.find((entry) => entry.session_id === sessionId) ?? null
}

export function formatSlotHeading(row: CompareSlotRow, index: number): string {
  if (row.label && row.label.trim()) return row.label
  if (row.slot === "unslotted") return "Unslotted"
  if (typeof row.slot === "number") return `Question ${row.slot}`
  return row.slot ? String(row.slot) : `Slot ${index + 1}`
}
