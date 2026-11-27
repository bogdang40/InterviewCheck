import type { Interview } from "./api"
import { useReviewNavigationGuard } from "./dirtyTracking"
import { isInterviewUnavailable, request } from "./http"

/** Revalidate the selection before applying an interview snapshot that can replace the open exchange. */
export function useReviewSelectionRefresh(sessionId: string, locked: boolean, source: string,
  update: (session: Interview) => void, withdraw: () => void) {
  const captureSelection = useReviewNavigationGuard(locked, source)
  async function refreshForSelection(maySelect: () => boolean) {
    let fresh: Interview
    try {
      fresh = await request<Interview>(`/api/sessions/${sessionId}`)
    } catch (err) {
      if (!isInterviewUnavailable(err)) throw err
      withdraw()
      return
    }
    if (fresh?.id !== sessionId || typeof fresh.consent !== "boolean" || !Array.isArray(fresh.answers)) {
      throw new Error("The server did not return this interview.")
    }
    if (!fresh.consent || (fresh.privacy_state && fresh.privacy_state !== "unmarked")) {
      withdraw()
      return
    }
    if (!maySelect()) throw new Error("Finish your current changes, then select the exchange again.")
    update(fresh)
    return fresh
  }
  return { captureSelection, refreshForSelection }
}
