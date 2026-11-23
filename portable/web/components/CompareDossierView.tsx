"use client"

import Link from "next/link"
import { useRouter, useSearchParams } from "next/navigation"
import { useEffect, useMemo, useState } from "react"
import { Download, Printer, RotateCcw, SlidersHorizontal } from "lucide-react"
import { dateLabel, message, statusText } from "@/lib/api"
import type { FeedPage } from "@/lib/bulkArchive"
import {
  buildComparePageUrl, buildComparePrintUrl, compareInterviews, downloadCompareDossier,
  formatSlotHeading, getSlotCell, parseCompareIds, type CompareCounts, type CompareResponse,
  type CompareSessionSummary, type CompareSlotRow,
} from "@/lib/compareInterviews"
import { candidateName, lifecycle, lifecycleText, type Lifecycle } from "@/lib/interview-list"
import { interviewURL, useResource } from "@/lib/workspace"
import WorkspaceError from "./WorkspaceError"
import { Badge } from "./ui/badge"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import styles from "./CompareDossierView.module.css"

const COUNT_BADGES: Array<[keyof CompareCounts, string, "success" | "destructive" | "warning" | "secondary" | "outline"]> = [
  ["match", "Match", "success"], ["no_match", "No match", "destructive"], ["insufficient", "Limited", "warning"],
  ["pending", "Pending", "secondary"], ["explained", "Explained", "outline"],
  ["unresolved", "Unresolved", "outline"], ["disclosed", "Disclosed", "outline"],
]

const statusVariant = (status: string) =>
  status === "match" ? ("success" as const) : status === "no_match" ? ("destructive" as const) : ("warning" as const)

const lifecycleLabel = (value: string) =>
  value in lifecycleText ? lifecycleText[value as Lifecycle] : value || "Unknown"

function InterviewQuestionCell({ session, row, includeExcerpts, includeNotes }: {
  session: CompareSessionSummary; row: CompareSlotRow; includeExcerpts: boolean; includeNotes: boolean
}) {
  const answer = getSlotCell(row, session.id)
  const prompt = row.planned_questions?.[session.id]
  const otherInterview = row.owner_session_id !== undefined && row.owner_session_id !== session.id
  return (
    <td>
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
            <Badge variant={statusVariant(answer.status)}>{statusText[answer.status as keyof typeof statusText] || answer.status}</Badge>
            <Badge variant="outline">{answer.disposition}</Badge>
          </div>
          {prompt !== answer.question && <p className={styles.cellQuestion}>
            {row.planned_questions && <span className={styles.promptLabel}>Recorded question</span>}{answer.question}
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
  // Each candidate selection starts with private notes and excerpts excluded.
  return <CandidateComparison key={parsed.ids.join(",")} parsed={parsed} />
}

function CandidateComparison({ parsed }: { parsed: ReturnType<typeof parseCompareIds> }) {
  const router = useRouter()
  const selectedIds = parsed.ids
  const [pickerOpen, setPickerOpen] = useState(false)
  const [draftIds, setDraftIds] = useState<string[]>(selectedIds)
  const [searchText, setSearchText] = useState("")
  const [debouncedSearch, setDebouncedSearch] = useState("")
  const [includeExcerpts, setIncludeExcerpts] = useState(false)
  const [includeNotes, setIncludeNotes] = useState(false)
  const [result, setResult] = useState<{ key: string; data: CompareResponse } | null>(null)
  const [error, setError] = useState("")
  const [refresh, setRefresh] = useState(0)
  const [downloading, setDownloading] = useState(false)
  const [downloadNotice, setDownloadNotice] = useState("")

  useEffect(() => {
    const timer = window.setTimeout(() => setDebouncedSearch(searchText.trim().slice(0, 120)), 140)
    return () => window.clearTimeout(timer)
  }, [searchText])

  const showPicker = selectedIds.length < 2 || pickerOpen
  const archive = useResource<FeedPage>(
    showPicker ? "interviews/feed?page_size=50" + (debouncedSearch ? "&q=" + encodeURIComponent(debouncedSearch) : "") : null,
  )
  const requestKey = useMemo(
    () => (selectedIds.length >= 2 ? JSON.stringify({ selectedIds, includeExcerpts, includeNotes, refresh }) : ""),
    [selectedIds, includeExcerpts, includeNotes, refresh],
  )

  useEffect(() => {
    if (!requestKey) { setError(""); return }
    const controller = new AbortController()
    setError("")
    compareInterviews({ session_ids: selectedIds, include_excerpts: includeExcerpts, include_notes: includeNotes }, controller.signal)
      .then((data) => { if (!controller.signal.aborted) setResult({ key: requestKey, data }) })
      .catch((err) => { if (!controller.signal.aborted) setError(message(err)) })
    return () => controller.abort()
  }, [requestKey, selectedIds, includeExcerpts, includeNotes])

  const data = result?.key === requestKey ? result.data : null
  const loading = Boolean(requestKey) && !data && !error
  const printUrl = buildComparePrintUrl(selectedIds, { includeExcerpts, includeNotes })

  function toggleDraft(id: string, checked: boolean) {
    setDraftIds((prev) => (!checked ? prev.filter((item) => item !== id) : prev.includes(id) || prev.length >= 6 ? prev : [...prev, id]))
  }

  function applySelection() {
    if (draftIds.length < 2 || draftIds.length > 6) return
    setPickerOpen(false)
    router.replace(buildComparePageUrl(draftIds))
  }

  async function handleDownload() {
    if (selectedIds.length < 2 || downloading) return
    setDownloading(true)
    setDownloadNotice("")
    setError("")
    try {
      const filename = await downloadCompareDossier({
        session_ids: selectedIds, include_excerpts: includeExcerpts, include_notes: includeNotes,
      })
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
            <Button type="button" variant="outline" size="sm" onClick={() => setPickerOpen((open) => !open)}>
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

      {(parsed.ignoredCount > 0 || parsed.truncatedCount > 0) && (
        <p className="notice" role="status">
          {parsed.ignoredCount > 0 && `Ignored ${parsed.ignoredCount} invalid interview ID(s). `}
          {parsed.truncatedCount > 0 && "Comparison supports up to 6 interviews; showing the first 6."}
        </p>
      )}
      {downloadNotice && <p className="notice" role="status">{downloadNotice}</p>}

      {showPicker && (
        <section className={`panel ${styles.pickerPanel}`} aria-labelledby="compare-picker-heading">
          <div className={styles.pickerControls}>
            <div>
              <h2 id="compare-picker-heading">Select interviews</h2>
              <p className="muted">Choose 2 to 6 active interviews ({draftIds.length} of 6 selected).</p>
            </div>
            <div className={styles.headerActions}>
              {selectedIds.length >= 2 && (
                <Button type="button" variant="ghost" size="sm" onClick={() => { setDraftIds(selectedIds); setPickerOpen(false) }}>
                  Cancel
                </Button>
              )}
              <Button type="button" size="sm" disabled={draftIds.length < 2 || draftIds.length > 6} onClick={applySelection}>
                Compare selected ({draftIds.length})
              </Button>
            </div>
          </div>
          <label className={`field ${styles.pickerSearch}`}>
            Filter active archive
            <Input
              type="search" maxLength={120} placeholder="Search by candidate or role"
              value={searchText} onChange={(e) => setSearchText(e.target.value)}
            />
          </label>
          {archive.error && <WorkspaceError text={archive.error} retry={archive.reload} />}
          {!archive.data && !archive.error && <p className="muted" role="status">Loading interviews…</p>}
          {!archive.error && archive.data && !debouncedSearch && archive.data.items.length < 2 && (
            <div className="notice row" role="status">
              <span>
                {archive.data.items.length === 0
                  ? "No active interviews yet. Create at least 2 interviews to compare candidates."
                  : "Only 1 active interview found. Create another interview to compare 2 or more candidates."}
              </span>
              <Button asChild size="sm"><Link href="/interviews/new/">New interview</Link></Button>
            </div>
          )}
          {!archive.error && archive.data && debouncedSearch && archive.data.items.length === 0 && (
            <div className="notice row" role="status">
              <span>No active interviews match your filter.</span>
              <Button type="button" variant="outline" size="sm" onClick={() => setSearchText("")}>Clear search</Button>
              <Link className="text-action" href="/interviews/">Open interviews</Link>
            </div>
          )}
          {!archive.error && archive.data && archive.data.items.length > 0 && (
            <ul className={styles.pickerList}>
              {archive.data.items.map((item) => {
                const checked = draftIds.includes(item.id)
                return (
                  <li key={item.id}>
                    <label className={checked ? `${styles.pickerOption} ${styles.pickerOptionSelected}` : styles.pickerOption}>
                      <input
                        type="checkbox" checked={checked} disabled={!checked && draftIds.length >= 6}
                        onChange={(e) => toggleDraft(item.id, e.target.checked)}
                      />
                      <span className={styles.pickerMeta}>
                        <strong>{candidateName(item)}</strong>
                        <small>{item.role || "No role"} · {lifecycleText[lifecycle(item)]} · {dateLabel(item.created_at)}</small>
                      </span>
                      <Badge variant="outline">{item.answer_count} answers</Badge>
                    </label>
                  </li>
                )
              })}
            </ul>
          )}
        </section>
      )}

      {selectedIds.length >= 2 && (
        <section className={`panel ${styles.optionsBar}`} aria-label="Comparison options">
          <div className={styles.toggles}>
            <label className="check"><input type="checkbox" checked={includeExcerpts} onChange={(e) => setIncludeExcerpts(e.target.checked)} />Include answer excerpts</label>
            <label className="check"><input type="checkbox" checked={includeNotes} onChange={(e) => setIncludeNotes(e.target.checked)} />Include interviewer notes</label>
          </div>
          {error && <Button type="button" variant="outline" size="sm" onClick={() => setRefresh((n) => n + 1)}><RotateCcw aria-hidden="true" />Retry comparison</Button>}
        </section>
      )}

      {error && <WorkspaceError text={error} retry={() => setRefresh((n) => n + 1)} />}
      {loading && <section className="panel inset" role="status"><p className="muted">Preparing candidate comparison…</p></section>}

      {data && (
        <>
          <section className={styles.section} aria-labelledby="compare-cards-heading">
            <h2 id="compare-cards-heading">Candidates ({data.sessions.length})</h2>
            <div className={styles.cardsGrid}>
              {data.sessions.map((session) => (
                <article key={session.id} className={`panel ${styles.candidateCard}`}>
                  <div className={styles.cardHead}>
                    <div>
                      <Link className={styles.cardTitle} href={interviewURL(session.id)}>
                        {session.candidate || "Unnamed candidate"}
                      </Link>
                      <p className={styles.cardMeta}>{session.role || "No role assigned"}</p>
                    </div>
                    <Badge variant="outline">{lifecycleLabel(session.lifecycle)}</Badge>
                  </div>
                  <p className={styles.cardMeta}>
                    {dateLabel(session.created_at)} · {session.consent ? "Consent recorded" : "No consent"} · {session.answer_count} answers
                  </p>
                  {session.policy && <p className={styles.policyText}>Policy: {session.policy}</p>}
                  <div className={styles.countsList}>
                    {COUNT_BADGES.map(([key, label, variant]) => (
                      <Badge key={key} variant={variant}>{label} {session.counts[key]}</Badge>
                    ))}
                  </div>
                </article>
              ))}
            </div>
          </section>

          <section className={`panel ${styles.section}`} aria-labelledby="compare-matrix-heading">
            <h2 id="compare-matrix-heading">Question-slot matrix</h2>
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
                      {data.sessions.map((s) => <th key={s.id} scope="col">{s.candidate || "Unnamed candidate"}</th>)}
                    </tr>
                  </thead>
                  <tbody>
                    {data.slots.map((row, idx) => (
                      <tr key={`${String(row.slot)}-${idx}`}>
                        <th scope="row" className={styles.slotCellHead}>
                          <div>{formatSlotHeading(row, idx)}</div>
                          {row.planned_question && <p className={styles.cellMeta}>{row.planned_question}</p>}
                        </th>
                        {data.sessions.map(session => <InterviewQuestionCell key={session.id} session={session} row={row}
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
              <h2 id="compare-rubric-heading">Shared role rubric criteria</h2>
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
