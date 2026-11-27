import { saveBlob } from "./download"

const MAX_BACKUP = 20 * 1024 * 1024
const MAX_ERROR = 4 * 1024

function backupTarget(sessionId: string | null) {
  const base = "/api/backups/workspace"
  if (sessionId === null) return { url: base, filename: "interviewcheck-workspace.json" }
  const uuid = /^[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}$/i
  const id = uuid.test(sessionId) ? sessionId.toLowerCase() : sessionId
  return { url: base + "?session_id=" + encodeURIComponent(id), filename: `interview-${id}.json` }
}

export function backupURL(sessionId: string | null): string {
  return backupTarget(sessionId).url
}

class BodyTooLarge extends Error {}

function discard(response: Response) {
  void response.body?.cancel().catch(() => {})
}

async function readBytes(response: Response, limit: number, signal: AbortSignal): Promise<Uint8Array<ArrayBuffer>> {
  const length = Number(response.headers.get("Content-Length"))
  if (!response.headers.get("Content-Encoding") && length > limit) {
    discard(response)
    throw new BodyTooLarge()
  }
  const reader = response.body?.getReader()
  if (!reader) throw new Error("The workspace returned an empty response. Retry the download.")
  const cancel = () => { void reader.cancel().catch(() => {}) }
  signal.addEventListener("abort", cancel, { once: true })
  try {
    signal.throwIfAborted()
    let used = 0
    let bytes = new Uint8Array(Number.isSafeInteger(length) && length > 0 ? Math.min(length, limit) : 0)
    while (true) {
      const { done, value } = await reader.read()
      signal.throwIfAborted()
      if (done) return bytes.subarray(0, used)
      const needed = used + value.byteLength
      if (needed > limit) throw new BodyTooLarge()
      if (needed > bytes.length) {
        const larger = new Uint8Array(Math.min(limit, Math.max(needed, bytes.length * 2, 4096)))
        larger.set(bytes.subarray(0, used))
        bytes = larger
      }
      bytes.set(value, used)
      used = needed
    }
  } catch (error) {
    cancel()
    throw error
  } finally {
    signal.removeEventListener("abort", cancel)
    reader.releaseLock()
  }
}

async function failedDownload(response: Response, signal: AbortSignal): Promise<Error> {
  // Only the interview ID from a recognized server error is useful here. Never
  // reflect arbitrary gateway pages, private notes or account payloads.
  if (response.status === 409) {
    let record = "An interview"
    try {
      const bytes = await readBytes(response, MAX_ERROR, signal)
      const detail = JSON.parse(new TextDecoder().decode(bytes))?.detail
      const id = typeof detail === "string" && /^Interview ([a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}) contains /i.exec(detail)
      if (id) record = `Interview ${id[1]}`
    } catch { signal.throwIfAborted() }
    return new Error(`${record} contains data this JSON backup cannot preserve. Use a consistent SQLite backup.`)
  }
  discard(response)
  switch (response.status) {
    case 401: return new Error("Sign in to the workspace again, then retry the backup.")
    case 402: return new Error("An active InterviewCheck plan is required to download a backup.")
    case 403: return new Error("This account cannot download the backup. Check the workspace account.")
    case 404: return new Error("The selected backup is unavailable. Choose another interview or check the workspace.")
    case 413: return new Error("The backup exceeds the JSON export limits. Use a smaller interview backup or a consistent SQLite backup.")
    default: return new Error(`The workspace could not provide the backup (HTTP ${response.status}). Retry the download.`)
  }
}

export async function downloadBackup(sessionId: string | null, signal: AbortSignal): Promise<{ checksum: string; deferredQuestions?: number }> {
  signal.throwIfAborted()
  if (!globalThis.crypto?.subtle) throw new Error("Open the workspace over HTTPS or localhost to verify the backup.")
  const { url, filename } = backupTarget(sessionId)
  let response: Response
  try {
    response = await fetch(url, {
      credentials: "same-origin", mode: "same-origin", redirect: "error", cache: "no-store", signal,
      headers: { "X-InterviewCheck": "1" },
    })
  } catch {
    signal.throwIfAborted()
    throw new Error("Could not reach the workspace. Check the connection and retry the backup.")
  }
  if (signal.aborted) { discard(response); signal.throwIfAborted() }
  if (response.status !== 200) throw await failedDownload(response, signal)
  const mime = response.headers.get("Content-Type")?.split(";", 1)[0].trim().toLowerCase()
  const disposition = response.headers.get("Content-Disposition") ?? ""
  const name = /^attachment\s*;\s*filename\s*=\s*(?:"([^"\\]+)"|([\w.-]+))\s*$/i.exec(disposition)
  const expectedHash = response.headers.get("X-Backup-SHA256")
  if (response.redirected || mime !== "application/json" || (name?.[1] ?? name?.[2]) !== filename || !expectedHash || !/^[a-f\d]{64}$/i.test(expectedHash)) {
    discard(response)
    throw new Error("The workspace did not return a verifiable backup for this selection. Retry the download.")
  }
  const reported = response.headers.get("X-Backup-Deferred-Questions")
  const deferredQuestions = reported === null ? undefined : Number(reported)
  if (reported !== null && (!/^(0|[1-9]\d*)$/.test(reported) || !Number.isSafeInteger(deferredQuestions))) {
    discard(response)
    throw new Error("The workspace returned an invalid deferred question count. Retry the download.")
  }
  let bytes: Uint8Array<ArrayBuffer>
  try {
    bytes = await readBytes(response, MAX_BACKUP, signal)
  } catch (error) {
    signal.throwIfAborted()
    if (error instanceof BodyTooLarge) throw new Error("The backup exceeds 20 MiB. Use a consistent SQLite backup.")
    throw new Error("The backup transfer was interrupted. Retry the download.")
  }
  if (!bytes.length) throw new Error("The workspace returned an empty backup. Retry the download.")
  let digest: Uint8Array<ArrayBuffer>
  try {
    digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))
  } catch {
    signal.throwIfAborted()
    throw new Error("The backup checksum could not be verified. Retry the download.")
  }
  signal.throwIfAborted()
  const actualHash = Array.from(digest, (n) => n.toString(16).padStart(2, "0")).join("")
  if (expectedHash.toLowerCase() !== actualHash) throw new Error("The backup checksum does not match. Retry the download.")
  saveBlob(new Blob([bytes], { type: "application/json" }), filename)
  return { checksum: actualHash, deferredQuestions }
}
