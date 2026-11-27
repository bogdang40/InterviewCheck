import { api, type Answer, type Interview } from "./api"
import { MAX_NOTE_CHARACTERS, normalizedWorksheetNote } from "./worksheetNote"

export { MAX_NOTE_CHARACTERS, normalizedWorksheetNote } from "./worksheetNote"

export const MAX_WORKSHEET_BYTES = 96 * 1024
// Four UTF-8 bytes per scalar, plus a possible BOM, ten CRLF header lines and a final CRLF.
const NOTE_RESERVE = 4 * MAX_NOTE_CHARACTERS + 15
const title = "InterviewCheck review worksheet v1"
const marker = "=== Proposed interviewer note ==="
const uuid = /^[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}$/i
const receipt = /^[a-f\d]{64}$/
const forbidden = /[\u0000-\u0008\u000b-\u001f\u007f\u202a-\u202e\u2066-\u2069]/

export type WorksheetGuard = { material: string; review: string }
type Context = Pick<Interview, "candidate" | "role" | "created_at" | "consent" | "policy" | "role_id" | "planned_questions" | "permitted_sources">
export type WorksheetState = WorksheetGuard & { session_id: string; ordinal: number; session: Context; answer: Answer }
export type Worksheet = WorksheetGuard & {
  sessionId: string; answerId: string; ordinal: number; revision: number; question: string | null; excerpt: string | null; note: string
}
export type Disclosure = { question: boolean; excerpt: boolean }

function stable(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stable)
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
      .map(([k, v]) => [k, stable(v)]))
  }
  return value
}

function material(answer: Answer) {
  const { revision, disposition, note, ...fields } = answer
  return fields
}

export function confirmsWorksheetSave(saved: Answer | null, original: Answer, note: string): saved is Answer {
  return !!saved && typeof saved === "object" && saved.note === note && saved.disposition === original.disposition
    && saved.revision === original.revision + (note === original.note ? 0 : 1)
    && JSON.stringify(stable(material(saved))) === JSON.stringify(stable(material(original)))
}

export async function currentWorksheet(session: Interview, item: Answer, ordinal: number, signal?: AbortSignal): Promise<WorksheetState> {
  const live = await api<WorksheetState>(`sessions/${session.id}/answers/${item.id}/worksheet`, "GET", undefined, signal)
  if (!live?.session || !live.answer || !receipt.test(live.material) || !receipt.test(live.review)
    || live.session_id !== session.id || live.answer.id !== item.id || live.ordinal !== ordinal
    || !Number.isSafeInteger(live.answer.revision) || live.answer.revision < 1 || typeof live.answer.note !== "string"
    || !["pending", "explained", "unresolved", "disclosed"].includes(live.answer.disposition)) {
    throw new Error("The saved exchange could not be verified. Reload the interview.")
  }
  const context: Context = {
    candidate: session.candidate, role: session.role, created_at: session.created_at, consent: session.consent,
    policy: session.policy, role_id: session.role_id, planned_questions: session.planned_questions,
    permitted_sources: session.permitted_sources,
  }
  if (JSON.stringify(stable([live.session, material(live.answer)])) !== JSON.stringify(stable([context, material(item)]))) {
    throw new Error("The exchange has changed. Reload the interview before using a worksheet.")
  }
  return live
}

function firstExcerpt(answer: string) {
  return Array.from(answer).slice(0, 240).join("")
}

function display(value: string | null) {
  if (value === null) return "Omitted"
  // Keep every header on one visible line, including text from a pasted prompt.
  return JSON.stringify(value).replace(/[\u007f\u2028\u2029\u202a-\u202e\u2066-\u2069]/g,
    ch => "\\u" + ch.charCodeAt(0).toString(16).padStart(4, "0"))
}

export function worksheetText(saved: WorksheetState, fields: Disclosure) {
  const text = [title, "Session: " + saved.session_id, "Exchange: " + saved.answer.id, "Number: " + saved.ordinal,
    "Revision: " + saved.answer.revision, "Material: " + saved.material, "Review: " + saved.review,
    "Question: " + display(fields.question ? saved.answer.question : null),
    "Candidate excerpt: " + display(fields.excerpt ? firstExcerpt(saved.answer.answer) : null),
    marker, ""].join("\n")
  if (new TextEncoder().encode(text).length + NOTE_RESERVE > MAX_WORKSHEET_BYTES) {
    throw new Error("These fields leave too little room for a full review note. Omit the question or answer excerpt and preview again.")
  }
  return text
}

function field(line: string | undefined, label: string) {
  if (!line?.startsWith(label + ": ")) throw new Error("The worksheet header is missing or out of order.")
  return line.slice(label.length + 2)
}

function positive(text: string) {
  if (!/^[1-9]\d*$/.test(text) || !Number.isSafeInteger(Number(text))) throw new Error("Invalid worksheet revision or exchange number.")
  return Number(text)
}

function disclosed(text: string) {
  if (text === "Omitted") return null
  try {
    const value: unknown = JSON.parse(text)
    if (typeof value === "string" && text === display(value)) return value
  } catch { /* Use the same error for invalid JSON and edited header syntax. */ }
  throw new Error("The disclosure fields have changed. Edit only the proposed note.")
}

export function parseWorksheet(raw: string): Worksheet {
  if (new TextEncoder().encode(raw).length > MAX_WORKSHEET_BYTES) throw new Error("The worksheet exceeds 96 KiB.")
  const lines = raw.replace(/^\ufeff/, "").replace(/\r\n/g, "\n").split("\n")
  if (lines[0] !== title || lines[9] !== marker || lines.slice(10).includes(marker)) {
    throw new Error("Use a version 1 worksheet with one proposed note marker.")
  }
  const sessionId = field(lines[1], "Session"), answerId = field(lines[2], "Exchange")
  const ordinal = positive(field(lines[3], "Number")), revision = positive(field(lines[4], "Revision"))
  const material = field(lines[5], "Material"), review = field(lines[6], "Review")
  if (!uuid.test(sessionId) || !uuid.test(answerId) || !receipt.test(material) || !receipt.test(review)) {
    throw new Error("The worksheet return metadata is invalid.")
  }
  const body = lines.slice(10).join("\n")
  if (forbidden.test(body)) throw new Error("Remove control or bidirectional formatting characters from the note.")
  const note = normalizedWorksheetNote(body)
  if (!note || Array.from(note).length > MAX_NOTE_CHARACTERS) throw new Error("Enter a proposed note of 1 to 12,000 characters.")
  return { sessionId, answerId, ordinal, revision, material, review, question: disclosed(field(lines[7], "Question")),
    excerpt: disclosed(field(lines[8], "Candidate excerpt")), note }
}

export function verifyWorksheet(file: Worksheet, live: WorksheetState) {
  if (file.sessionId !== live.session_id || file.answerId !== live.answer.id || file.ordinal !== live.ordinal
    || file.material !== live.material || (file.question !== null && file.question !== live.answer.question)
    || (file.excerpt !== null && file.excerpt !== firstExcerpt(live.answer.answer))) {
    throw new Error("This worksheet belongs to a different workspace, exchange or version of the evidence.")
  }
}

export async function readWorksheetFile(file: File) {
  if (file.size > MAX_WORKSHEET_BYTES) throw new Error("The worksheet exceeds 96 KiB.")
  const bytes = await file.arrayBuffer()
  let text: string
  try { text = new TextDecoder("utf-8", { fatal: true }).decode(bytes) }
  catch { throw new Error("Save the worksheet as UTF-8 plain text.") }
  return parseWorksheet(text)
}
