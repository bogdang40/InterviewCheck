"use client"

import { useEffect, useState } from "react"
import { ChevronDown, ChevronUp, ClipboardCheck } from "lucide-react"
import { message } from "@/lib/api"
import { useReportDirty, type DirtyReporter } from "@/lib/dirtyTracking"
import { fetchSessionScorecard, type ScorecardState } from "@/lib/sessionScorecard"
import { Button } from "./ui/button"
import PanelHandoffNotes from "./PanelHandoffNotes"
import ScorecardEditor from "./ScorecardEditor"
import styles from "./SessionScorecardPanel.module.css"

export default function SessionScorecardPanel({ sessionId, onDirtyChange }: { sessionId: string; onDirtyChange?: DirtyReporter }) {
  const [expanded, setExpanded] = useState(true)
  const [loading, setLoading] = useState(true)
  const [initial, setInitial] = useState<ScorecardState | null>(null)
  const [scoreDirty, setScoreDirty] = useState(false)
  const [noteDirty, setNoteDirty] = useState(false)
  const [liveWeightedPct, setLiveWeightedPct] = useState<number | null>(null)
  const [loadAttempt, setLoadAttempt] = useState(0)
  const [error, setError] = useState("")

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true); setError("")
    fetchSessionScorecard(sessionId, controller.signal)
      .then(res => {
        if (controller.signal.aborted) return
        setInitial(res); setLiveWeightedPct(res.weighted_score_pct)
      })
      .catch(err => { if (!controller.signal.aborted) setError(message(err)) })
      .finally(() => { if (!controller.signal.aborted) setLoading(false) })
    return () => controller.abort()
  }, [sessionId, loadAttempt])
  useReportDirty(scoreDirty || noteDirty, onDirtyChange)

  return <section className={styles.panel} aria-label="Session scorecard panel">
    <div className={styles.header}>
      <div className={styles.titleWrap}>
        <ClipboardCheck size={18} aria-hidden="true" />
        <h2>Rubric scorecard &amp; handoff notes</h2>
      </div>
      <div className={styles.headerMeta}>
        <span className={styles.scoreBadge} data-testid="scorecard-weighted-badge">
          {liveWeightedPct !== null ? `Score: ${liveWeightedPct.toFixed(1)}%` : "Score: Ungraded"}
        </span>
        <Button type="button" variant="outline" size="sm" aria-expanded={expanded} onClick={() => setExpanded(v => !v)}>
          {expanded ? <ChevronUp size={15} aria-hidden="true" /> : <ChevronDown size={15} aria-hidden="true" />}
          {expanded ? "Collapse" : "Expand"}
        </Button>
      </div>
    </div>
    <div hidden={!expanded}>
      {loading ? <p className="muted" role="status">Loading scorecard...</p>
        : !initial ? <Button type="button" variant="outline" onClick={() => setLoadAttempt(attempt => attempt + 1)}>Retry loading scorecard</Button>
        : !initial.available ? <p className="muted" role="status">The interview or its scorecard is unavailable.</p>
        : <>
          <ScorecardEditor sessionId={sessionId} initial={initial} onDirty={setScoreDirty} onScore={setLiveWeightedPct} />
          <PanelHandoffNotes key={sessionId} sessionId={sessionId} initial={initial} visible={expanded} onDirty={setNoteDirty} />
        </>}
      {error && <p className="error" role="alert">{error}</p>}
    </div>
  </section>
}
