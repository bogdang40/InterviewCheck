"use client"

import { useEffect, useState, type FormEvent } from "react"
import { ChevronDown, ChevronUp, ClipboardCheck, MessageSquarePlus, Trash2 } from "lucide-react"
import { dateLabel, message } from "@/lib/api"
import { useReportDirty, type DirtyReporter } from "@/lib/dirtyTracking"
import {
  createHandoffNote, deleteHandoffNote, fetchSessionScorecard,
  type HandoffNote, type HandoffNoteCategory, type ScorecardState,
} from "@/lib/sessionScorecard"
import { Button } from "./ui/button"
import ScorecardEditor from "./ScorecardEditor"
import { Textarea } from "./ui/textarea"
import styles from "./SessionScorecardPanel.module.css"

const CATEGORY_LABELS: Record<HandoffNoteCategory, string> = {
  observation: "Observation", follow_up: "Follow-up", decision: "Decision", concern: "Concern",
}
const CATEGORY_CLASS: Record<HandoffNoteCategory, string> = {
  observation: "", follow_up: styles.cat_follow_up, decision: styles.cat_decision, concern: styles.cat_concern,
}

export default function SessionScorecardPanel({ sessionId, onDirtyChange }: { sessionId: string; onDirtyChange?: DirtyReporter }) {
  const [expanded, setExpanded] = useState(true)
  const [loading, setLoading] = useState(true)
  const [initial, setInitial] = useState<ScorecardState | null>(null)
  const [scoreDirty, setScoreDirty] = useState(false)
  const [liveWeightedPct, setLiveWeightedPct] = useState<number | null>(null)
  const [loadAttempt, setLoadAttempt] = useState(0)
  const [notes, setNotes] = useState<HandoffNote[]>([])
  const [noteCategory, setNoteCategory] = useState<HandoffNoteCategory>("observation")
  const [noteBody, setNoteBody] = useState("")
  const [savingNote, setSavingNote] = useState(false)
  const [deletingId, setDeletingId] = useState<string | null>(null)
  const [error, setError] = useState("")
  const [status, setStatus] = useState("")

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true); setError(""); setStatus("")
    fetchSessionScorecard(sessionId, controller.signal)
      .then((res) => {
        if (controller.signal.aborted) return
        setInitial(res); setLiveWeightedPct(res.weighted_score_pct); setNotes(res.handoff_notes)
      })
      .catch((err) => { if (!controller.signal.aborted) setError(message(err)) })
      .finally(() => { if (!controller.signal.aborted) setLoading(false) })
    return () => controller.abort()
  }, [sessionId, loadAttempt])

  useReportDirty(scoreDirty || noteBody !== "" || savingNote, onDirtyChange)

  async function handleAddNote(e: FormEvent) {
    e.preventDefault()
    const trimmed = noteBody.trim()
    if (!trimmed || savingNote) return
    setSavingNote(true); setError(""); setStatus("")
    try {
      const created = await createHandoffNote(sessionId, noteCategory, trimmed)
      setNotes((prev) => [created, ...prev]); setNoteBody(""); setStatus("Handoff note added.")
    } catch (err) { setError(message(err)) } finally { setSavingNote(false) }
  }

  async function handleDeleteNote(noteId: string) {
    setDeletingId(noteId); setError(""); setStatus("")
    try {
      await deleteHandoffNote(sessionId, noteId)
      setNotes((prev) => prev.filter((n) => n.id !== noteId)); setStatus("Handoff note removed.")
    } catch (err) { setError(message(err)) } finally { setDeletingId(null) }
  }

  return (
    <section className={styles.panel} aria-label="Session scorecard panel">
      <div className={styles.header}>
        <div className={styles.titleWrap}>
          <ClipboardCheck size={18} aria-hidden="true" />
          <h2>Rubric scorecard &amp; handoff notes</h2>
        </div>
        <div className={styles.headerMeta}>
          <span className={styles.scoreBadge} data-testid="scorecard-weighted-badge">
            {liveWeightedPct !== null ? `Score: ${liveWeightedPct.toFixed(1)}%` : "Score: Ungraded"}
          </span>
          <Button type="button" variant="outline" size="sm" aria-expanded={expanded} onClick={() => setExpanded((v) => !v)}>
            {expanded ? <ChevronUp size={15} aria-hidden="true" /> : <ChevronDown size={15} aria-hidden="true" />}
            {expanded ? "Collapse" : "Expand"}
          </Button>
        </div>
      </div>

      <div hidden={!expanded}>
          {loading ? (
            <p className="muted" role="status">Loading scorecard...</p>
          ) : !initial ? (
            <Button type="button" variant="outline" onClick={() => setLoadAttempt((attempt) => attempt + 1)}>Retry loading scorecard</Button>
          ) : !initial.available ? (
            <p className="muted" role="status">Rubric scorecard endpoints are not enabled on this server.</p>
          ) : (
            <>
              <ScorecardEditor sessionId={sessionId} initial={initial} onDirty={setScoreDirty} onScore={setLiveWeightedPct} />
              <div className={styles.section}>
                <h3>Panel handoff notes</h3>
                <form className="stack" onSubmit={handleAddNote}>
                  <div className={styles.noteFormRow}>
                    <label className="field" style={{ minWidth: "160px" }}>
                      Category
                      <select value={noteCategory} disabled={savingNote} onChange={(e) => setNoteCategory(e.target.value as HandoffNoteCategory)}>
                        <option value="observation">Observation</option>
                        <option value="follow_up">Follow-up</option>
                        <option value="decision">Decision</option>
                        <option value="concern">Concern</option>
                      </select>
                    </label>
                    <label className="field" style={{ flex: "1 1 240px" }}>
                      Handoff note
                      <Textarea
                        rows={2} maxLength={2000} value={noteBody} disabled={savingNote}
                        placeholder="Share handoff context for subsequent interviewers..."
                        onChange={(e) => setNoteBody(e.target.value)}
                      />
                    </label>
                    <Button type="submit" size="sm" disabled={savingNote || !noteBody.trim()}>
                      <MessageSquarePlus size={14} aria-hidden="true" />{savingNote ? "Adding..." : "Add handoff note"}
                    </Button>
                  </div>
                </form>

                {notes.length === 0 ? (
                  <p className="muted">No panel handoff notes recorded yet.</p>
                ) : (
                  <ul className={styles.notesList}>
                    {notes.map((note) => (
                      <li key={note.id} className={styles.noteCard}>
                        <div className={styles.noteHead}>
                          <div className={styles.titleWrap}>
                            <span className={`${styles.catBadge} ${CATEGORY_CLASS[note.category]}`}>{CATEGORY_LABELS[note.category]}</span>
                            <span className={styles.noteMeta}>{note.author_email} &middot; {dateLabel(note.created_at)}</span>
                          </div>
                          <Button
                            type="button" variant="ghost" size="sm"
                            aria-label={`Delete ${CATEGORY_LABELS[note.category].toLowerCase()} note`}
                            disabled={deletingId === note.id} onClick={() => handleDeleteNote(note.id)}
                          >
                            <Trash2 size={14} aria-hidden="true" />Delete
                          </Button>
                        </div>
                        <p className={styles.noteBody}>{note.body}</p>
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            </>
          )}
          {error && <p className="error" role="alert">{error}</p>}
          {status && <p className="notice" role="status">{status}</p>}
      </div>
    </section>
  )
}
