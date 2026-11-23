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
  items: ScorecardItem[]
  weighted_score_pct: number | null
  handoff_notes: HandoffNote[]
}

export class ScorecardApiError extends ApiError {}

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
  return totalWeight > 0 ? Math.round((weightedSum / (totalWeight * 5)) * 1000) / 10 : null
}

export async function fetchSessionScorecard(sessionId: string, signal?: AbortSignal): Promise<ScorecardState> {
  try {
    const data = await requestJson<Omit<ScorecardState, "available">>(`/api/sessions/${sessionId}/scorecard`, { signal })
    return {
      available: true,
      items: Array.isArray(data.items) ? data.items : [],
      weighted_score_pct: typeof data.weighted_score_pct === "number" ? data.weighted_score_pct : null,
      handoff_notes: Array.isArray(data.handoff_notes) ? data.handoff_notes : [],
    }
  } catch (error) {
    if (error instanceof ScorecardApiError && (error.status === 404 || error.status === 501)) {
      return { available: false, items: [], weighted_score_pct: null, handoff_notes: [] }
    }
    throw error
  }
}

export function saveSessionScorecard(
  sessionId: string,
  items: ScorecardSaveItem[],
): Promise<{ items: ScorecardItem[]; weighted_score_pct: number | null }> {
  return requestJson(`/api/sessions/${sessionId}/scorecard`, { method: "PUT", body: JSON.stringify({ items }) })
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
