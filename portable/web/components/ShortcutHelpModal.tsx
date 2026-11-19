"use client"

import { useEffect, useId, useRef } from "react"
import { Keyboard, X } from "lucide-react"
import { useDialogFocusTrap } from "@/lib/useDialogFocusTrap"

type ShortcutEntry = { keys: string[]; description: string }
type ShortcutGroup = { heading: string; items: ShortcutEntry[] }

const SHORTCUT_GROUPS: readonly ShortcutGroup[] = [
  {
    heading: "Workspace navigation & global",
    items: [
      { keys: ["Ctrl", "K"], description: "Open command palette and workspace search (Cmd+K on macOS)" },
      { keys: ["?"], description: "Open keyboard shortcuts reference" },
      { keys: ["Esc"], description: "Close active dialog or mobile navigation drawer" },
      { keys: ["Tab"], description: "Move focus to next interactive control" },
    ],
  },
  {
    heading: "Command palette",
    items: [
      { keys: ["ArrowUp", "ArrowDown"], description: "Move selection across commands and records" },
      { keys: ["Enter"], description: "Execute selected command or open highlighted record" },
    ],
  },
  {
    heading: "Review workbench & admin console",
    items: [
      { keys: ["j"], description: "Select the next interview exchange" },
      { keys: ["k"], description: "Select the previous interview exchange" },
      { keys: ["n"], description: "Jump to the next pending match" },
      { keys: ["e"], description: "Set review outcome to Explained (click Save review to persist)" },
      { keys: ["u"], description: "Set review outcome to Unresolved (click Save review to persist)" },
      { keys: ["f"], description: "Focus the interviewer note field" },
      { keys: ["ArrowUp", "ArrowDown"], description: "Step between interview questions in the navigator" },
      { keys: ["ArrowLeft", "ArrowRight"], description: "Switch tabs in the Model Admin console" },
      { keys: ["Home", "End"], description: "Jump to the first or last question or admin tab" },
    ],
  },
]

export default function ShortcutHelpModal({
  open,
  onClose,
}: {
  open: boolean
  onClose: () => void
}) {
  const dialogRef = useRef<HTMLDialogElement>(null)
  const closeRef = useRef<HTMLButtonElement>(null)
  const suppressCloseRef = useRef(false)
  const titleId = useId()
  const descId = useId()

  useDialogFocusTrap({
    open,
    containerRef: dialogRef,
    initialFocusRef: closeRef,
    onClose,
  })

  useEffect(() => {
    const el = dialogRef.current
    if (!el) return
    if (open && !el.open) {
      suppressCloseRef.current = false
      el.showModal()
      closeRef.current?.focus()
    } else if (!open && el.open) {
      suppressCloseRef.current = true
      el.close()
    }
    return () => {
      if (el.open) {
        suppressCloseRef.current = true
        el.close()
      }
    }
  }, [open])

  return (
    <dialog
      ref={dialogRef}
      className="shortcut-dialog"
      aria-labelledby={titleId}
      aria-describedby={descId}
      tabIndex={-1}
      onCancel={(e) => {
        e.preventDefault()
        onClose()
      }}
      onClose={() => {
        if (dialogRef.current?.open) return
        if (suppressCloseRef.current) {
          suppressCloseRef.current = false
          return
        }
        if (open) onClose()
      }}
      onClick={(e) => {
        if (e.target !== dialogRef.current) return
        const r = dialogRef.current.getBoundingClientRect()
        if (e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom) {
          onClose()
        }
      }}
    >
      <div className="shortcut-dialog-head">
        <div className="shortcut-dialog-title">
          <Keyboard size={18} aria-hidden="true" />
          <h2 id={titleId}>Keyboard shortcuts</h2>
        </div>
        <button
          ref={closeRef}
          type="button"
          className="shortcut-close"
          aria-label="Close keyboard shortcuts"
          onClick={onClose}
        >
          <X size={18} aria-hidden="true" />
        </button>
      </div>
      <p id={descId} className="shortcut-dialog-lead">
        Press Esc to close this dialog and return focus to your previous control.
      </p>
      <div className="shortcut-groups">
        {SHORTCUT_GROUPS.map((group) => (
          <section key={group.heading} className="shortcut-group" aria-label={group.heading}>
            <h3>{group.heading}</h3>
            <dl className="shortcut-list">
              {group.items.map((item) => (
                <div key={item.description} className="shortcut-row">
                  <dt className="shortcut-keys">
                    {item.keys.map((keyLabel) => (
                      <kbd key={keyLabel}>{keyLabel}</kbd>
                    ))}
                  </dt>
                  <dd>{item.description}</dd>
                </div>
              ))}
            </dl>
          </section>
        ))}
      </div>
    </dialog>
  )
}
