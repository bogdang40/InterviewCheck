import { DRAFT_SWEEP_EVENT } from "./localDraftSweep"
import { ACCOUNT_EVENT } from "./useAccountStatus"

/** Discard private worksheet state when this tab or another tab clears the workspace. */
export function watchWorksheetAccess(sessionId: string, clear: () => void) {
  function sweep(event: Event) {
    const ids: unknown = event instanceof CustomEvent ? event.detail : null
    if (!Array.isArray(ids) || ids.includes(sessionId)) clear()
  }
  function storage(event: StorageEvent) {
    if (event.key === null || (!event.newValue && (event.key === "ic_local_draft_epoch"
      || event.key === `ic_local_draft_epoch:${sessionId}`))) clear()
  }
  window.addEventListener(ACCOUNT_EVENT, clear)
  window.addEventListener(DRAFT_SWEEP_EVENT, sweep)
  window.addEventListener("storage", storage)
  return () => {
    window.removeEventListener(ACCOUNT_EVENT, clear)
    window.removeEventListener(DRAFT_SWEEP_EVENT, sweep)
    window.removeEventListener("storage", storage)
  }
}
