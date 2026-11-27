import { type FormEvent, useEffect, useId, useRef, useState } from "react"
import { MessageSquarePlus, Trash2 } from "lucide-react"
import { message } from "@/lib/api"
import { useReportDirty, type DirtyReporter } from "@/lib/dirtyTracking"
import { useDeferredFocus } from "@/lib/useDeferredFocus"
import { isAccessDenied } from "@/lib/http"
import {
  createHandoffNote, deleteHandoffNote, fetchHandoffPage, fetchSessionScorecard, HANDOFF_PAGE_SIZE,
  ScorecardApiError, type HandoffNote, type HandoffNoteCategory, type HandoffPage, type ScorecardState,
} from "@/lib/sessionScorecard"
import { Button } from "./ui/button"
import { Textarea } from "./ui/textarea"
import styles from "./SessionScorecardPanel.module.css"

const categories = { observation: "Observation", follow_up: "Follow-up", decision: "Decision", concern: "Concern" } as const
const noteTime = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" })
function NoteTime({ value }: { value: string }) {
  const stamp = Date.parse(value)
  return Number.isFinite(stamp) ? <time dateTime={value}>{noteTime.format(stamp)}</time> : <span>Time unavailable</span>
}
const options = Object.entries(categories).map(([key, label]) => <option key={key} value={key}>{label}</option>)
type View = { category: HandoffNoteCategory | ""; cursors: string[]; afterDelete?: "nearest" | "newest" }
type Reply = { view: View; data?: HandoffPage; error?: string }

function legacyPage(notes: HandoffNote[], view: View): HandoffPage {
  const filtered = view.category ? notes.filter(note => note.category === view.category) : notes
  const offset = (view.cursors.length - 1) * HANDOFF_PAGE_SIZE
  return { items: filtered.slice(offset, offset + HANDOFF_PAGE_SIZE), total: filtered.length,
    next_cursor: offset + HANDOFF_PAGE_SIZE < filtered.length ? String(offset + HANDOFF_PAGE_SIZE) : null }
}

function newestFirst(a: HandoffNote, b: HandoffNote) {
  if (a.created_at !== b.created_at) return a.created_at < b.created_at ? 1 : -1
  if (a.id === b.id) return 0
  return a.id < b.id ? 1 : -1
}

function accessError(err: unknown) {
  if (!(err instanceof ScorecardApiError)) return ""
  if (isAccessDenied(err)) {
    if (err.status === 401) return "Sign in to view handoff notes."
    return "You no longer have access to these handoff notes."
  }
  return err.status === 404 ? "This interview or handoff note is unavailable. Check whether the interview is in Trash." : ""
}

export default function PanelHandoffNotes({ sessionId, initial, visible, onDirty, readOnly = false }: {
  readOnly?: boolean; sessionId: string; initial: ScorecardState; visible: boolean; onDirty: DirtyReporter
}) {
  const legacy = useRef(!initial.handoff_notes_paged)
  const cached = useRef<HandoffNote[] | null>(legacy.current ? initial.handoff_notes : null)
  const [view, setView] = useState<View>({ category: "", cursors: [""] })
  const [reply, setReply] = useState<Reply | null>(null)
  const [category, setCategory] = useState<HandoffNoteCategory>("observation")
  const [body, setBody] = useState("")
  const [busy, setBusy] = useState(false)
  const [writeError, setWriteError] = useState("")
  const [denied, setDenied] = useState("")
  const [withholdDraft, setWithholdDraft] = useState(false)
  const [status, setStatus] = useState("")
  const statusRef = useRef<HTMLParagraphElement>(null)
  const writeAlert = useRef<HTMLParagraphElement>(null)
  const retry = useRef<HTMLButtonElement>(null)
  const composer = useRef<HTMLTextAreaElement>(null)
  const { requestFocus, completeFocus, cancelFocus } = useDeferredFocus<string>()
  const prefix = useId()
  const current = !denied && reply?.view === view ? reply : null
  const data = current?.data
  const readError = denied || current?.error
  useReportDirty(body !== "" || busy, onDirty)

  useEffect(() => {
    if (!visible || denied) { setReply(null); return }
    const controller = new AbortController()
    async function load() {
      // A missing note or loss of access invalidates the legacy list.
      if (legacy.current && cached.current === null) {
        const fresh = await fetchSessionScorecard(sessionId, controller.signal)
        if (controller.signal.aborted) return
        if (!fresh.available) throw new ScorecardApiError(404, "Interview unavailable.")
        legacy.current = !fresh.handoff_notes_paged
        cached.current = legacy.current ? fresh.handoff_notes : null
      }
      const page = legacy.current && cached.current !== null ? legacyPage(cached.current, view)
        : await fetchHandoffPage(sessionId, view.category, view.cursors[view.cursors.length - 1], controller.signal)
      if (controller.signal.aborted) return
      if (page.next_cursor && view.cursors.includes(page.next_cursor)) throw new Error("The server returned a repeated handoff note page.")
      if (view.afterDelete && !page.items.length && view.cursors.length > 1) {
        // Try the nearest newer page once. If that page also vanished, return to the newest notes.
        const cursors = page.total && view.afterDelete === "nearest" ? view.cursors.slice(0, -1) : [""]
        setView({ category: view.category, cursors, afterDelete: "newest" })
      } else {
        setWithholdDraft(false)
        setReply({ view, data: page })
      }
    }
    load().catch(err => {
      if (controller.signal.aborted) return
      const blocked = accessError(err)
      if (blocked) { cached.current = null; setWithholdDraft(true); setDenied(blocked) }
      else setReply({ view, error: message(err) })
    })
    return () => controller.abort()
  }, [sessionId, visible, view, denied])

  useEffect(() => {
    if (!visible) cancelFocus()
    else if (busy) return
    else if (readError) completeFocus(() => retry.current)
    else if (writeError) completeFocus(() => writeAlert.current)
    else if (data) completeFocus(target => target === "composer" ? composer.current :
      document.getElementById(prefix + target) ?? statusRef.current)
  }, [data, prefix, visible, busy, readError, writeError, cancelFocus, completeFocus])

  function navigate(next: View) {
    requestFocus("status")
    setView(next)
    setWriteError("")
    setStatus("")
  }
  function failed(err: unknown) {
    const blocked = accessError(err)
    if (blocked) { cached.current = null; setWithholdDraft(true); setDenied(blocked) }
    else setWriteError(message(err))
  }
  async function add(event: FormEvent) {
    event.preventDefault()
    if (!data || busy || !body.trim()) return
    requestFocus("composer")
    setBusy(true); setWriteError(""); setStatus("")
    try {
      const added = await createHandoffNote(sessionId, category, body.trim())
      if (cached.current) cached.current = [added, ...cached.current].sort(newestFirst)
      const switched = Boolean(view.category && view.category !== category)
      setBody("")
      setStatus(switched ? `Handoff note added. Showing ${categories[category].toLowerCase()} notes.` : "Handoff note added.")
      setView({ category: switched ? category : view.category, cursors: [""] })
    } catch (err) { failed(err) } finally { setBusy(false) }
  }
  async function remove(note: HandoffNote, index: number) {
    if (!data || busy) return
    requestFocus(data.items[index + 1]?.id ?? data.items[index - 1]?.id ?? "status")
    setBusy(true); setWriteError(""); setStatus("")
    try {
      await deleteHandoffNote(sessionId, note.id)
      if (cached.current) cached.current = cached.current.filter(entry => entry.id !== note.id)
      setStatus("Handoff note removed.")
      setView({ ...view, afterDelete: "nearest" })
    } catch (err) {
      if (err instanceof ScorecardApiError && err.status === 404) {
        cached.current = null
        setStatus("The selected handoff note is unavailable.")
        setView({ ...view, afterDelete: "nearest" })
      } else failed(err)
    } finally { setBusy(false) }
  }

  return <section className={styles.section} aria-label="Panel handoff notes">
    <h3>Panel handoff notes</h3>
    {!readOnly && !withholdDraft && <form className="stack" onSubmit={add}>
      <div className={styles.noteFormRow}>
        <label className={`field ${styles.composeCategory}`}>Category
          <select aria-label="Category" value={category} disabled={busy || !!denied}
            onChange={e => setCategory(e.target.value as HandoffNoteCategory)}>{options}</select>
        </label>
        <label className={`field ${styles.composeBody}`}>Handoff note
          <Textarea ref={composer} aria-label="Handoff note" rows={2} maxLength={2000} value={body} disabled={busy || !!denied}
            onChange={e => setBody(e.target.value)} placeholder="Share context for the next interviewer..." />
        </label>
        <Button type="submit" size="sm" disabled={busy || !data || !body.trim()}>
          <MessageSquarePlus size={14} aria-hidden="true" />Add handoff note
        </Button>
      </div>
    </form>}
    <label className="field">Show handoff notes
      <select aria-label="Show handoff notes" value={view.category} disabled={busy || !!denied}
        onChange={e => navigate({ category: e.target.value as View["category"], cursors: [""] })}>
        <option value="">All notes</option>{options}
      </select>
    </label>
    {readError ? <div className="stack"><p role="alert" className="error">{readError}</p>
      <Button ref={retry} type="button" size="sm" variant="outline" onClick={() => { setDenied(""); navigate({ ...view }) }}>Reload handoff notes</Button>
    </div> : !data ? <p role="status" className="muted">Loading handoff notes...</p> : <>
      <p ref={statusRef} tabIndex={-1} role="status" className="muted">
        {data.total === 0 ? (view.category ? "No handoff notes in this category." : "No panel handoff notes recorded yet.")
          : `Page ${view.cursors.length}. Showing ${data.items.length} of ${data.total} ${data.total === 1 ? "note" : "notes"}.`}
      </p>
      <ul className={styles.notesList}>{data.items.map((note, index) => <li key={note.id} className={styles.noteCard}>
        <div className={styles.noteHead}><div className={styles.titleWrap}>
          <span className={`${styles.catBadge} ${styles["cat_" + note.category] ?? ""}`}>{categories[note.category]}</span>
          <span className={styles.noteMeta}>{note.author_email} &middot; <NoteTime value={note.created_at} /></span>
        </div>
          <Button id={prefix + note.id} type="button" variant="ghost" size="sm" disabled={busy}
            aria-label={`Delete ${categories[note.category].toLowerCase()} note`} aria-describedby={prefix + "-body-" + note.id}
            onClick={() => void remove(note, index)}>
            <Trash2 size={14} aria-hidden="true" />Delete</Button>
        </div>
        <p id={prefix + "-body-" + note.id} className={styles.noteBody}>{note.body || "No note text retained."}</p>
      </li>)}</ul>
    </>}
    {(!denied && (view.cursors.length > 1 || data?.next_cursor)) && <nav className="row" aria-label="Handoff note pages">
      <Button type="button" variant="outline" size="sm" disabled={busy || view.cursors.length <= 1}
        onClick={() => navigate({ category: view.category, cursors: view.cursors.slice(0, -1) })}>Newer notes</Button>
      <Button type="button" variant="outline" size="sm" disabled={busy || !data?.next_cursor}
        onClick={() => { if (data?.next_cursor) navigate({ category: view.category, cursors: [...view.cursors, data.next_cursor] }) }}>Older notes</Button>
    </nav>}
    {writeError && <p ref={writeAlert} tabIndex={-1} className="error" role="alert" aria-label="Handoff note change failed">{writeError}</p>}
    {status && <p className="notice" role="status">{status}</p>}
  </section>
}
