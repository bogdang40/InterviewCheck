import { errorMessage } from "./http"

type Counts = { new: number; identical: number; conflict: number }
type Kind = "roles" | "sessions"
type Conflict = { kind: Kind; id: string; label: string }
export type BackupPreview = {
  roles: Counts; sessions: Counts; answers: number; drafts: number; trashed: number
  assignments?: number; handoff_notes?: number; scorecard_items?: number
  fingerprint: string; conflicts: Conflict[]
}
export type BackupOperation = { action: "preview" } | { action: "restore"; preview: BackupPreview }

const invalid = "The workspace returned an invalid restore preview. Preview the file again."
const uncertain = "The restore may have completed. Preview the same file again to check which records are present."
const hex = /^[a-f\d]{64}$/i
const uuid = /^[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}$/
const reviewCounts = ["assignments", "handoff_notes", "scorecard_items"] as const

function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}
function count(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) throw new Error(invalid)
  return value
}
function total(group: Counts) {
  return count(group.new + group.identical + group.conflict)
}
function counts(value: unknown): Counts {
  if (!object(value)) throw new Error(invalid)
  return { new: count(value.new), identical: count(value.identical), conflict: count(value.conflict) }
}

function parseReply(value: unknown, digest: string, header: string | null): BackupPreview {
  if (!object(value)) throw new Error(invalid)
  if (value.fingerprint !== digest || (header !== null && header.toLowerCase() !== digest)) {
    throw new Error("The preview fingerprint does not match the selected file. Preview the file again.")
  }
  const roles = counts(value.roles), sessions = counts(value.sessions)
  const sessionCount = total(sessions)
  if (total(roles) > 4_000 || sessionCount > 5_000) throw new Error(invalid)
  if (!Array.isArray(value.conflicts) || value.conflicts.length !== Math.min(20, roles.conflict + sessions.conflict)) {
    throw new Error(invalid)
  }
  const seen = new Set<string>()
  const sampled = { roles: 0, sessions: 0 }
  const conflicts: Conflict[] = value.conflicts.map(entry => {
    if (!object(entry) || (entry.kind !== "roles" && entry.kind !== "sessions") ||
        typeof entry.id !== "string" || entry.id.length !== 36 || !uuid.test(entry.id) || typeof entry.label !== "string") {
      throw new Error(invalid)
    }
    const key = entry.kind + "/" + entry.id
    if (seen.has(key)) throw new Error(invalid)
    seen.add(key)
    sampled[entry.kind]++
    return { kind: entry.kind, id: entry.id, label: entry.label }
  })
  if (sampled.roles > roles.conflict || sampled.sessions > sessions.conflict) throw new Error(invalid)
  const reply: BackupPreview = {
    roles, sessions, fingerprint: digest, conflicts,
    answers: count(value.answers), drafts: count(value.drafts), trashed: count(value.trashed),
  }
  for (const field of reviewCounts) if (Object.hasOwn(value, field)) reply[field] = count(value[field])
  if (reply.trashed > sessionCount || reply.drafts > sessionCount || (reply.assignments ?? 0) > sessionCount ||
      reply.answers > sessionCount * 20_000 || (reply.scorecard_items ?? 0) > sessionCount * 25 ||
      (sessionCount === 0 && (reply.handoff_notes ?? 0) > 0)) {
    throw new Error(invalid)
  }
  return reply
}

export function canRestore(preview: BackupPreview) {
  return preview.roles.conflict === 0 && preview.sessions.conflict === 0 && preview.roles.new + preview.sessions.new > 0
}

function confirmsFile(before: BackupPreview, after: BackupPreview) {
  return after.roles.conflict === 0 && after.sessions.conflict === 0 &&
    total(before.roles) === total(after.roles) && total(before.sessions) === total(after.sessions) &&
    before.answers === after.answers && before.drafts === after.drafts && before.trashed === after.trashed &&
    reviewCounts.every(key => before[key] === undefined || before[key] === after[key])
}

async function fingerprint(file: File) {
  try {
    const bytes = await file.arrayBuffer()
    const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))
    return Array.from(hash, byte => byte.toString(16).padStart(2, "0")).join("")
  } catch {
    throw new Error("The checksum of the selected file could not be verified in this browser.")
  }
}

function rejection(body: unknown) {
  if (!object(body)) return false
  return (typeof body.detail === "string" && body.detail.length > 0) ||
    (Array.isArray(body.detail) && object(body.detail[0]) && typeof body.detail[0].msg === "string") ||
    (object(body.error) && typeof body.error.message === "string")
}

export async function submitBackup(file: File, expected: string, operation: BackupOperation, signal: AbortSignal): Promise<BackupPreview> {
  const checksum = expected.trim()
  if (checksum && (checksum.length !== 64 || !hex.test(checksum))) throw new Error("Enter a 64-character hexadecimal SHA-256 checksum.")
  const digest = await fingerprint(file)
  signal.throwIfAborted()
  if (checksum && digest !== checksum.toLowerCase()) throw new Error("The expected SHA-256 checksum does not match the selected file.")
  const headers: Record<string, string> = { "Content-Type": "application/json", "X-InterviewCheck": "1" }
  if (checksum) headers["X-Backup-SHA256"] = checksum
  if (operation.action === "restore") {
    if (operation.preview.fingerprint !== digest || !canRestore(operation.preview)) throw new Error("Preview this file again before restoring.")
    headers["X-Backup-Preview"] = operation.preview.fingerprint
  }

  let response: Response
  try {
    response = await fetch("/api/backups/" + operation.action, { method: "POST", headers, body: file, signal, cache: "no-store", redirect: "error" })
  } catch {
    throw new Error(operation.action === "restore" ? uncertain : "The preview could not reach the workspace. Preview the file again.")
  }
  if (response.status >= 500 || response.status === 408) {
    throw new Error(operation.action === "restore" ? uncertain : `The workspace could not preview the file (HTTP ${response.status}). Preview it again.`)
  }
  const mime = response.headers.get("Content-Type")?.split(";", 1)[0].trim().toLowerCase()
  if (response.ok && mime !== "application/json") {
    void response.body?.cancel().catch(() => {})
    throw new Error(operation.action === "restore" ? uncertain : invalid)
  }
  const body: unknown = await response.json().catch(() => null)
  if (response.status >= 400 && response.status < 500 && rejection(body)) {
    throw new Error(errorMessage(body, response.status))
  }
  try {
    if (response.status !== 200 || response.redirected) throw new Error(invalid)
    const result = parseReply(body, digest, response.headers.get("X-Backup-SHA256"))
    if (operation.action === "restore" && !confirmsFile(operation.preview, result)) throw new Error(uncertain)
    return result
  } catch (error) {
    if (operation.action === "restore") throw new Error(uncertain)
    throw error
  }
}
