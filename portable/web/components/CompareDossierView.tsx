"use client"

import Link from "next/link"
import { useRouter, useSearchParams } from "next/navigation"
import { useEffect, useMemo, useRef, useState } from "react"
import { Download, Printer, RotateCcw, SlidersHorizontal } from "lucide-react"
import { message, statusText } from "@/lib/api"
import {
  buildComparePageUrl, buildComparePrintUrl, compareInterviews, downloadCompareDossier,
  formatSlotHeading, getSlotCell, parseCompareIds, type CompareResponse,
  type CompareSessionSummary, type CompareSlotRow,
} from "@/lib/compareInterviews"
import { interviewURL } from "@/lib/workspace"
import ComparisonScorecards from "./ComparisonScorecards"
import ComparisonCandidateCard from "./ComparisonCandidateCard"
import WorkspaceError from "./WorkspaceError"
import { Badge } from "./ui/badge"
import { Button } from "./ui/button"
import ComparisonPicker from "./ComparisonPicker"
import styles from "./CompareDossierView.module.css"

function InterviewQuestionCell({ session, row, rowHeader, includeExcerpts, includeNotes }: {
  session: CompareSessionSummary; row: CompareSlotRow; rowHeader: string; includeExcerpts: boolean; includeNotes: boolean
}) {
  const answer = getSlotCell(row, session.id)
  const prompt = row.planned_questions?.[session.id]
  const otherInterview = row.owner_session_id !== undefined && row.owner_session_id !== session.id
  return (
    <td headers={`${rowHeader} compare-column-${session.id}`}>
      <div className={styles.cellStack}>
        <strong className={styles.mobileCandidate} aria-hidden="true">{session.candidate || "Unnamed candidate"}</strong>
        {prompt === null && <p className={styles.cellMeta}>Not in this interview plan.</p>}
        {typeof prompt === "string" && <p className={styles.cellQuestion}>
          <span className={styles.promptLabel}>Planned question</span>{prompt}
        </p>}
        {!answer && prompt !== null && <span className={styles.cellMeta}>
          {otherInterview ? "Not applicable" : "No response recorded"}
        </span>}
        {answer && <>
          <div className={styles.countsList}>
            <span className={`status ${answer.status}`}>{statusText[answer.status as keyof typeof statusText] || answer.status}</span>
            <Badge variant="outline">{answer.disposition}</Badge>
          </div>
          {(prompt ?? row.planned_question) !== answer.question && <p className={styles.cellQuestion}>
            {(row.planned_questions || row.planned_question) && <span className={styles.promptLabel}>Recorded question</span>}{answer.question}
          </p>}
          <span className={styles.cellMeta}>{answer.passage_count} {answer.passage_count === 1 ? "passage" : "passages"}</span>
          {includeExcerpts && answer.excerpt && <blockquote className={styles.excerpt}>{answer.excerpt}</blockquote>}
          {includeNotes && answer.note && <p className={styles.note}><strong>Note:</strong> {answer.note}</p>}
          <Link className={styles.cellLink} href={interviewURL(session.id, answer.answer_id)}>Open answer</Link>
        </>}
      </div>
    </td>
  )
}

export default function CompareDossierView() {
  const ids = useSearchParams().get("ids")
  const parsed = useMemo(() => parseCompareIds(ids), [ids])
  // A new selection requires a fresh opt-in to private review material.
  return <CandidateComparison key={parsed.ids.join(",")} parsed={parsed} />
}

function CandidateComparison({ parsed }: { parsed: ReturnType<typeof parseCompareIds> }) {
  const router = useRouter()
  const selectedIds = parsed.ids
  const [pickerOpen, setPickerOpen] = useState(false)
  const pickerButton = useRef<HTMLButtonElement>(null)
  const [includeExcerpts, setIncludeExcerpts] = useState(false)
  const [includeNotes, setIncludeNotes] = useState(false)
  const [scorecardDetail, setScorecardDetail] = useState<"none" | "ratings" | "rationales">("none")
  const includeScorecards = scorecardDetail !== "none"
  const includeRationales = scorecardDetail === "rationales"
  const [result, setResult] = useState<{ key: string; data: CompareResponse } | null>(null)
  const [error, setError] = useState("")
  const [refresh, setRefresh] = useState(0)
  const [downloading, setDownloading] = useState(false)
  const [downloadNotice, setDownloadNotice] = useState("")

  const showPicker = selectedIds.length < 2 || pickerOpen
  const comparison = useMemo(() => ({
    session_ids: selectedIds, include_excerpts: includeExcerpts, include_notes: includeNotes,
    ...(includeScorecards && { include_scorecards: true }),
    ...(includeRationales && { include_rationales: true }),
  }), [selectedIds, includeExcerpts, includeNotes, includeScorecards, includeRationales])
  const requestKey = selectedIds.length >= 2 ? JSON.stringify([comparison, refresh]) : ""

  useEffect(() => {
    if (!requestKey) { setError(""); return }
    const controller = new AbortController()
    setError("")
    compareInterviews(comparison, controller.signal)
      .then((data) => { if (!controller.signal.aborted) setResult({ key: requestKey, data }) })
      .catch((err) => { if (!controller.signal.aborted) setError(message(err)) })
    return () => controller.abort()
  }, [requestKey, comparison])

  const data = result?.key === requestKey ? result.data : null
  const loading = Boolean(requestKey) && !data && !error
  const printUrl = buildComparePrintUrl(selectedIds, { includeExcerpts, includeNotes, includeScorecards, includeRationales })

  function closePicker() {
    setPickerOpen(false)
    pickerButton.current?.focus()
  }

  function applySelection(draftIds: string[]) {
    if (draftIds.length < 2 || draftIds.length > 6) return
    closePicker()
    router.replace(buildComparePageUrl(draftIds))
  }

  async function handleDownload() {
    if (selectedIds.length < 2 || downloading) return
    setDownloading(true)
    setDownloadNotice("")
    setError("")
    try {
      const filename = await downloadCompareDossier(comparison)
      setDownloadNotice(`Downloaded ${filename}.`)
    } catch (err) {
      setError(message(err))
    } finally {
      setDownloading(false)
    }
  }

  return (
    <div className={styles.root}>
      <header className={styles.header}>
        <div className="page-title">
          <span className="eyebrow">COMPARISON MATRIX</span>
          <h1>Candidate comparison</h1>
          <p>
            {selectedIds.length >= 2
              ? `Comparing ${selectedIds.length} candidates using their saved interview plans.`
              : "Select 2 to 6 interviews to compare candidates side by side."}
          </p>
        </div>
        {selectedIds.length >= 2 && (
          <div className={styles.headerActions}>
            <Button ref={pickerButton} type="button" variant="outline" size="sm" aria-expanded={pickerOpen} onClick={() => setPickerOpen((open) => !open)}>
              <SlidersHorizontal aria-hidden="true" />{pickerOpen ? "Hide selector" : "Change interviews"}
            </Button>
            <Button type="button" size="sm" disabled={downloading || loading || !data} onClick={() => void handleDownload()}>
              <Download aria-hidden="true" />{downloading ? "Preparing…" : "Download Markdown dossier"}
            </Button>
            <Button asChild variant="outline" size="sm">
              <a href={printUrl} target="_blank" rel="noreferrer"><Printer aria-hidden="true" />Print or save PDF</a>
            </Button>
          </div>
        )}
      </header>

      {data && <nav className={styles.sectionLinks} aria-label="Comparison sections">
        <a href="#compare-cards-heading">Candidates</a>
        {includeScorecards && <a href="#saved-scorecards-heading">Scorecards</a>}
        <a href="#compare-matrix-heading">Questions</a>
        {!!data.rubric_criteria?.length && <a href="#compare-rubric-heading">Role rubric</a>}
      </nav>}

      {(parsed.ignoredCount > 0 || parsed.truncatedCount > 0) && (
        <p className="notice" role="status">
          {parsed.ignoredCount > 0 && `Ignored ${parsed.ignoredCount} invalid interview ID(s). `}
          {parsed.truncatedCount > 0 && "Comparison supports up to 6 interviews; showing the first 6."}
        </p>
      )}
      {downloadNotice && <p className="notice" role="status">{downloadNotice}</p>}

      <ComparisonPicker open={showPicker} committed={selectedIds} known={data?.sessions}
        apply={applySelection} cancel={selectedIds.length >= 2 ? closePicker : undefined} />

      {selectedIds.length >= 2 && (
        <section className={`panel ${styles.optionsBar}`} aria-label="Comparison options">
          <fieldset className={styles.disclosures}>
            <legend>Include in comparison and exports</legend>
            <div className={styles.toggles}>
              <label className="check"><input type="checkbox" checked={includeExcerpts} onChange={(e) => setIncludeExcerpts(e.target.checked)} />Include answer excerpts</label>
              <label className="check"><input type="checkbox" checked={includeNotes} onChange={(e) => setIncludeNotes(e.target.checked)} />Include interviewer notes</label>
              <label className="check"><input type="checkbox" checked={includeScorecards}
                onChange={e => setScorecardDetail(e.target.checked ? "ratings" : "none")} />Include saved scorecards</label>
              <label className="check"><input type="checkbox" checked={includeRationales} disabled={!includeScorecards}
                onChange={e => setScorecardDetail(e.target.checked ? "rationales" : "ratings")} />Include reviewer rationales</label>
            </div>
          </fieldset>
          {error && <Button type="button" variant="outline" size="sm" onClick={() => setRefresh((n) => n + 1)}><RotateCcw aria-hidden="true" />Retry comparison</Button>}
        </section>
      )}

      {error && <WorkspaceError text={error} retry={() => setRefresh((n) => n + 1)} />}
      {loading && <section className="panel inset" role="status"><p className="muted">Preparing candidate comparison…</p></section>}

      {data && (
        <>
          <section className={styles.section} aria-labelledby="compare-cards-heading">
            <h2 id="compare-cards-heading" tabIndex={-1}>Candidates ({data.sessions.length})</h2>
            <div className={styles.cardsGrid}>
              {data.sessions.map(session => <ComparisonCandidateCard key={session.id} session={session} />)}
            </div>
          </section>

          {includeScorecards && <ComparisonScorecards sessions={data.sessions} includeRationales={includeRationales} />}

          <section className={`panel ${styles.section}`} aria-labelledby="compare-matrix-heading">
            <h2 id="compare-matrix-heading" tabIndex={-1}>Question-slot matrix</h2>
            {data.slots.some(row => row.owner_session_id) && <p className="muted">
              Additional answers follow their planned question in recorded order. Unslotted exchanges appear last in recorded order.
            </p>}
            {data.slots.length === 0 ? (
              <p className="muted">No recorded questions or answers across the selected interviews.</p>
            ) : (
              <div className={styles.matrixWrap}>
                <table className={styles.matrixTable}>
                  <thead>
                    <tr>
                      <th scope="col" className={styles.slotCellHead}>Question slot</th>
                      {data.sessions.map((s) => <th key={s.id} id={`compare-column-${s.id}`} scope="col">{s.candidate || "Unnamed candidate"}</th>)}
                    </tr>
                  </thead>
                  <tbody>
                    {data.slots.map((row, idx) => (
                      <tr key={`${String(row.slot)}-${idx}`}>
                        <th id={`compare-row-${idx}`} scope="row" className={styles.slotCellHead}>
                          <div>{formatSlotHeading(row, idx)}</div>
                          {row.planned_question && <p className={styles.cellMeta}>{row.planned_question}</p>}
                        </th>
                        {data.sessions.map(session => <InterviewQuestionCell key={session.id} session={session} row={row} rowHeader={`compare-row-${idx}`}
                          includeExcerpts={includeExcerpts} includeNotes={includeNotes} />)}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>

          {data.rubric_criteria && data.rubric_criteria.length > 0 && (
            <section className={`panel ${styles.section}`} aria-labelledby="compare-rubric-heading">
              <h2 id="compare-rubric-heading" tabIndex={-1}>Shared role rubric criteria</h2>
              <p className="muted">Current guidance from the shared role definition.</p>
              <div className={styles.rubricGrid}>
                {data.rubric_criteria.map((item, idx) => (
                  <article key={item.id || `${item.criterion}-${idx}`} className={styles.rubricCard}>
                    <div className={styles.cardHead}>
                      <strong>{item.criterion}</strong>
                      {typeof item.weight === "number" && <Badge variant="default">Weight {item.weight}</Badge>}
                    </div>
                    {item.expected_signals && item.expected_signals.length > 0 && (
                      <div><small className="muted">Expected signals</small><ul>{item.expected_signals.map((sig, i) => <li key={i}>{sig}</li>)}</ul></div>
                    )}
                    {item.red_flags && item.red_flags.length > 0 && (
                      <div><small className="muted">Red flags</small><ul>{item.red_flags.map((flag, i) => <li key={i}>{flag}</li>)}</ul></div>
                    )}
                  </article>
                ))}
              </div>
            </section>
          )}
        </>
      )}
    </div>
  )
}
