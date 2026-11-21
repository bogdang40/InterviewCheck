"use client"

import Link from "next/link"
import { BriefcaseBusiness, FileText, Laptop, MessageSquareText, Moon, Search, Sun, X } from "lucide-react"
import { lazy, Suspense, useEffect, useId, useRef, useState, type KeyboardEvent as ReactKeyEvent } from "react"
import type * as CommandPaletteModule from "@/lib/commandPalette"
import { resultURL, useWorkspaceSearch } from "@/lib/search"
import { useAccountStatus } from "@/lib/useAccountStatus"

const ShortcutHelpModal = lazy(() => import("./ShortcutHelpModal"))

const isEditable = (target: EventTarget | null) =>
  target instanceof HTMLElement &&
  (target.isContentEditable ||
    Boolean(target.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"])')))

const hasModalOpen = () =>
  typeof document !== "undefined" && Boolean(document.querySelector('dialog[open], [role="dialog"][aria-modal="true"]'))

const commandIcon = (cmd: CommandPaletteModule.PaletteCommand) =>
  cmd.theme === "light" ? Sun : cmd.theme === "dark" ? Moon : cmd.theme === "system" ? Laptop : cmd.kind === "help" ? MessageSquareText : FileText

export default function WorkspaceSearch({
  compact = false,
  isAdmin: isAdminProp,
}: {
  compact?: boolean
  isAdmin?: boolean
}) {
  const dialog = useRef<HTMLDialogElement>(null),
    input = useRef<HTMLInputElement>(null),
    trigger = useRef<HTMLButtonElement>(null)
  const previousFocusRef = useRef<HTMLElement | null>(null)
  const navigatingRef = useRef(false)
  const openCycleRef = useRef(false)
  const [open, setOpen] = useState(false),
    [shortcutOpen, setShortcutOpen] = useState(false),
    [paletteMod, setPaletteMod] = useState<typeof CommandPaletteModule | null>(null),
    [query, setQuery] = useState(""),
    [active, setActive] = useState(0)
  const shortcutOpenRef = useRef(false)
  shortcutOpenRef.current = shortcutOpen
  const list = useId(),
    title = useId()
  const { isAdmin: fallbackIsAdmin } = useAccountStatus(undefined, isAdminProp === undefined)
  const isAdmin = isAdminProp ?? fallbackIsAdmin
  const { result, error, pending } = useWorkspaceSearch(query, open)
  const commands = open && paletteMod ? paletteMod.filterPaletteCommands(query, isAdmin) : []
  const records = result?.items ?? []
  const totalCount = commands.length + records.length
  const activeIndex = totalCount > 0 ? Math.min(active, totalCount - 1) : 0

  function loadPalette() {
    if (!paletteMod) void import("@/lib/commandPalette").then(setPaletteMod)
  }

  function show() {
    if (!dialog.current || dialog.current.open) return
    loadPalette()
    const activeElement = document.activeElement
    previousFocusRef.current =
      activeElement instanceof HTMLElement &&
      activeElement !== document.body &&
      activeElement !== document.documentElement
        ? activeElement
        : null
    navigatingRef.current = false
    openCycleRef.current = true
    setOpen(true)
    setActive(0)
    setQuery("")
    dialog.current.showModal()
    input.current?.focus()
  }

  function openShortcutHelp() {
    navigatingRef.current = true
    dialog.current?.close()
    trigger.current?.focus()
    setShortcutOpen(true)
  }

  function runCommand(cmd: CommandPaletteModule.PaletteCommand) {
    if (cmd.theme && paletteMod) {
      paletteMod.applyThemePreference(cmd.theme)
      dialog.current?.close()
      return
    }
    if (cmd.kind === "help") openShortcutHelp()
  }

  useEffect(() => {
    function hotkey(e: KeyboardEvent) {
      if (
        (e.metaKey || e.ctrlKey) &&
        !e.altKey &&
        e.key.toLowerCase() === "k" &&
        !e.defaultPrevented &&
        !shortcutOpenRef.current &&
        !hasModalOpen() &&
        trigger.current?.getClientRects().length
      ) {
        e.preventDefault()
        show()
        return
      }
      if (
        e.key === "?" &&
        !e.metaKey &&
        !e.ctrlKey &&
        !e.altKey &&
        !e.defaultPrevented &&
        !e.isComposing &&
        !shortcutOpenRef.current &&
        !dialog.current?.open &&
        !hasModalOpen() &&
        !isEditable(e.target) &&
        !isEditable(document.activeElement) &&
        trigger.current?.getClientRects().length
      ) {
        e.preventDefault()
        setShortcutOpen(true)
      }
    }
    document.addEventListener("keydown", hotkey)
    return () => document.removeEventListener("keydown", hotkey)
  }, [])

  function key(e: ReactKeyEvent<HTMLInputElement>) {
    if (!totalCount) return
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault()
      const next = (activeIndex + (e.key === "ArrowDown" ? 1 : -1) + totalCount) % totalCount
      setActive(next)
      document.getElementById(list + next)?.scrollIntoView({ block: "nearest" })
    } else if (e.key === "Enter" && !e.nativeEvent.isComposing) {
      e.preventDefault()
      document.getElementById(list + activeIndex)?.click()
    }
  }

  const footerText =
    error ||
    (pending
      ? "Searching records..."
      : query.trim().length < 2
        ? commands.length
          ? `${commands.length} ${commands.length === 1 ? "command" : "commands"}. Type 2+ characters to search records.`
          : "Type 2+ characters to search records."
        : !totalCount
          ? "No matching commands or records."
          : result?.has_more
            ? "Showing commands and first 20 records. Refine your search."
            : `${totalCount} ${totalCount === 1 ? "result" : "results"}. Use arrow keys and Enter.`)

  return (
    <>
      <button
        ref={trigger}
        type="button"
        className={compact ? "search-launch compact" : "search-launch"}
        aria-label="Search workspace"
        aria-keyshortcuts="Meta+k Control+k"
        onMouseEnter={loadPalette}
        onFocus={loadPalette}
        onClick={show}
      >
        <Search size={16} aria-hidden="true" />
        {!compact && <span className="search-label">Search <kbd>Ctrl / ⌘ K</kbd></span>}
      </button>
      <dialog
        ref={dialog}
        className="search-dialog"
        aria-labelledby={title}
        onClose={() => {
          if (dialog.current?.open || !openCycleRef.current) return
          openCycleRef.current = false
          setOpen(false)
          setQuery("")
          setActive(0)
          const shouldRestore = !navigatingRef.current
          const restoreTarget = previousFocusRef.current
          navigatingRef.current = false
          previousFocusRef.current = null
          if (shouldRestore) {
            if (restoreTarget?.isConnected) restoreTarget.focus()
            if ((!restoreTarget || document.activeElement !== restoreTarget) && trigger.current?.isConnected) {
              trigger.current.focus()
            }
          }
        }}
        onClick={(e) => {
          if (e.target === dialog.current) {
            const r = dialog.current.getBoundingClientRect()
            if (e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom)
              dialog.current.close()
          }
        }}
      >
        <h2 className="sr-only" id={title}>Search workspace</h2>
        <div className="search-input-row">
          <Search size={19} aria-hidden="true" />
          <input
            ref={input}
            type="text"
            role="combobox"
            aria-label="Search workspace records"
            aria-autocomplete="list"
            aria-expanded={totalCount > 0}
            aria-controls={list}
            aria-activedescendant={totalCount > 0 ? list + activeIndex : undefined}
            placeholder="Search interviews, roles, or run a command"
            autoComplete="off"
            maxLength={160}
            value={query}
            onChange={(e) => { setQuery(e.target.value); setActive(0) }}
            onKeyDown={key}
          />
          <button type="button" aria-label="Close search" onClick={() => dialog.current?.close()}>
            <X size={18} aria-hidden="true" />
          </button>
        </div>
        <div className="search-body" id={list} role="listbox" aria-label="Search results">
          {commands.length > 0 && <div className="search-section-label" role="presentation">Commands</div>}
          {commands.map((cmd, i) => {
            const Icon = commandIcon(cmd)
            const badge = cmd.shortcut ? <kbd>{cmd.shortcut}</kbd> : cmd.kind === "theme" ? "Theme" : "Navigate"
            const body = (<><Icon size={17} aria-hidden="true" /><span><b>{cmd.label}</b><small>{cmd.description}</small></span><em>{badge}</em></>)
            return cmd.href ? (
              <Link id={list + i} key={cmd.id} role="option" aria-selected={i === activeIndex} tabIndex={-1} prefetch={false} href={cmd.href} className="search-hit" onMouseMove={() => setActive(i)} onClick={() => { navigatingRef.current = true; dialog.current?.close() }}>
                {body}
              </Link>
            ) : (
              <button type="button" id={list + i} key={cmd.id} role="option" aria-selected={i === activeIndex} tabIndex={-1} className="search-hit search-hit-action" onMouseMove={() => setActive(i)} onClick={() => runCommand(cmd)}>
                {body}
              </button>
            )
          })}
          {records.length > 0 && <div className="search-section-label" role="presentation">Workspace records</div>}
          {records.map((r, offset) => {
            const index = commands.length + offset
            const Icon = r.kind === "role" ? BriefcaseBusiness : r.kind === "session" ? FileText : MessageSquareText
            return (
              <Link id={list + index} key={r.kind + r.id} role="option" aria-selected={index === activeIndex} tabIndex={-1} prefetch={false} href={resultURL(r)} className="search-hit" onMouseMove={() => setActive(index)} onClick={() => { navigatingRef.current = true; dialog.current?.close() }}>
                <Icon size={17} aria-hidden="true" />
                <span><b>{r.label}</b><small>{r.snippet}</small></span>
                <em>{r.kind === "session" ? "Interview" : r.kind === "answer" ? "Exchange" : "Role"}</em>
              </Link>
            )
          })}
        </div>
        <div className="search-footer-row">
          <p className="search-footer" role="status">{footerText}</p>
          <button type="button" className="search-shortcuts-btn" onClick={openShortcutHelp}>
            Shortcuts <kbd>?</kbd>
          </button>
        </div>
      </dialog>
      <Suspense fallback={null}>
        {shortcutOpen && <ShortcutHelpModal open={shortcutOpen} onClose={() => setShortcutOpen(false)} />}
      </Suspense>
    </>
  )
}
