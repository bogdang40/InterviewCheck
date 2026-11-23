import type { Disposition, QuestionOrigin, Source } from "./api"
import { DRAFT_KEY_PREFIX, isDraftExpired } from "./localDraftSweep"

export type LocalDraftPayload = {
  text: string
  disposition?: Disposition
  note?: string
  savedAt: string
  baseRevision?: number
  question?: string
  sources?: Source[]
  origin?: QuestionOrigin
  answerId?: string
  draftId?: string
}

export type DraftRecord = { key: string; raw: string; data: LocalDraftPayload }

export function editorDraftKey(sessionId: string, answerId?: string, savedDraftId?: string) {
  const suffix = answerId ?? (savedDraftId ? "saved:" + savedDraftId : "new")
  return `${DRAFT_KEY_PREFIX}${sessionId}:editor:${suffix}`
}

export const reviewDraftKey = (sessionId: string, answerId: string) => `${DRAFT_KEY_PREFIX}${sessionId}:review:${answerId}`
const unlinkedPrefix = (id: string) => DRAFT_KEY_PREFIX + id + ":unlinked:"
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const outcomes = new Set(["pending", "explained", "unresolved", "disclosed"])

function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function text(value: unknown, limit: number): value is string {
  if (typeof value !== "string" || value.length > limit * 2) return false
  if (value.length <= limit) return true
  // Python validates code points. A character outside the BMP is two JS code units.
  let count = 0
  for (const _ of value) if (++count > limit) return false
  return true
}

function positive(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0
}

function identifier(value: unknown): value is string {
  return typeof value === "string" && value.length === 36 && uuid.test(value)
}

function validSource(value: unknown): value is Source {
  return object(value) && text(value.label, 180) && text(value.text, 24000) && typeof value.permitted === "boolean"
}

function validOrigin(value: unknown): value is QuestionOrigin {
  if (!object(value)) return false
  const { parent_answer_id: parent, planned_slot: slot } = value
  return (parent == null || identifier(parent)) && (slot == null || positive(slot)) && !(parent && slot)
}

function validPayload(value: unknown): value is LocalDraftPayload {
  if (!object(value) || !text(value.text, 24000) || !text(value.savedAt, 64)) return false
  return (value.question === undefined || text(value.question, 4000)) &&
    (value.note === undefined || text(value.note, 24000)) &&
    (value.sources === undefined || (Array.isArray(value.sources) && value.sources.length <= 12 && value.sources.every(validSource))) &&
    (value.disposition === undefined || (typeof value.disposition === "string" && outcomes.has(value.disposition))) &&
    (value.origin === undefined || validOrigin(value.origin)) &&
    (value.baseRevision === undefined || positive(value.baseRevision)) &&
    (value.answerId === undefined || identifier(value.answerId)) &&
    (value.draftId === undefined || identifier(value.draftId)) && !(value.answerId && value.draftId)
}

export function draftStorage(): Storage | null {
  try { return window.localStorage } catch { return null }
}

export function removeRecord(record: Pick<DraftRecord, "key" | "raw"> | null) {
  const storage = draftStorage()
  if (!record || !storage) return
  try {
    if (storage.getItem(record.key) === record.raw) storage.removeItem(record.key)
  } catch { /* storage may be unavailable */ }
}

export function readRecord(key: string): DraftRecord | null {
  const storage = draftStorage()
  if (!storage) return null
  try {
    const raw = storage.getItem(key)
    if (!raw || raw.length > 2_000_000) return null
    const data: unknown = JSON.parse(raw)
    if (!validPayload(data)) return null
    if (isDraftExpired(data.savedAt)) { removeRecord({ key, raw }); return null }
    const { text, savedAt, answerId, draftId, baseRevision, question, sources, origin, disposition, note } = data
    return { key, raw, data: {
      text, savedAt, answerId, draftId, baseRevision, question, disposition, note,
      sources: sources?.map(({ label, text, permitted }) => ({ label, text, permitted })),
      origin: origin && { planned_slot: origin.planned_slot, parent_answer_id: origin.parent_answer_id },
    } }
  } catch { return null }
}

export function ambiguous(record: DraftRecord | null): boolean {
  return !!record && !!record.data.baseRevision && !record.data.answerId && !record.data.draftId && record.key.endsWith(":editor:new")
}

/** Old editors shared one key between new exchanges and all resumed server drafts. */
export function preserveUnlinked(sessionId: string): DraftRecord | null {
  const storage = draftStorage()
  const old = readRecord(editorDraftKey(sessionId))
  if (!storage || !old || !ambiguous(old)) return null
  try {
    let key = unlinkedPrefix(sessionId) + encodeURIComponent(old.data.savedAt)
    const existing = storage.getItem(key)
    if (existing !== null && existing !== old.raw) key += ":" + crypto.randomUUID()
    storage.setItem(key, old.raw)
    removeRecord(old)
    return { ...old, key }
  } catch {
    // When storage is full, keep the original readable and never overwrite it.
    return old
  }
}

export function latestUnlinked(sessionId: string): DraftRecord | null {
  const moved = preserveUnlinked(sessionId)
  const storage = draftStorage()
  if (!storage) return moved
  let latest = moved
  try {
    for (const key of Object.keys(storage)) {
      if (!key.startsWith(unlinkedPrefix(sessionId))) continue
      const record = readRecord(key)
      if (record && (!latest || Date.parse(record.data.savedAt) > Date.parse(latest.data.savedAt))) latest = record
    }
  } catch { /* return the known copy when enumeration fails */ }
  return latest
}
