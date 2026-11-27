"use client"

import { useCallback, useEffect, useState } from "react"
import { ChevronDown, ChevronUp, ClipboardCheck } from "lucide-react"
import { message } from "@/lib/api"
import { useReportDirty, type DirtyReporter } from "@/lib/dirtyTracking"
import { isResourceUnavailable } from "@/lib/http"
import { fetchSessionScorecard, type ScorecardState } from "@/lib/sessionScorecard"
import { Button } from "./ui/button"
import InterviewRubric from "./InterviewRubric"
import PanelHandoffNotes from "./PanelHandoffNotes"
import ScorecardEditor, { type ScorePreview } from "./ScorecardEditor"
import styles from "./SessionScorecardPanel.module.css"

export default function SessionScorecardPanel({ sessionId, onDirtyChange, readOnly = false }: { sessionId: string; onDirtyChange?: DirtyReporter; readOnly?: boolean }) {
  const [expanded, setExpanded] = useState(true)
  const [loading, setLoading] = useState(true)
  const [initial, setInitial] = useState<ScorecardState | null>(null)
  const [scoreDirty, setScoreDirty] = useState(false)
  const [noteDirty, setNoteDirty] = useState(false)
  const [score, setScore] = useState<ScorePreview>({ pct: null, unsaved: false })
  const [read, setRead] = useState({ attempt: 0, verify: false })
  const [accessIssue, setAccessIssue] = useState<"read" | "write" | null>(null)
  const [error, setError] = useState("")

  const withhold = useCallback((source: "read" | "write") => {
    // Legacy notes came from the scorecard read; modern notes have their own endpoint.
    setInitial(old => old && { ...old, items: [], version: null, weighted_score_pct: null,
      handoff_notes: source === "read" && !old.handoff_notes_paged ? [] : old.handoff_notes })
    setScoreDirty(false)
    setScore({ pct: null, unsaved: false })
    setError("")
    setAccessIssue(source)
  }, [])
  function reload(verify = false) { setRead(old => ({ attempt: old.attempt + 1, verify })) }

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true); setError("")
    fetchSessionScorecard(sessionId, controller.signal)
      .then(res => {
        if (controller.signal.aborted) return
        if (read.verify && (!res.available || !res.version)) { withhold("read"); return }
        setInitial(res); setScore({ pct: res.weighted_score_pct, unsaved: false })
        setAccessIssue(null)
      })
      .catch(err => {
        if (controller.signal.aborted) return
        if (read.verify && isResourceUnavailable(err)) withhold("read")
        else setError(message(err))
      })
      .finally(() => { if (!controller.signal.aborted) setLoading(false) })
    return () => controller.abort()
  }, [sessionId, read, withhold])
  useReportDirty(scoreDirty || noteDirty, onDirtyChange)

  return <section className={styles.panel} aria-label="Session scorecard panel">
    <div className={styles.header}>
      <div className={styles.titleWrap}>
        <ClipboardCheck size={18} aria-hidden="true" />
        <h2>Rubric scorecard &amp; handoff notes</h2>
      </div>
      <div className={styles.headerMeta}>
        {initial?.available && !accessIssue && <span className={styles.scoreBadge} data-testid="scorecard-weighted-badge" aria-live="polite" aria-atomic="true">
          {score.pct !== null ? `Score: ${score.pct.toFixed(1)}%` : "Score: Ungraded"}{score.unsaved && " · Unsaved"}
        </span>}
        <Button type="button" variant="outline" size="sm" aria-expanded={expanded} onClick={() => setExpanded(v => !v)}>
          {expanded ? <ChevronUp size={15} aria-hidden="true" /> : <ChevronDown size={15} aria-hidden="true" />}
          {expanded ? "Collapse" : "Expand"}
        </Button>
      </div>
    </div>
    <div hidden={!expanded}>
      {loading && !initial ? <p className="muted" role="status">Loading scorecard...</p>
        : !initial ? <Button type="button" variant="outline" onClick={() => reload()}>Retry loading scorecard</Button>
        : !initial.available ? <p className="muted" role="status">The interview or its scorecard is unavailable.</p>
        : <>
          {accessIssue ? <div className={styles.section}>
            <p role="alert" className="error">{accessIssue === "write"
              ? "The scorecard change was refused. Reload the scorecard before editing again."
              : "The scorecard is unavailable. Reload it to check current access."}</p>
            <Button type="button" variant="outline" disabled={loading} onClick={() => reload(true)}>Reload scorecard</Button>
          </div> : readOnly ? <div className="stack">
            <InterviewRubric snapshot={initial.rubric_snapshot} />
            <h3>Saved grades</h3>
            {initial.items.length ? <ul>{initial.items.map(item => <li key={item.criterion_id}>
              {item.criterion_label}: {item.rating ?? "Ungraded"}{item.rationale && <p>{item.rationale}</p>}
            </li>)}</ul> : <p className="muted">No grades saved.</p>}
          </div> : <ScorecardEditor sessionId={sessionId} initial={initial} onDirty={setScoreDirty} onScore={setScore} onUnavailable={withhold} />}
          {(accessIssue !== "read" || initial.handoff_notes_paged) &&
            <PanelHandoffNotes readOnly={readOnly} key={sessionId} sessionId={sessionId} initial={initial} visible={expanded} onDirty={setNoteDirty} />}
        </>}
      {error && <p className="error" role="alert">{error}</p>}
    </div>
  </section>
}
