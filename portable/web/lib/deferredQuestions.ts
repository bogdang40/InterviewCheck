import { api, type Answer, type Draft, type Interview, type Source } from "./api"
import { ApiError, request } from "./http"
import { deferredFields } from "./deferredSubmission"
import { currentWorksheet } from "./reviewWorksheet"

export const deferredStates = ["pending", "dismissed", "fulfilled"] as const
export type DeferredStatus = typeof deferredStates[number]
export type DeferredFilter = DeferredStatus | "all"
export type DeferredLink = { id: string; version: string }
export type DeferredQuestion = DeferredLink & {
  session_id: string; parent_answer_id: string; question: string; status: DeferredStatus
  needs_reconfirmation: boolean; child_answer_id: string | null; created_at: string
}
export type DeferredPage = { items: DeferredQuestion[]; page: number; page_size: number; total: number; pending_count: number }
export type SourceReview = { session: Interview; answer: Answer; ordinal: number; material: string }

const validId = (id: unknown): id is string => typeof id === "string" && /^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(id)
const digest = (v: unknown) => typeof v === "string" && /^[\da-f]{64}$/.test(v)
const count = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= 0
const route = (sid: string) => `/api/sessions/${sid}/deferred-questions`

function checked(row: DeferredQuestion | null, sid: string, id?: string): DeferredQuestion {
  if (!row || !validId(row.id) || (id && row.id !== id) || row.session_id !== sid || !validId(row.parent_answer_id)
      || !digest(row.version) || !deferredStates.includes(row.status) || typeof row.question !== "string" || !row.question.trim()
      || typeof row.needs_reconfirmation !== "boolean" || typeof row.created_at !== "string"
      || (row.status === "fulfilled" ? !validId(row.child_answer_id) : row.child_answer_id !== null)) {
    throw new Error("The server did not confirm the deferred question. Reload the list to check its saved state.")
  }
  return row
}

export async function listDeferred(sid: string, filter: DeferredFilter, page: number, signal: AbortSignal) {
  const result = await request<DeferredPage>(`${route(sid)}?status=${filter}&page=${page}&page_size=10`, { signal })
  if (!result || !Array.isArray(result.items) || !count(result.page) || result.page < 1 || result.page > page || result.page_size !== 10 ||
      !count(result.total) || !count(result.pending_count) || result.items.length > 10) {
    throw new Error("The server returned an incomplete deferred question list.")
  }
  result.items.forEach(item => checked(item, sid))
  return result
}

export async function readDeferred(sid: string, id: string, signal?: AbortSignal) {
  return checked(await request<DeferredQuestion>(`${route(sid)}/${id}`, { signal }), sid, id)
}

export async function keepDeferred(sid: string, id: string, parent: string, question: string, expectedMaterial: string, signal: AbortSignal) {
  const saved = checked(await request<DeferredQuestion>(route(sid), {
    method: "POST", signal, json: { id, parent_answer_id: parent, question, expected_material: expectedMaterial },
  }), sid, id)
  if (saved.parent_answer_id !== parent || saved.question !== question) throw new Error("Check the saved question before retrying.")
  return saved
}

export async function changeDeferred(item: DeferredQuestion, action: "dismiss" | "reopen" | "reconfirm", signal: AbortSignal, material?: string) {
  const saved = checked(await request<DeferredQuestion>(`${route(item.session_id)}/${item.id}`, {
    method: "PATCH", signal, json: { action, expected_version: item.version, ...(material ? { expected_material: material } : {}) },
  }), item.session_id, item.id)
  if (saved.status !== (action === "dismiss" ? "dismissed" : "pending") || saved.parent_answer_id !== item.parent_answer_id
      || saved.question !== item.question || (action !== "dismiss" && saved.needs_reconfirmation)) {
    throw new Error("The server did not confirm the requested change. Check the saved question.")
  }
  return saved
}

export async function readDeferredSource(sid: string, parentId: string, signal: AbortSignal): Promise<SourceReview> {
  const session = await api<Interview>(`sessions/${sid}`, "GET", undefined, signal)
  if (session?.id !== sid || !session.consent || session.ended_at || (session.privacy_state && session.privacy_state !== "unmarked")) {
    throw new Error("This interview is no longer open for capture.")
  }
  const index = session.answers.findIndex(a => a.id === parentId)
  if (index < 0) throw new Error("The source exchange is no longer available.")
  const answer = session.answers[index]
  const saved = await currentWorksheet(session, answer, index + 1, signal)
  return { session, answer, ordinal: index + 1, material: saved.material }
}

export function matchesDeferredDraft(draft: Draft | null, item: DeferredQuestion, id?: string): boolean {
  return !!draft && validId(draft.id) && (!id || draft.id === id) && count(draft.revision) && draft.revision > 0
    && typeof draft.answer === "string" && Array.isArray(draft.references) && typeof draft.updated_at === "string"
    && draft.parent_answer_id === item.parent_answer_id && draft.planned_slot == null && draft.question === item.question
    && draft.deferred_question?.id === item.id && draft.deferred_question.version === item.version
}

export function sameSources(stored: Source[], proposed: Source[]) {
  return Array.isArray(stored) && stored.length === proposed.length && stored.every((r, i) =>
    r?.text === proposed[i].text && r.label === proposed[i].label && !!r.permitted === !!proposed[i].permitted)
}

export async function saveDeferredDraft(item: DeferredQuestion, id: string, revision: number, answer: string,
                                        sources: Source[], signal?: AbortSignal) {
  const fields = deferredFields(item.question, answer, sources)
  const saved = await api<Draft>(`sessions/${item.session_id}/draft`, "PUT", {
    id, expected_revision: revision, parent_answer_id: item.parent_answer_id, planned_slot: null, ...fields,
    deferred_question: { id: item.id, version: item.version },
  }, signal)
  if (!matchesDeferredDraft(saved, item, id) || saved.answer !== fields.answer ||
      !sameSources(saved.references, fields.references)) {
    throw new Error("The server did not confirm this saved draft. Check the current draft before retrying.")
  }
  return saved
}

export function accessLost(error: unknown) {
  return error instanceof ApiError && [401, 402, 403, 404].includes(error.status)
}
