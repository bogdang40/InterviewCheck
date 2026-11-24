import { useCallback, useEffect, useRef } from "react"

function isDocumentFocus(element: EventTarget | null) {
  return !element || element === document.body || element === document.documentElement
}

/** Restore an async action's keyboard landing only while the user has kept that focus intent. */
export function useDeferredFocus<T>() {
  const pending = useRef<{ origin: Element | null; target: T } | null>(null)
  const requestFocus = useCallback((target: T) => {
    pending.current = { origin: document.activeElement, target }
  }, [])
  const cancelFocus = useCallback(() => { pending.current = null }, [])
  const completeFocus = useCallback((destination: (target: T) => HTMLElement | null) => {
    const intent = pending.current
    pending.current = null
    if (intent && (document.activeElement === intent.origin || isDocumentFocus(document.activeElement))) {
      destination(intent.target)?.focus()
    }
  }, [])
  useEffect(() => {
    function moved(event: FocusEvent) {
      if (pending.current && event.target !== pending.current.origin && !isDocumentFocus(event.target)) cancelFocus()
    }
    function edited() { if (pending.current) cancelFocus() }
    document.addEventListener("focusin", moved)
    document.addEventListener("input", edited, true)
    return () => {
      document.removeEventListener("focusin", moved)
      document.removeEventListener("input", edited, true)
      cancelFocus()
    }
  }, [cancelFocus])
  return { requestFocus, completeFocus, cancelFocus }
}
