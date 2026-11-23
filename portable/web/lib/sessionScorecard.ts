"use client"

import { ApiError, request } from "./http"

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
export type ScorecardState = {
  available: boolean
  version: string | null
  items: ScorecardItem[]
  weighted_score_pct: number | null
  handoff_notes: HandoffNote[]
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

export function requestJson<T>(url: string, options: RequestInit = {}): Promise<T> {
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
    const data = await requestJson<Omit<ScorecardState, "available">>(`/api/sessions/${sessionId}/scorecard`, { signal })
    if (!Array.isArray(data?.items)) throw new Error("The server returned an unreadable scorecard.")
    return {
      available: true,
      version: typeof data.version === "string" && /^[a-f0-9]{64}$/.test(data.version) ? data.version : null,
      items: data.items,
      weighted_score_pct: typeof data.weighted_score_pct === "number" ? data.weighted_score_pct : null,
      handoff_notes: Array.isArray(data.handoff_notes) ? data.handoff_notes : [],
    }
  } catch (error) {
    if (error instanceof ScorecardApiError && (error.status === 404 || error.status === 501)) {
      return { available: false, version: null, items: [], weighted_score_pct: null, handoff_notes: [] }
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
  const data = await request<SavedScorecard>(`/api/sessions/${sessionId}/scorecard`, {
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

export function createHandoffNote(
  sessionId: string,
  category: HandoffNoteCategory,
  body: string,
): Promise<HandoffNote> {
  return requestJson(`/api/sessions/${sessionId}/handoff-notes`, { method: "POST", body: JSON.stringify({ category, body }) })
}

export function deleteHandoffNote(sessionId: string, noteId: string): Promise<void> {
  return requestJson(`/api/sessions/${sessionId}/handoff-notes/${noteId}`, { method: "DELETE" })
}
