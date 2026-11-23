/** Lifetime rules for unsaved interview text buffered in localStorage. */

export const DRAFT_KEY_PREFIX = "ic_draft_v1:"

/** Buffered text older than this is dropped instead of offered for recovery. */
export const DRAFT_TTL_MS = 7 * 24 * 60 * 60 * 1000

const EPOCH = "ic_local_draft_epoch"
export const DRAFT_SWEEP_EVENT = "interviewcheck:draft-sweep"

function marker() {
  const nonce = globalThis.crypto?.randomUUID?.() ?? Math.random().toString(36).slice(2).padEnd(36, "0")
  return Date.now() + "-" + nonce
}

export function draftEpoch(storage: Storage, sessionId: string, reserve = false): string | null {
  if (reserve) {
    // Reserve both entries before accepting private text. A later sweep can invalidate
    // them by deletion even when storage has no room for a new marker.
    for (const key of [EPOCH, EPOCH + ":" + sessionId]) {
      if (storage.getItem(key) === null) storage.setItem(key, marker())
    }
  }
  const workspace = storage.getItem(EPOCH)
  const session = storage.getItem(EPOCH + ":" + sessionId)
  return workspace && session ? workspace + "/" + session : null
}

/** Every entry carries the ISO `savedAt` it was written with. */
export function isDraftExpired(savedAt: string): boolean {
  const age = Date.now() - Date.parse(savedAt)
  return !(age >= -DRAFT_TTL_MS && age <= DRAFT_TTL_MS)
}

/** Remove buffered drafts for the given interviews, or for every interview when none are given. */
export function sweepLocalDrafts(sessionIds?: readonly string[]): void {
  if (sessionIds && !sessionIds.length) return
  try {
    const store = window.localStorage
    // A removed marker will never match the nonempty one reserved by a live writer.
    for (const key of sessionIds ? sessionIds.map(id => EPOCH + ":" + id) : [EPOCH]) store.removeItem(key)
    for (const key of Object.keys(store)) {
      if (key.startsWith(DRAFT_KEY_PREFIX) && (!sessionIds || sessionIds.some((id) => key.startsWith(`${DRAFT_KEY_PREFIX}${id}:`)))) {
        store.removeItem(key)
      } else if (key.startsWith(EPOCH + ":")) {
        const stamp = Number(store.getItem(key)?.split("-", 1)[0])
        if (!sessionIds || Date.now() - stamp > DRAFT_TTL_MS) store.removeItem(key)
      }
    }
  } catch { /* no window, or restricted storage */ }
  if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent(DRAFT_SWEEP_EVENT, { detail: sessionIds ?? null }))
}
