import { useEffect } from "react"

const INTERVIEW_PROMPT = "Discard unsaved interview changes and leave this page?"

/** Ask before a pending edit is lost to navigation or a page reload. */
export function useDraftGuard(dirty: boolean, prompt = INTERVIEW_PROMPT, retainsDraft?: (destination: URL) => boolean) {
  useEffect(() => {
    if (!dirty) return
    const confirmLeave = () => window.confirm(prompt)
    const beforeUnload = (event: BeforeUnloadEvent) => {
      event.preventDefault()
      event.returnValue = ""
    }
    function click(event: MouseEvent) {
      if (
        event.defaultPrevented ||
        event.button ||
        event.metaKey ||
        event.ctrlKey ||
        event.shiftKey ||
        event.altKey
      )
        return
      const link = event.target instanceof Element ? event.target.closest<HTMLAnchorElement>("a[href]") : null
      if (!link || link.hasAttribute("download") || link.target === "_blank" || link.href === location.href) return
      if (link.origin !== location.origin) return // Full document departures use the native beforeunload prompt.
      if (retainsDraft?.(new URL(link.href))) return
      if (!confirmLeave()) {
        event.preventDefault()
        event.stopImmediatePropagation()
      }
    }
    function traverse(event: Event) {
      const { navigationType, destination } = event as Event & {
        navigationType: string; destination?: { sameDocument: boolean; url: string }
      }
      if (!event.cancelable || navigationType !== "traverse" || destination?.sameDocument === false) return
      // Only an in-document visit can keep a mounted editor. Reloads retain the native beforeunload guard.
      if (destination?.sameDocument && retainsDraft?.(new URL(destination.url))) return
      if (!confirmLeave()) event.preventDefault()
    }
    const navigation = (window as Window & { navigation?: EventTarget }).navigation
    document.addEventListener("click", click, true)
    navigation?.addEventListener("navigate", traverse)
    window.addEventListener("beforeunload", beforeUnload)
    return () => {
      window.removeEventListener("beforeunload", beforeUnload)
      navigation?.removeEventListener("navigate", traverse)
      document.removeEventListener("click", click, true)
    }
  }, [dirty, prompt, retainsDraft])
}
