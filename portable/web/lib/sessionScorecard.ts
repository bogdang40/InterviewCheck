"use client"

import { ApiError, request, type HttpOptions } from "./http"

export type HandoffNoteCategory = "observation" | "follow_up" | "decision" | "concern"
export type ScorecardItem = {
  criterion_id: string
  criterion_label: string
  weight: number
  rating: number | null
  rationale: string
  updated_by?: string | null
  updated_at?: string | null
}
export type ScorecardSaveItem = {
  criterion_id: string
  criterion_label: string
  weight: number
  rating: number
  rationale: string
}
export type HandoffNote = {
  id: string
  session_id?: string
  author_email: string
  category: HandoffNoteCategory
  body: string
  created_at: string
}
function readableNote(value: unknown, sessionId: string): value is HandoffNote {
  if (!value || typeof value !== "object") return false
  const note = value as Partial<HandoffNote>
  return typeof note.id === "string" && !!note.id && (note.session_id === undefined || note.session_id === sessionId) &&
    ["observation", "follow_up", "decision", "concern"].includes(note.category ?? "") &&
    typeof note.body === "string" && typeof note.author_email === "string" &&
    typeof note.created_at === "string"
}
export type ScorecardState = {
  available: boolean
  version: string | null
  items: ScorecardItem[]
  weighted_score_pct: number | null
  handoff_notes: HandoffNote[]
  handoff_notes_paged: boolean
}

export class ScorecardApiError extends ApiError {}
export class ScorecardVersionConflict extends ScorecardApiError {}

function extractError(data: unknown, status: number): string {
  if (data && typeof data === "object") {
    const obj = data as { detail?: unknown; error?: { message?: unknown } }
    if (typeof obj.detail === "string" && obj.detail.trim()) return obj.detail
    if (Array.isArray(obj.detail) && obj.detail.length > 0) {
      const first = obj.detail[0] as { msg?: unknown }
      if (typeof first?.msg === "string") return first.msg
    }
    if (obj.error && typeof obj.error.message === "string" && obj.error.message.trim()) return obj.error.message
  }
  return `Request failed (HTTP ${status}).`
}

export function requestJson<T>(url: string, options: HttpOptions = {}): Promise<T> {
  return request<T>(url, { ...options, errorType: ScorecardApiError, describe: extractError })
}

export function computeWeightedScorePct(items: ReadonlyArray<{ weight: number; rating: number | null }>): number | null {
  let weightedSum = 0
  let totalWeight = 0
  for (const item of items) {
    if (item.rating !== null && item.rating >= 1 && item.rating <= 5 && item.weight > 0) {
      weightedSum += item.rating * item.weight
      totalWeight += item.weight
    }
  }
  if (!totalWeight) return null
  // Match the server's integer calculation, including exact half-tenths.
  const numerator = weightedSum * 200
  const tenths = Math.floor(numerator / totalWeight)
  const remainder = numerator % totalWeight
  const roundUp = 2 * remainder > totalWeight || (2 * remainder === totalWeight && tenths % 2 === 1)
  return (tenths + Number(roundUp)) / 10
}

export async function fetchSessionScorecard(sessionId: string, signal?: AbortSignal): Promise<ScorecardState> {
  try {
    const data = await requestJson<Omit<ScorecardState, "available">>(`/api/sessions/${sessionId}/scorecard?include_handoff_notes=false`, { signal })
    if (!Array.isArray(data?.items)) throw new Error("The server returned an unreadable scorecard.")
    const notes = data.handoff_notes_paged === true ? [] : data.handoff_notes ?? []
    if (!Array.isArray(notes) || !notes.every(note => readableNote(note, sessionId))) throw new Error("The server returned unreadable handoff notes.")
    return {
      available: true,
      version: typeof data.version === "string" && /^[a-f0-9]{64}$/.test(data.version) ? data.version : null,
      items: data.items,
      weighted_score_pct: typeof data.weighted_score_pct === "number" ? data.weighted_score_pct : null,
      handoff_notes: notes,
      handoff_notes_paged: data.handoff_notes_paged === true,
    }
  } catch (error) {
    if (error instanceof ScorecardApiError && (error.status === 404 || error.status === 501)) {
      return { available: false, version: null, items: [], weighted_score_pct: null, handoff_notes: [], handoff_notes_paged: false }
    }
    throw error
  }
}

type SavedScorecard = { version: string; items: ScorecardItem[] }

export async function saveSessionScorecard(
  sessionId: string,
  items: ScorecardSaveItem[],
  expectedVersion: string,
): Promise<SavedScorecard> {
  const data = await request<SavedScorecard>(`/api/sessions/${sessionId}/scorecard?include_handoff_notes=false`, {
    method: "PUT", json: { items, expected_version: expectedVersion },
    toError: (response, body) => {
      const reason = extractError(body, response.status)
      return response.status === 409 && response.headers.get("X-InterviewCheck-Conflict") === "scorecard-version"
        ? new ScorecardVersionConflict(response.status, reason)
        : new ScorecardApiError(response.status, reason)
    },
  })
  if (!Array.isArray(data?.items) || typeof data.version !== "string" || !/^[a-f0-9]{64}$/.test(data.version)) {
    throw new Error("The server could not confirm the saved scorecard.")
  }
  return data
}

export const HANDOFF_PAGE_SIZE = 20
export type HandoffPage = { items: HandoffNote[]; total: number; next_cursor: string | null }

export async function fetchHandoffPage(sessionId: string, category: HandoffNoteCategory | "", cursor: string, signal: AbortSignal) {
  const qs = new URLSearchParams({ limit: String(HANDOFF_PAGE_SIZE) })
  if (category) qs.set("category", category)
  if (cursor) qs.set("cursor", cursor)
  const page = await requestJson<HandoffPage>(`/api/sessions/${encodeURIComponent(sessionId)}/handoff-notes?${qs}`, { signal })
  if (!Array.isArray(page?.items) || page.items.length > HANDOFF_PAGE_SIZE || !page.items.every(note => readableNote(note, sessionId)) ||
      !Number.isSafeInteger(page.total) || page.total < page.items.length ||
      !(page.next_cursor === null || (typeof page.next_cursor === "string" && page.next_cursor && page.next_cursor !== cursor))) {
    throw new Error("The server returned an unreadable handoff note page.")
  }
  return page
}

export async function createHandoffNote(
  sessionId: string,
  category: HandoffNoteCategory,
  body: string,
): Promise<HandoffNote> {
  const note = await requestJson<HandoffNote>(`/api/sessions/${sessionId}/handoff-notes`, { method: "POST", json: { category, body } })
  if (!readableNote(note, sessionId)) throw new Error("The server could not confirm the new handoff note.")
  return note
}

export function deleteHandoffNote(sessionId: string, noteId: string): Promise<void> {
  return requestJson(`/api/sessions/${sessionId}/handoff-notes/${noteId}`, { method: "DELETE" })
}
