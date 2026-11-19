import { useEffect, useRef, type RefObject } from "react"

const FOCUSABLE_SELECTOR =
  'a[href], area[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), summary, [contenteditable]:not([contenteditable="false"]), [tabindex]:not([tabindex="-1"])'

function isVisible(el: HTMLElement, root: HTMLElement): boolean {
  if (el.closest("[inert], [hidden]")) return false
  if (
    typeof el.checkVisibility === "function" &&
    !el.checkVisibility({ checkVisibilityCSS: true, visibilityProperty: true })
  ) {
    return false
  }
  for (let cur: HTMLElement | null = el; cur; cur = cur.parentElement) {
    const cs = window.getComputedStyle(cur)
    if (cs.display === "none" || cs.visibility === "hidden" || cs.visibility === "collapse") return false
    if (cur === root) break
  }
  return true
}

function getFocusable(container: HTMLElement): HTMLElement[] {
  return Array.from(container.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR)).filter(
    (el) => !el.matches(":disabled") && isVisible(el, container),
  )
}

export interface UseDialogFocusTrapOptions {
  open: boolean
  containerRef: RefObject<HTMLElement | null>
  initialFocusRef?: RefObject<HTMLElement | null>
  onClose?: () => void
  disabled?: boolean
}

export function useDialogFocusTrap(options: UseDialogFocusTrapOptions): void {
  const { open, containerRef, initialFocusRef, onClose, disabled = false } = options
  const onCloseRef = useRef(onClose)
  onCloseRef.current = onClose
  const disabledRef = useRef(disabled)
  disabledRef.current = disabled
  const previousFocusRef = useRef<HTMLElement | null>(null)

  useEffect(() => {
    if (!open) return
    const container = containerRef.current
    if (!container) return

    const activeOnOpen = document.activeElement
    previousFocusRef.current = activeOnOpen instanceof HTMLElement ? activeOnOpen : null

    const initial = initialFocusRef?.current
    const focusable = getFocusable(container)
    if (initial && container.contains(initial) && !initial.matches(":disabled") && isVisible(initial, container)) {
      initial.focus()
    } else if (focusable.length > 0) {
      focusable[0].focus()
    } else {
      container.focus()
    }

    function onKeyDown(e: KeyboardEvent) {
      if (e.defaultPrevented) return
      const current = containerRef.current
      if (!current) return

      if (e.key === "Escape") {
        if (!disabledRef.current && onCloseRef.current) {
          e.preventDefault()
          onCloseRef.current()
        }
        return
      }
      if (e.key !== "Tab") return

      const items = getFocusable(current)
      if (items.length === 0) {
        e.preventDefault()
        current.focus()
        return
      }
      const first = items[0]
      const last = items[items.length - 1]
      const active = document.activeElement instanceof HTMLElement ? document.activeElement : null
      if (!active || !current.contains(active)) {
        e.preventDefault()
        ;(e.shiftKey ? last : first).focus()
        return
      }
      if (e.shiftKey && (active === first || active === current)) {
        e.preventDefault()
        last.focus()
      } else if (!e.shiftKey && active === last) {
        e.preventDefault()
        first.focus()
      }
    }

    document.addEventListener("keydown", onKeyDown)
    return () => {
      document.removeEventListener("keydown", onKeyDown)
      const prev = previousFocusRef.current
      previousFocusRef.current = null
      if (prev && prev.isConnected && typeof prev.focus === "function") {
        prev.focus()
      }
    }
  }, [open, containerRef, initialFocusRef])
}
