export type PermittedMaterial = { label: string; text: string }
export type Source = { label: string; text: string; permitted: boolean }
export type Passage = { answer_span?: [number, number]; source_span?: [number, number]; source_index?: number; label: string; answer_excerpt: string; source_excerpt: string; words: number }
export type Disposition = "pending" | "explained" | "unresolved" | "disclosed"
export type TranscriptOrigin = {
  format: "webvtt"; transcript_sha256: string; candidate_speaker: string; interviewer_speakers: string[];
  ordinal: number; start_ms: number; end_ms: number; first_cue?: number; last_cue?: number; input_sha256: string
}
export type QuestionOrigin = { parent_answer_id?: string | null; planned_slot?: number | null }
export type Answer = QuestionOrigin & {
  import_origin?: TranscriptOrigin
  id: string
  revision: number
  question: string
  answer: string
  references: Source[]
  result: {
    status: "match" | "no_match" | "insufficient"
    explanation: string
    passages: Passage[]
    follow_up: string
  }
  note: string
  disposition: Disposition
  legacy?: Record<string, unknown> | null
}
export type Session = {
  id: string
  candidate: string
  role: string
  policy: string
  consent: boolean
  ended_at: string | null
  role_id: string | null
  created_at: string
  answer_count: number
  first_pending_answer_id: string | null
  review_count: number
}
export type DraftSummary = {id:string;revision:number;updated_at:string}
export type Draft = QuestionOrigin & DraftSummary & {deferred_question?: { id: string; version: string } | null; question:string;answer:string;references:Source[]}
export type Interview = Session & { privacy_state?: "unmarked" | "anonymized" | "legacy_unverified"; draft:DraftSummary|null; answers: Answer[]; planned_questions: string[]; permitted_sources: PermittedMaterial[] }
export type Role = { id: string; version: string; name: string; description: string; questions: string[]; policy: string; permitted_sources: PermittedMaterial[] }

export class RevisionConflict extends Error {}
export class WorksheetUnavailable extends Error {}
export class DeferredConflict extends Error {}
export class DraftConflict extends Error {}
export class RoleConflict extends Error {}

export async function api<T>(path: string, method = "GET", body?: unknown, signal?: AbortSignal): Promise<T> {
  const response = await fetch("/api/" + path, {
    method,
    signal,
    cache: "no-store",
    headers: { "Content-Type": "application/json", "X-InterviewCheck": "1" },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  if (!response.ok) {
    const data = await response.json().catch(() => ({}))
    const detail = typeof data?.detail === "string" ? data.detail : data?.detail?.[0]?.msg
    const guardedSave = method === "PATCH" && typeof body === "object" && body !== null && "worksheet_guard" in body
    const unavailable = [401, 402, 403, 404].includes(response.status)
      || response.headers.get("X-InterviewCheck-Worksheet") === "unavailable"
    if (unavailable && (guardedSave || (method === "GET" && path.endsWith("/worksheet")))) {
      throw new WorksheetUnavailable(detail || "The worksheet exchange is no longer available.")
    }
    if (response.status === 409 && response.headers.get("X-InterviewCheck-Conflict") === "role-version") {
      throw new RoleConflict(detail)
    }
    if(response.status===409 && response.headers.get("X-InterviewCheck-Conflict")==="deferred-question") throw new DeferredConflict(detail || "The deferred question changed.")
    if(response.status===409 && response.headers.get("X-InterviewCheck-Conflict")==="draft-revision") throw new DraftConflict(detail || "Draft conflict.")
    if (response.status === 409 && response.headers.get("X-InterviewCheck-Conflict") === "answer-revision") {
      throw new RevisionConflict(detail || "The saved exchange changed.")
    }
    throw new Error(detail || data.error?.message || `Request failed (HTTP ${response.status}).`)
  }
  return response.status === 204 ? (undefined as T) : response.json()
}

/** The API's reply when no one is signed in (portable/api/access.py, local_boundary.py). */
export const SIGN_IN_REQUIRED = "Sign in under Account."

export function needsSignIn(text: string) {
  return text.trim() === SIGN_IN_REQUIRED
}

export function message(error: unknown) {
  return error instanceof Error ? error.message : "The operation failed."
}
export const statusText = {
  match: "Passage match",
  no_match: "No passage match",
  insufficient: "Limited evidence",
}
const shortDate = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", year: "numeric" })
export const dateLabel = (iso: string) => shortDate.format(new Date(iso))
