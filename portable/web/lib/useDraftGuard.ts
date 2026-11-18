import { useEffect } from "react"

/** Ask before a pending interview edit is lost to navigation or a page reload. */
export function useDraftGuard(dirty: boolean) {
  useEffect(() => {
    if (!dirty) return
    const confirmLeave = () => window.confirm("Discard unsaved interview changes and leave this page?")
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
      if (!link || link.download || link.target === "_blank" || link.href === location.href) return
      if (!confirmLeave()) {
        event.preventDefault()
        event.stopImmediatePropagation()
      }
    }
    function traverse(event: Event) {
      if (
        event.cancelable &&
        (event as Event & { navigationType: string }).navigationType === "traverse" &&
        !confirmLeave()
      ) {
        event.preventDefault()
      }
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
  }, [dirty])
}
