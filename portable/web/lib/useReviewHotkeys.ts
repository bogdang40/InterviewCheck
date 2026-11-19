"use client"

import { useEffect, useLayoutEffect, useRef, useState } from "react"

const useIsomorphicLayoutEffect = typeof window === "undefined" ? useEffect : useLayoutEffect

export type ReviewHotkeyHandlers = {
  enabled?: boolean
  onNext: () => string | null
  onPrev: () => string | null
  onNextPending: () => string | null
  onExplained: () => string | null
  onUnresolved: () => string | null
  onFocusNote: () => string | null
}

function isEditableTarget(target: EventTarget | null): boolean {
  if (!(target instanceof Element)) return false
  if (target instanceof HTMLElement && target.isContentEditable) return true
  return Boolean(
    target.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"])'),
  )
}

function hasBlockingModal(): boolean {
  if (typeof document === "undefined") return false
  return Boolean(
    document.querySelector(
      'dialog[open], [role="dialog"][aria-modal="true"], main#main-content[inert]',
    ),
  )
}

export function useReviewHotkeys(handlers: ReviewHotkeyHandlers) {
  const { enabled = true } = handlers
  const handlersRef = useRef(handlers)
  useIsomorphicLayoutEffect(() => {
    handlersRef.current = handlers
  })
  const [announcement, setAnnouncement] = useState("")

  useIsomorphicLayoutEffect(() => {
    if (!enabled || typeof window === "undefined") return
    if (!window.location.pathname.startsWith("/interviews/review")) return

    function onKeyDown(e: KeyboardEvent) {
      if (e.ctrlKey || e.metaKey || e.altKey || e.defaultPrevented || e.isComposing || e.repeat) {
        return
      }
      if (hasBlockingModal()) return
      if (isEditableTarget(e.target) || isEditableTarget(document.activeElement)) return

      const current = handlersRef.current
      let message: string | null = null
      switch (e.key.toLowerCase()) {
        case "j":
          e.preventDefault()
          message = current.onNext()
          break
        case "k":
          e.preventDefault()
          message = current.onPrev()
          break
        case "n":
          e.preventDefault()
          message = current.onNextPending()
          break
        case "e":
          e.preventDefault()
          message = current.onExplained()
          break
        case "u":
          e.preventDefault()
          message = current.onUnresolved()
          break
        case "f":
          e.preventDefault()
          message = current.onFocusNote()
          break
        default:
          return
      }
      if (message) setAnnouncement(message)
    }

    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [enabled])

  return { announcement, setAnnouncement }
}
