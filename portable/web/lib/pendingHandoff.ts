import { ApiError, send } from "./http"
import { listDeferred, type DeferredQuestion } from "./deferredQuestions"

export const MAX_HANDOFF_ITEMS = 50
export const HANDOFF_FILENAME = "pending-questions.txt"
export type HandoffChoice = Pick<DeferredQuestion, "id" | "version" | "question" | "created_at" | "parent_answer_id">
export type HandoffPreview = { text: string; sha256: string }

function compareBytes(a: Uint8Array, b: Uint8Array) {
  for (let i = 0; i < Math.min(a.length, b.length); i++) {
    if (a[i] !== b[i]) return a[i] - b[i]
  }
  return a.length - b.length
}

/** SQLite orders these rows by the binary text values of created_at and id. */
function selectedText(items: readonly HandoffChoice[]) {
  const enc = new TextEncoder()
  return items.map(item => ({ item, order: enc.encode(item.created_at + "\0" + item.id) }))
    .sort((a, b) => compareBytes(a.order, b.order))
    .map(({ item }, i) => `${i + 1}. ${item.question}\n`).join("")
}

export class UnsupportedHandoff extends Error {}
export class UnverifiedHandoff extends Error {}

export async function fetchHandoff(sid: string, items: readonly HandoffChoice[],
                                   previous: HandoffPreview | null, signal: AbortSignal): Promise<HandoffPreview> {
  if (!globalThis.crypto?.subtle) throw new UnverifiedHandoff("Open the workspace on HTTPS or localhost to verify a handoff.")
  if (!items.length || items.length > MAX_HANDOFF_ITEMS || new Set(items.map(i => i.id)).size !== items.length) {
    throw new UnverifiedHandoff("Select between one and 50 distinct pending questions.")
  }
  const expected = selectedText(items)
  if (previous && previous.text !== expected) throw new UnverifiedHandoff("The selection changed. Preview it again.")
  const body = { items: items.map(({ id, version }) => ({ id, version })),
    ...(previous && { preview_sha256: previous.sha256 }) }
  let response: Response
  try {
    response = await send(`/api/sessions/${encodeURIComponent(sid)}/deferred-questions/handoff/${previous ? "verify" : "preview"}`, {
      method: "POST", json: body, signal,
      toError: r => new ApiError(r.status, "The server could not verify this handoff.", r.headers.get("X-InterviewCheck-Conflict") ?? undefined),
    })
  } catch (error) {
    if (!(error instanceof ApiError) || ![404, 405, 501].includes(error.status)) throw error
    // Only an authorized, readable pending queue establishes that the route itself is missing.
    await listDeferred(sid, "pending", 1, signal)
    throw new UnsupportedHandoff("This server does not support pending question handoffs.")
  }
  const data = await response.json().catch(() => null)
  signal.throwIfAborted()
  if (!data || Object.keys(data).length !== 2 || data.text !== expected || typeof data.sha256 !== "string" ||
      !/^[0-9a-f]{64}$/.test(data.sha256)) {
    throw new UnverifiedHandoff("The reply did not match the selected questions. Preview them again.")
  }
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(expected)))
  signal.throwIfAborted()
  const digest = Array.from(hash, byte => byte.toString(16).padStart(2, "0")).join("")
  if (data.sha256 !== digest || (previous && (previous.sha256 !== digest || previous.text !== data.text))) {
    throw new UnverifiedHandoff("The handoff checksum changed. Preview the questions again.")
  }
  return { text: data.text, sha256: digest }
}
