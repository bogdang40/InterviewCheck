import { api, type Interview } from "./api"
import { useReviewNavigationGuard } from "./dirtyTracking"

/** Revalidate the selection before applying an interview snapshot that can replace the open exchange. */
export function useReviewSelectionRefresh(sessionId: string, locked: boolean, source: string,
  update: (session: Interview) => void, withdraw: () => void) {
  const guard = useReviewNavigationGuard(locked, source)
  return async () => {
    const maySelect = guard()
    const fresh = await api<Interview>(`sessions/${sessionId}`)
    if (fresh?.id !== sessionId) throw new Error("The server did not return this interview.")
    if (!fresh.consent || (fresh.privacy_state && fresh.privacy_state !== "unmarked")) {
      withdraw()
      return
    }
    if (!maySelect()) throw new Error("Finish your current changes, then select the exchange again.")
    update(fresh)
    return fresh
  }
}
