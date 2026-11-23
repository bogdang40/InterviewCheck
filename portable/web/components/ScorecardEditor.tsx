import { useEffect, useId, useMemo, useState } from "react"
import { Plus } from "lucide-react"
import { message } from "@/lib/api"
import { useReportDirty, type DirtyReporter } from "@/lib/dirtyTracking"
import { reconcileScores, sameScores, undoScoreRemoval, type ScoreConflict } from "@/lib/scorecardDraft"
import {
  computeWeightedScorePct, fetchSessionScorecard, saveSessionScorecard, ScorecardVersionConflict,
  type ScorecardItem, type ScorecardState,
} from "@/lib/sessionScorecard"
import ScorecardCriteria from "./ScorecardCriteria"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import styles from "./SessionScorecardPanel.module.css"

export type ScorePreview = { pct: number | null; unsaved: boolean }

export default function ScorecardEditor({ sessionId, initial, onDirty, onScore }: {
  sessionId: string; initial: ScorecardState; onDirty: DirtyReporter; onScore: (score: ScorePreview) => void
}) {
  const prefix = useId()
  const [baseline, setBaseline] = useState<Pick<ScorecardState, "items" | "version">>(initial)
  const [rows, setRows] = useState(initial.items)
  const [removals, setRemovals] = useState(() => new Map<string, ScorecardItem>())
  const [conflicts, setConflicts] = useState<ScoreConflict[]>([])
  const [needsRefresh, setNeedsRefresh] = useState(!initial.version)
  const [name, setName] = useState("")
  const [weight, setWeight] = useState("1")
  const [busy, setBusy] = useState(false)
  const [attempted, setAttempted] = useState(false)
  const [error, setError] = useState("")
  const [status, setStatus] = useState("")
  const [focusId, setFocusId] = useState("")
  const existing = new Set(baseline.items.map((row) => row.criterion_id))
  const savedRatings = new Set(baseline.items.filter((row) => row.rating !== null).map((row) => row.criterion_id))
  const retained = useMemo(() => rows.filter((row) => !removals.has(row.criterion_id)), [rows, removals])
  const added = new Set(rows.filter((row) => !existing.has(row.criterion_id)).map((row) => row.criterion_id))
  const incomplete = retained.filter((r) => r.rating === null && (added.has(r.criterion_id) || r.rationale !== ""))
  const pendingName = name !== "" || weight !== "1"
  const unsaved = pendingName || conflicts.length > 0 || removals.size > 0 || !sameScores(rows, baseline.items)
  const pct = computeWeightedScorePct(retained)
  useReportDirty(busy || unsaved, onDirty)
  useEffect(() => { onScore({ pct, unsaved }) }, [pct, unsaved, onScore])
  useEffect(() => {
    if (!busy && focusId) { document.getElementById(focusId)?.focus(); setFocusId("") }
  }, [busy, focusId])

  function update(id: string, patch: Partial<ScorecardItem>) {
    setRows((items) => items.map((row) => row.criterion_id === id ? { ...row, ...patch } : row))
    setError(""); setStatus("")
  }

  function resetAdd() { setName(""); setWeight("1") }

  function markRemoval(id: string, remove: boolean) {
    const saved = baseline.items.find((row) => row.criterion_id === id)
    const local = rows.find((row) => row.criterion_id === id)
    if (!saved || !local) return
    const next = new Map(removals)
    setError(""); setStatus("")
    if (remove) {
      next.set(id, saved)
      setFocusId(`${prefix}-undo-${id}`)
    } else {
      const original = next.get(id)
      if (!original) return
      next.delete(id)
      const { row: restored, conflict } = undoScoreRemoval(original, local, saved)
      setRows((items) => items.map((row) => row.criterion_id === id ? restored : row))
      if (conflict) {
        setConflicts((current) => [...current, conflict])
        setStatus("The saved score changed while removal was pending. Review your draft before saving.")
        setFocusId(`${prefix}-resolve`)
      } else setFocusId(`${prefix}-remove-${id}`)
    }
    setRemovals(next)
  }

  function add() {
    if (!name.trim() || retained.length >= 25) return
    const suffix = globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`
    setRows([...rows, { criterion_id: `adhoc-${suffix}`, criterion_label: name.trim(),
      weight: Math.min(100, Math.max(1, Math.round(Number(weight) || 1))), rating: null, rationale: "" }])
    resetAdd(); setError(""); setStatus("")
  }

  function choose(conflict: ScoreConflict, selection: "local" | "saved") {
    const chosen = conflict[selection]
    if (conflict.removeLocal && selection === "saved") {
      const next = new Map(removals)
      next.delete(conflict.id)
      setRemovals(next)
    }
    setRows((items) => {
      if (!chosen) return items.filter((r) => r.criterion_id !== conflict.id)
      if (!items.some((r) => r.criterion_id === conflict.id)) return [...items, chosen]
      return items.map((r) => r.criterion_id === conflict.id ? chosen : r)
    })
    setConflicts(conflicts.filter((c) => c.id !== conflict.id))
    setFocusId(`${prefix}-${conflicts.length === 1 ? "save" : "resolve"}`)
    if (conflicts.length === 1) setStatus("All changes reviewed. Save the scorecard to apply your choices.")
  }

  async function refresh() {
    setBusy(true); setError(""); setStatus(""); setNeedsRefresh(true)
    try {
      const latest = await fetchSessionScorecard(sessionId)
      if (!latest.available || !latest.version) throw new Error("A current scorecard version is unavailable.")
      const merged = reconcileScores(baseline.items, rows, latest.items, removals)
      setBaseline(latest); setRows(merged.rows); setConflicts(merged.conflicts); setNeedsRefresh(false)
      setRemovals(merged.pendingRemovals)
      const alreadySaved = !merged.pendingRemovals.size && sameScores(merged.rows, latest.items)
      if (merged.conflicts.length) setStatus("Another reviewer changed the same criteria. Choose which scores to use.")
      else if (alreadySaved) setStatus("The saved scorecard already reflects your changes.")
      else setStatus("Saved scores refreshed. Review the combined scorecard before saving.")
      setFocusId(`${prefix}-${merged.conflicts.length ? "resolve" : merged.rows.length ? "save" : "name"}`)
    } catch (err) { setError(message(err)) } finally { setBusy(false) }
  }

  async function save() {
    if (busy || !baseline.version || needsRefresh || conflicts.length) return
    setAttempted(true); setStatus(""); setError("")
    if (incomplete.length) {
      setError("Some criteria still need a rating."); setFocusId(`${prefix}-rate-${incomplete[0].criterion_id}`); return
    }
    if (pendingName) {
      setError("Add or discard the new criterion before saving."); setFocusId(`${prefix}-name`); return
    }
    const payload = retained.flatMap((r) => r.rating === null ? [] : [{
      criterion_id: r.criterion_id, criterion_label: r.criterion_label, weight: r.weight, rating: r.rating, rationale: r.rationale,
    }])
    if (!payload.length && !removals.size) { setError("Select a 1 to 5 rating for at least one criterion before saving."); return }
    if (payload.length > 25) { setError("A scorecard can hold 25 ratings. Discard a new criterion before saving."); return }
    setBusy(true)
    try {
      const saved = await saveSessionScorecard(sessionId, payload, baseline.version)
      setBaseline(saved); setRows(saved.items); setRemovals(new Map()); setAttempted(false); setStatus("Scorecard saved.")
      if (!saved.items.length) setFocusId(`${prefix}-name`)
    } catch (err) {
      if (err instanceof ScorecardVersionConflict) await refresh()
      else setError(message(err))
    } finally { setBusy(false) }
  }

  return <fieldset className={styles.section} disabled={busy} aria-label="Rubric scores">
    <ScorecardCriteria rows={rows} added={added} invalid={new Set(attempted ? incomplete.map((r) => r.criterion_id) : [])}
      savedRatings={savedRatings} removals={removals} markRemoval={markRemoval}
      conflicts={conflicts} prefix={prefix} update={update} choose={choose}
      remove={(id) => { setRows(rows.filter((r) => r.criterion_id !== id)); setError(""); setStatus("") }} />
    {(retained.length < 25 || pendingName) && <div className={styles.addCriterionRow}>
      <label className="field" style={{ flex: "1 1 200px" }}>Add criterion
        <Input id={`${prefix}-name`} value={name} maxLength={200} placeholder="e.g. System design depth" onChange={(e) => setName(e.target.value)} />
      </label>
      <label className="field" style={{ flex: "0 1 96px" }}>Weight
        <Input type="number" min={1} max={100} value={weight} onChange={(e) => setWeight(e.target.value)} />
      </label>
      <Button type="button" variant="outline" size="sm" disabled={!name.trim() || retained.length >= 25} onClick={add}>
        <Plus size={14} aria-hidden="true" />Add criterion</Button>
      {pendingName && <Button type="button" variant="ghost" size="sm" onClick={resetAdd}>Discard entry</Button>}
    </div>}
    <div>
      <Button id={`${prefix}-save`} type="button" size="sm" disabled={needsRefresh || conflicts.length > 0 || !rows.length}
        onClick={save}>{busy ? "Checking scorecard..." : "Save scorecard"}</Button>
    </div>
    {needsRefresh && <div><p>Refresh the saved scorecard before saving your draft.</p>
      <Button type="button" size="sm" variant="outline" onClick={refresh}>Refresh saved scorecard</Button></div>}
    {error && <p className="error" role="alert">{error}</p>}
    {status && <p className="notice" role="status">{status}</p>}
  </fieldset>
}
