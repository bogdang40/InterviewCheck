"use client"

import Link from "next/link"
import { Search, X, FileText, BriefcaseBusiness, MessageSquareText } from "lucide-react"
import { useEffect, useId, useRef, useState, type KeyboardEvent as ReactKeyEvent } from "react"
import { resultURL, useWorkspaceSearch } from "@/lib/search"

export default function WorkspaceSearch({ compact = false }: { compact?: boolean }) {
  const dialog = useRef<HTMLDialogElement>(null),
    input = useRef<HTMLInputElement>(null)
  const trigger = useRef<HTMLButtonElement>(null)
  const [open, setOpen] = useState(false),
    [query, setQuery] = useState(""),
    [active, setActive] = useState(0)
  const list = useId(),
    title = useId()
  const { result, error, pending } = useWorkspaceSearch(query, open)
  function show() {
    if (!dialog.current || dialog.current.open) return
    setOpen(true)
    setActive(0)
    setQuery("")
    dialog.current.showModal()
    input.current?.focus()
  }
  useEffect(() => {
    function hotkey(e: KeyboardEvent) {
      if (
        (e.metaKey || e.ctrlKey) &&
        !e.altKey &&
        e.key.toLowerCase() === "k" &&
        !e.defaultPrevented &&
        trigger.current?.getClientRects().length
      ) {
        e.preventDefault()
        show()
      }
    }
    document.addEventListener("keydown", hotkey)
    return () => document.removeEventListener("keydown", hotkey)
  }, [])
  function key(e: ReactKeyEvent<HTMLInputElement>) {
    const length = result?.items.length ?? 0
    if (!length) return
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault()
      const next = (active + (e.key === "ArrowDown" ? 1 : -1) + length) % length
      setActive(next)
      document.getElementById(list + next)?.scrollIntoView({ block: "nearest" })
    } else if (e.key === "Enter" && !e.nativeEvent.isComposing) {
      e.preventDefault()
      document.getElementById(list + active)?.click()
    }
  }
  return (
    <>
      <button
        ref={trigger}
        type="button"
        className={compact ? "search-launch compact" : "search-launch"}
        aria-label="Search workspace"
        onClick={show}
      >
        <Search size={16} />
        {!compact && (
          <>
            Search <kbd>Ctrl / ⌘ K</kbd>
          </>
        )}
      </button>
      <dialog
        ref={dialog}
        className="search-dialog"
        aria-labelledby={title}
        onClose={() => {
          if (dialog.current?.open) return
          setOpen(false)
          setQuery("")
          setActive(0)
        }}
        onClick={(e) => {
          if (e.target === dialog.current) {
            const r = dialog.current.getBoundingClientRect()
            if (e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom)
              dialog.current.close()
          }
        }}
      >
        <h2 className="sr-only" id={title}>
          Search workspace
        </h2>
        <div className="search-input-row">
          <Search size={19} />
          <input
            ref={input}
            type="text"
            role="combobox"
            aria-label="Search workspace records"
            aria-autocomplete="list"
            aria-expanded={!!result?.items.length}
            aria-controls={list}
            aria-activedescendant={result?.items[active] ? list + active : undefined}
            placeholder="Search interviews, roles and exchanges"
            autoComplete="off"
            maxLength={160}
            value={query}
            onChange={(e) => {
              setQuery(e.target.value)
              setActive(0)
            }}
            onKeyDown={key}
          />
          <button type="button" aria-label="Close search" onClick={() => dialog.current?.close()}>
            <X size={18} />
          </button>
        </div>
        <div className="search-body" id={list} role="listbox" aria-label="Search results">
          {result?.items.map((r, i) => {
            const Icon =
              r.kind === "role" ? BriefcaseBusiness : r.kind === "session" ? FileText : MessageSquareText
            return (
              <Link
                id={list + i}
                key={r.kind + r.id}
                role="option"
                aria-selected={i === active}
                tabIndex={-1}
                prefetch={false}
                href={resultURL(r)}
                className="search-hit"
                onMouseMove={() => setActive(i)}
                onClick={() => dialog.current?.close()}
              >
                <Icon size={17} />
                <span>
                  <b>{r.label}</b>
                  <small>{r.snippet}</small>
                </span>
                <em>{r.kind === "session" ? "Interview" : r.kind === "answer" ? "Exchange" : "Role"}</em>
              </Link>
            )
          })}
        </div>
        <p className="search-footer" role="status">
          {error ||
            (query.trim().length < 2
              ? "Enter at least two characters."
              : pending
                ? "Searching…"
                : !result?.items.length
                  ? "No matching records."
                  : result.has_more
                    ? "First 20 results. Refine your search to see more."
                    : `${result.items.length} results. Use the arrow keys and Enter to open a record.`)}
        </p>
      </dialog>
    </>
  )
}
