import type { Answer, Disposition } from "./api"
import { ApiError, errorMessage, request } from "./http"

export const panelLabels = {
  none: "No disagreement",
  open: "Awaiting panel review",
  discussion_complete: "Discussion completed",
  follow_up_required: "Follow up required",
  reopened: "Discussion reopened",
  changed: "Review context changed",
}
export type PanelStatus = keyof typeof panelLabels
export type PanelAction = "discussion_complete" | "follow_up_required" | "reopened"
export type PanelView = "open" | "all" | "completed"
type PanelEvent = { sequence: number; action: PanelAction; actor_email?: string; rationale?: string; created_at: string }
export type PanelCase = {
  session_id: string; answer_id: string; status: PanelStatus; split: boolean; basis: string; version: string; evidence: string
  editor?: string; history_count: number; history: PanelEvent[]
  reviewers: { reviewer_email: string; disposition: Disposition; created_at: string }[]
}

export async function displayedEvidence(item: Answer): Promise<string> {
  if (!globalThis.crypto?.subtle) throw new Error("Open the workspace on HTTPS or localhost to verify the exchange.")
  const refs = item.references.map(r => [r.label, r.text, !!r.permitted])
  const passages = item.result.passages.map(p => [p.label, p.answer_excerpt, p.source_excerpt, p.words,
    p.source_index ?? null, p.answer_span ?? null, p.source_span ?? null])
  const material = [item.id, item.question, item.answer, refs, item.result.status, item.result.explanation,
    item.result.follow_up, passages, item.parent_answer_id ?? null, item.planned_slot ?? null]
  const content = [material, item.revision, item.disposition, item.note]
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(content))))
  return Array.from(hash, byte => byte.toString(16).padStart(2, "0")).join("")
}

function validDigest(value: unknown) {
  return typeof value === "string" && /^[0-9a-f]{64}$/.test(value)
}

function checked(data: PanelCase, sid: string, aid: string): PanelCase {
  if (!data || data.session_id !== sid || data.answer_id !== aid || !Object.hasOwn(panelLabels, data.status) ||
      !validDigest(data.basis) || !validDigest(data.version) || !validDigest(data.evidence) ||
      !Number.isSafeInteger(data.history_count) || data.history_count < 0 || !Array.isArray(data.reviewers) ||
      !data.reviewers.every(r => r && typeof r.reviewer_email === "string" &&
        ["explained", "unresolved", "disclosed"].includes(r.disposition) && typeof r.created_at === "string") ||
      typeof data.split !== "boolean" || !Array.isArray(data.history) || data.history.length > 10 || !data.history.every(h => h && Number.isSafeInteger(h.sequence) &&
        ["discussion_complete", "follow_up_required", "reopened"].includes(h.action) &&
        (h.rationale === undefined || typeof h.rationale === "string") &&
        (h.actor_email === undefined || typeof h.actor_email === "string") && typeof h.created_at === "string")) {
    throw new Error("The server could not confirm the panel review.")
  }
  return data
}

function route(sid: string, aid: string) {
  return `/api/calibration/sessions/${encodeURIComponent(sid)}/answers/${encodeURIComponent(aid)}/panel`
}

export async function readPanel(sid: string, aid: string, before: number | null, signal: AbortSignal, privateNotes = false, editing = false) {
  const suffix = before === null ? "" : `?before=${before}`
  const result = checked(await request<PanelCase>(route(sid, aid) + (privateNotes ? "/private" : editing ? "/edit" : "") + suffix, { signal }), sid, aid)
  if ((privateNotes || editing) && !validDigest(result.editor)) throw new Error("The server did not confirm this panel editor.")
  return result
}

export async function writePanel(state: PanelCase, action: PanelAction, rationale: string, signal: AbortSignal) {
  if (!validDigest(state.editor)) throw new Error("Read the administrator panel context before saving.")
  const json = { action, rationale, expected_editor: state.editor, expected_basis: state.basis, expected_version: state.version, expected_evidence: state.evidence }
  return checked(await request<PanelCase>(route(state.session_id, state.answer_id), {
    method: "POST", json, signal,
    toError: (response, body) => new ApiError(response.status, errorMessage(body, response.status),
      response.headers.get("X-InterviewCheck-Conflict") ?? undefined),
  }),
    state.session_id, state.answer_id)
}
