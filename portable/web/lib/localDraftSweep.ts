/** Lifetime rules for unsaved interview text buffered in localStorage. */

export const DRAFT_KEY_PREFIX = "ic_draft_v1:"

/** Buffered text older than this is dropped instead of offered for recovery. */
export const DRAFT_TTL_MS = 7 * 24 * 60 * 60 * 1000

/** Every entry carries the ISO `savedAt` it was written with. */
export function isDraftExpired(savedAt: string): boolean {
  // NaN fails both comparisons, so an undatable entry also counts as expired.
  return !(Date.now() - Date.parse(savedAt) <= DRAFT_TTL_MS)
}

/** Remove buffered drafts for the given interviews, or for every interview when none are given. */
export function sweepLocalDrafts(sessionIds?: readonly string[]): void {
  try {
    const store = window.localStorage
    for (const key of Object.keys(store)) {
      if (key.startsWith(DRAFT_KEY_PREFIX) && (!sessionIds || sessionIds.some((id) => key.startsWith(`${DRAFT_KEY_PREFIX}${id}:`)))) {
        store.removeItem(key)
      }
    }
  } catch { /* no window, or restricted storage */ }
}
