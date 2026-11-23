"use client"

import { useEffect, useState, type FormEvent } from "react"
import { ChevronDown, ChevronUp, ClipboardCheck, MessageSquarePlus, Plus, Trash2 } from "lucide-react"
import { dateLabel, message } from "@/lib/api"
import { useReportDirty, type DirtyReporter } from "@/lib/dirtyTracking"
import {
  computeWeightedScorePct, createHandoffNote, deleteHandoffNote, fetchSessionScorecard, saveSessionScorecard,
  type HandoffNote, type HandoffNoteCategory, type ScorecardItem,
} from "@/lib/sessionScorecard"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import { Textarea } from "./ui/textarea"
import styles from "./SessionScorecardPanel.module.css"

const CATEGORY_LABELS: Record<HandoffNoteCategory, string> = {
  observation: "Observation", follow_up: "Follow-up", decision: "Decision", concern: "Concern",
}
const CATEGORY_CLASS: Record<HandoffNoteCategory, string> = {
  observation: "", follow_up: styles.cat_follow_up, decision: styles.cat_decision, concern: styles.cat_concern,
}

function mergeSavedItems(prev: ScorecardItem[], saved: ScorecardItem[]): ScorecardItem[] {
  const byId = new Map(saved.map((row) => [row.criterion_id, row]))
  const merged = prev.map((row) => byId.get(row.criterion_id) ?? row)
  for (const row of saved) { if (!merged.some((m) => m.criterion_id === row.criterion_id)) merged.push(row) }
  return merged
}

export default function SessionScorecardPanel({ sessionId, onDirtyChange }: { sessionId: string; onDirtyChange?: DirtyReporter }) {
  const [expanded, setExpanded] = useState(true)
  const [loading, setLoading] = useState(true)
  const [available, setAvailable] = useState(true)
  const [items, setItems] = useState<ScorecardItem[]>([])
  const [savedItemsKey, setSavedItemsKey] = useState("[]")
  const [serverWeightedPct, setServerWeightedPct] = useState<number | null>(null)
  const [notes, setNotes] = useState<HandoffNote[]>([])
  const [newCriterion, setNewCriterion] = useState("")
  const [newWeight, setNewWeight] = useState("1")
  const [noteCategory, setNoteCategory] = useState<HandoffNoteCategory>("observation")
  const [noteBody, setNoteBody] = useState("")
  const [savingScorecard, setSavingScorecard] = useState(false)
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
        setAvailable(res.available); setItems(res.items); setSavedItemsKey(JSON.stringify(res.items))
        setServerWeightedPct(res.weighted_score_pct); setNotes(res.handoff_notes)
      })
      .catch((err) => { if (!controller.signal.aborted) setError(message(err)) })
      .finally(() => { if (!controller.signal.aborted) setLoading(false) })
    return () => controller.abort()
  }, [sessionId])

  const liveWeightedPct = computeWeightedScorePct(items) ?? serverWeightedPct
  const dirty = !loading && (JSON.stringify(items) !== savedItemsKey || noteBody.trim() !== "")
  useReportDirty(dirty, onDirtyChange)

  function updateItem(criterionId: string, patch: Partial<ScorecardItem>) {
    setStatus(""); setError("")
    setItems((prev) => prev.map((it) => (it.criterion_id === criterionId ? { ...it, ...patch } : it)))
  }

  function handleAddCriterion() {
    const label = newCriterion.trim().slice(0, 200)
    if (!label || items.length >= 25) return
    const weight = Math.min(100, Math.max(1, Math.round(Number(newWeight) || 1)))
    const slug = label.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "criterion"
    setItems((prev) => {
      if (prev.length >= 25) return prev
      const existing = new Set(prev.map((it) => it.criterion_id))
      const stamp = Date.now().toString(36)
      let criterionId = ""
      let attempt = 0
      do {
        const rand = typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
          ? crypto.randomUUID().slice(0, 8)
          : Math.random().toString(36).slice(2, 10)
        criterionId = attempt === 0 ? `${slug}-${stamp}-${rand}` : `${slug}-${stamp}-${rand}-${attempt}`
        attempt += 1
      } while (existing.has(criterionId))
      return [
        ...prev,
        { criterion_id: criterionId, criterion_label: label, weight, rating: null, rationale: "" },
      ]
    })
    setNewCriterion(""); setNewWeight("1"); setError(""); setStatus("")
  }

  async function handleSaveScorecard() {
    const rated = items.filter((it) => it.rating !== null && it.rating >= 1 && it.rating <= 5)
    if (!rated.length) { setError("Select a 1 to 5 rating for at least one criterion before saving."); return }
    setSavingScorecard(true); setError(""); setStatus("")
    try {
      const payload = rated.map((it) => ({
        criterion_id: it.criterion_id, criterion_label: it.criterion_label,
        weight: Math.min(100, Math.max(1, Math.round(it.weight || 1))), rating: it.rating as number, rationale: it.rationale,
      }))
      const saved = await saveSessionScorecard(sessionId, payload)
      // Edits made while the request was in flight stay unsaved, so compare against what was sent.
      setSavedItemsKey(JSON.stringify(mergeSavedItems(items, saved.items)))
      setItems((prev) => mergeSavedItems(prev, saved.items))
      setServerWeightedPct(saved.weighted_score_pct); setStatus("Scorecard saved.")
    } catch (err) { setError(message(err)) } finally { setSavingScorecard(false) }
  }

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

      {expanded && (
        <>
          {loading ? (
            <p className="muted" role="status">Loading scorecard...</p>
          ) : !available ? (
            <p className="muted" role="status">Rubric scorecard endpoints are not enabled on this server.</p>
          ) : (
            <>
              <div className={styles.section}>
                {items.length === 0 ? (
                  <p className="muted">No rubric criteria configured for this role yet. Add a criterion below to grade this session.</p>
                ) : (
                  <ul className={styles.criteriaList}>
                    {items.map((item) => (
                      <li key={item.criterion_id} className={styles.criterionCard}>
                        <div className={styles.criterionTop}>
                          <div><strong>{item.criterion_label}</strong> <span className={styles.weightLabel}>Weight {item.weight}</span></div>
                          <div className={styles.ratingGroup} role="group" aria-label={`Rating for ${item.criterion_label}`}>
                            {[1, 2, 3, 4, 5].map((score) => (
                              <button
                                key={score} type="button" className={styles.ratingBtn} aria-pressed={item.rating === score}
                                aria-label={`Rate ${item.criterion_label} ${score} of 5`} disabled={savingScorecard}
                                onClick={() => updateItem(item.criterion_id, { rating: score })}
                              >{score}</button>
                            ))}
                          </div>
                        </div>
                        <label className="field">
                          Rationale for {item.criterion_label}
                          <Input
                            value={item.rationale} maxLength={2000} disabled={savingScorecard}
                            placeholder="Document observed signals or gaps..."
                            onChange={(e) => updateItem(item.criterion_id, { rationale: e.target.value })}
                          />
                        </label>
                      </li>
                    ))}
                  </ul>
                )}

                {items.length < 25 && (
                  <div className={styles.addCriterionRow}>
                    <label className="field" style={{ flex: "1 1 200px" }}>
                      Add criterion
                      <Input
                        value={newCriterion} maxLength={200} disabled={savingScorecard}
                        placeholder="e.g. System design depth" onChange={(e) => setNewCriterion(e.target.value)}
                      />
                    </label>
                    <label className="field" style={{ flex: "0 1 96px" }}>
                      Weight
                      <Input
                        type="number" min={1} max={100} value={newWeight} disabled={savingScorecard}
                        onChange={(e) => setNewWeight(e.target.value)}
                      />
                    </label>
                    <Button type="button" variant="outline" size="sm" disabled={savingScorecard || !newCriterion.trim()} onClick={handleAddCriterion}>
                      <Plus size={14} aria-hidden="true" />Add criterion
                    </Button>
                  </div>
                )}

                <div>
                  <Button type="button" size="sm" disabled={savingScorecard || items.length === 0} onClick={handleSaveScorecard}>
                    {savingScorecard ? "Saving scorecard..." : "Save scorecard"}
                  </Button>
                </div>
              </div>

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
        </>
      )}
    </section>
  )
}
