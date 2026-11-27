import dynamic from "next/dynamic"
import { useEffect, useLayoutEffect, useRef, useState, type FormEvent, type MutableRefObject } from "react"
import { ClipboardCheck, Pencil, Quote } from "lucide-react"
import { api, message, RevisionConflict, statusText, WorksheetUnavailable, type Answer, type Disposition, type Interview } from "@/lib/api"
import CandidateResponse from "./CandidateResponse"
import MarkedText from "./MarkedText"
import JudgeAssist from "./JudgeAssist"
import { Button } from "./ui/button"
import { Textarea } from "./ui/textarea"
import { formatDraftTimestamp, reviewDraftKey, useLocalDraftRecovery } from "@/lib/localDraftBuffer"
import UnlinkedDraftCopy from "./UnlinkedDraftCopy"
import { confirmsWorksheetSave, currentWorksheet, MAX_NOTE_CHARACTERS, normalizedWorksheetNote, type WorksheetGuard, type WorksheetState } from "@/lib/reviewWorksheet"
import { watchWorksheetAccess } from "@/lib/worksheetPrivacy"

const ReviewWorksheet = dynamic(() => import("./ReviewWorksheet"), { ssr: false })

const ConflictReview = dynamic(() => import("./ConflictReview"), { ssr: false })

const RevisionHistory = dynamic(() => import("./RevisionHistory"), { ssr: false })

const useIsomorphicLayoutEffect = typeof window === "undefined" ? useEffect : useLayoutEffect

export type EvidenceHotkeyControls = {
  setOutcome: (value: Extract<Disposition, "explained" | "unresolved">) => boolean
  focusNote: () => boolean
}

const earlierNotePrefix = "Note from an earlier answer version:\n"

export function Findings({ result }: { result: Answer["result"] }) {
  return (
    <div className="findings">
      <div className="spread">
        <h3>Comparison result</h3>
        <span className={"status " + result.status}>{statusText[result.status]}</span>
      </div>
      <p>{result.explanation}</p>
      {result.passages.map((p, i) => (
        <div className="passage" key={i}>
          <div className="passage-meta">
            <Quote size={13} />
            {p.words} matched words
          </div>
          <div className="dual">
            <div>
              <span className="small-label">Candidate passage</span>
              <blockquote>{p.answer_excerpt}</blockquote>
            </div>
            <div>
              <span className="small-label">{p.label}</span>
              <blockquote>{p.source_excerpt}</blockquote>
            </div>
          </div>
        </div>
      ))}
      <div className="probe">
        <span className="eyebrow">ASK NEXT</span>
        <p>{result.follow_up}</p>
      </div>
    </div>
  )
}

export default function Evidence({
  item: initial,
  index,
  session,
  onSave,
  onEdit,
  onDirty,
  onFollowUp,
  canAdvance,
  judgeAvailable,
  controlsRef,
}: {
  item: Answer
  index: number
  session: Interview
  onSave: (a: Answer, advance?: boolean) => void
  canAdvance?: boolean
  onFollowUp?: (questionText?: string) => void
  onDirty: (id: string, value: boolean) => void
  onEdit?: () => void
  judgeAvailable?: boolean
  controlsRef?: MutableRefObject<EvidenceHotkeyControls | null>
}) {
  const sessionId = session.id
  const [item, setItem] = useState(initial)
  const [worksheet, setWorksheet] = useState<WorksheetGuard | null>(null)
  const [submittedNote, setSubmittedNote] = useState<string | null>(null)
  const [compared, setCompared] = useState<WorksheetState | null>(null)
  const worksheetBlocked = submittedNote !== null
  const [withdrawn, setWithdrawn] = useState(false)
  const [reconcileNotice, setReconcileNotice] = useState("")
  const worksheetEpoch = useRef(0)
  const [conflict, setConflict] = useState(false)
  const [note, setNote] = useState(item.note)
  const [disposition, setDisposition] = useState<Disposition>(item.disposition)
  const [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [saved, setSaved] = useState(false)
  const noteRef = useRef<HTMLTextAreaElement>(null)
  const oversizedWorksheetNote = !!worksheet && Array.from(normalizedWorksheetNote(note)).length > MAX_NOTE_CHARACTERS
  const dirty = !withdrawn && (note !== item.note || disposition !== item.disposition)
  const { recovered, clear: clearLocalBuffer, markRestored } = useLocalDraftRecovery(
    reviewDraftKey(sessionId, item.id), dirty && !worksheet, JSON.stringify([note, disposition]),
    () => ({ text: note, note, disposition, baseRevision: item.revision }),
    (b) => (b.note ?? b.text) === item.note && (b.disposition === undefined || b.disposition === item.disposition),
  )
  function withdrawWorksheet() {
    ++worksheetEpoch.current
    setWithdrawn(true); setBusy(false); setConflict(false); setWorksheet(null); setSubmittedNote(null); setCompared(null)
    setNote(""); setSaved(false); setError(""); clearLocalBuffer()
  }
  useEffect(() => {
    if (!worksheet) return
    return watchWorksheetAccess(sessionId, withdrawWorksheet)
  }, [worksheet, sessionId, clearLocalBuffer])
  useEffect(() => () => { ++worksheetEpoch.current }, [])
  function stageWorksheet(current: WorksheetState, proposed: string) {
    setItem(current.answer); setDisposition(current.answer.disposition); setNote(proposed)
    setWorksheet({ material: current.material, review: current.review }); setSubmittedNote(null); setCompared(null)
    setSaved(false); setError(""); setReconcileNotice(""); noteRef.current?.focus()
  }
  const restoreLocalDraft = () => {
    noteRef.current?.focus()
    if (!recovered || !markRestored()) return
    setNote(recovered.note ?? recovered.text)
    if (recovered.disposition === "pending" || recovered.disposition === "explained" ||
      recovered.disposition === "unresolved" || recovered.disposition === "disclosed") {
      setDisposition(recovered.disposition)
    }
    setSaved(false)
  }
  useEffect(() => {
    if (!worksheet && !dirty && !busy && !conflict && initial.revision > item.revision) {
      setItem(initial); setNote(initial.note); setDisposition(initial.disposition); setSaved(false)
    }
  }, [initial, item.revision, dirty, busy, conflict, worksheet])
  useIsomorphicLayoutEffect(() => {
    onDirty(item.id, dirty || busy || conflict || worksheetBlocked)
    return () => onDirty(item.id, false)
  }, [item.id, dirty, busy, conflict, worksheetBlocked, onDirty])
  useIsomorphicLayoutEffect(() => {
    if (!controlsRef) return
    const handle: EvidenceHotkeyControls = {
      setOutcome: (value) => {
        if (busy || conflict || worksheet || withdrawn) return false
        setDisposition(value)
        setSaved(false)
        return true
      },
      focusNote: () => {
        if (busy || !noteRef.current) return false
        noteRef.current.focus()
        noteRef.current.scrollIntoView({ block: "nearest" })
        return true
      },
    }
    controlsRef.current = handle
    return () => {
      if (controlsRef.current === handle) controlsRef.current = null
    }
  }, [controlsRef, busy, conflict, worksheet, withdrawn])
  async function save(e: FormEvent) {
    e.preventDefault()
    if (busy || conflict || worksheetBlocked || oversizedWorksheetNote || (worksheet && !dirty)) return
    const savingEpoch = worksheetEpoch.current
    const proposed = worksheet ? normalizedWorksheetNote(note) : note
    const submitter = (e.nativeEvent as SubmitEvent).submitter
    const advance = !!canAdvance && disposition !== "pending" && submitter?.getAttribute("value") === "next"
    setError(""); setReconcileNotice("")
    setBusy(true)
    try {
      const result = await api<Answer>(`sessions/${sessionId}/answers/${item.id}`, "PATCH", {
        note: proposed, disposition, expected_revision: item.revision, ...(worksheet ? { worksheet_guard: worksheet } : {}),
      })
      if (worksheet && savingEpoch !== worksheetEpoch.current) return
      if (worksheet && !confirmsWorksheetSave(result, item, proposed)) {
        throw new Error("The server did not confirm the worksheet save.")
      }
      setWorksheet(null); setSubmittedNote(null); setCompared(null)
      clearLocalBuffer()
      setItem(result)
      setNote(result.note)
      setDisposition(result.disposition)
      onSave(result, advance)
      setSaved(true)
    } catch (e) {
      if (worksheet && savingEpoch !== worksheetEpoch.current) return
      if (worksheet && e instanceof WorksheetUnavailable) {
        withdrawWorksheet()
      } else if (worksheet) {
        setSubmittedNote(proposed); setCompared(null)
        setError(message(e) + " Check the saved review before sending another change.")
      } else if (e instanceof RevisionConflict) setConflict(true)
      else setError(message(e))
    } finally {
      if (!worksheet || savingEpoch === worksheetEpoch.current) setBusy(false)
    }
  }
  async function reconcile(acceptCurrent: boolean) {
    if (!worksheet || submittedNote === null || busy) return
    const epoch = worksheetEpoch.current
    setBusy(true)
    try {
      const live = await currentWorksheet(session, item, index + 1)
      if (worksheetEpoch.current !== epoch) return
      if (live.material !== worksheet.material) {
        setCompared(null); setError("The original exchange has been replaced. Your edit cannot be applied to this record.")
        return
      }
      const alreadySaved = live.answer.note === submittedNote
      if (!alreadySaved && live.review !== worksheet.review && (!acceptCurrent || compared?.review !== live.review)) {
        setCompared(live); setError("The saved review changed. Compare it with your edited note.")
        return
      }
      const unfinished = normalizedWorksheetNote(note) !== live.answer.note
      setItem(live.answer); setDisposition(live.answer.disposition)
      setSubmittedNote(null); setCompared(null); setError("")
      if (unfinished) {
        setWorksheet({ material: live.material, review: live.review })
        setSaved(false)
      } else {
        setWorksheet(null); setNote(live.answer.note); setSaved(true)
        clearLocalBuffer(); onSave(live.answer)
      }
      setReconcileNotice(alreadySaved ? "The submitted note is already saved."
        : acceptCurrent ? "Your edited note is staged against the reviewed version." : "The saved review is unchanged. Your edits are still staged.")
      noteRef.current?.focus()
    } catch (e) {
      if (worksheetEpoch.current !== epoch) return
      if (e instanceof WorksheetUnavailable) withdrawWorksheet()
      else setError(message(e) + " Your edits remain in this tab.")
    } finally {
      if (worksheetEpoch.current === epoch) setBusy(false)
    }
  }
  if (withdrawn) return <section className="panel stack" role="region" aria-label="Worksheet unavailable">
    <p role="alert">The worksheet edit was cleared because access to this exchange changed.</p>
    <Button type="button" variant="outline" onClick={() => window.location.reload()}>Reload interview</Button>
  </section>
  const stale = recovered && recovered.baseRevision !== undefined && recovered.baseRevision !== item.revision
  return (
    <article className="panel evidence">
      <div className="spread">
        <span className="eyebrow">QUESTION {String(index + 1).padStart(2, "0")}</span>
        {onEdit && (
          <Button variant="ghost" size="sm" onClick={onEdit}>
            <Pencil />
            Edit exchange
          </Button>
        )}
      </div>
      <h2>{item.question}</h2>
      <CandidateResponse item={item}/>
      <Findings result={item.result} />
      <JudgeAssist key={`${item.id}:${item.revision}`} sessionId={sessionId} item={item}
        judgeAvailable={judgeAvailable} onFollowUp={onFollowUp} />
      {onFollowUp && (
        <Button variant="outline" size="sm" onClick={() => onFollowUp()}>
          Ask this follow up
        </Button>
      )}
      {item.references.length > 0 && (
        <details>
          <summary>Source texts ({item.references.length})</summary>
          {item.references.map((s, i) => (
            <div key={i}>
              <strong>
                {s.label}
                {s.permitted ? " · permitted" : ""}
              </strong>
              <p><MarkedText text={s.text} side="source" passages={s.permitted ? [] : item.result.passages.filter(p=>
                p.source_index === i || (p.source_index == null && p.label === s.label && item.references.filter(ref=>ref.label===s.label).length===1))}/></p>
            </div>
          ))}
        </details>
      )}
      {item.legacy && (
        <details>
          <summary>Original native record</summary>
          <pre>{JSON.stringify(item.legacy, null, 2)}</pre>
        </details>
      )}
      <ReviewWorksheet key={`worksheet:${item.id}:${item.revision}`} session={session} item={item} ordinal={index + 1}
        editorBusy={dirty || busy || conflict || !!worksheet || !!recovered} stage={stageWorksheet}
        onDenied={() => { if (worksheet) withdrawWorksheet() }} />
      {worksheet && <p role="status" className="notice">Worksheet note staged in this tab. Saving keeps the current review outcome.</p>}
      <UnlinkedDraftCopy sessionId={sessionId} afterDiscard={() => noteRef.current?.focus()} />
      {recovered && (
        <section className="notice stack" role="region" aria-label="Local draft recovery" style={{ marginTop: "12px" }}>
          <div className="spread">
            <strong>Unsaved local edits found</strong>
            <small>Saved <time dateTime={recovered.savedAt}>{formatDraftTimestamp(recovered.savedAt)}</time></small>
          </div>
          {stale && <p className="error" role="status">Server revision changed ({item.revision}) since base revision {recovered.baseRevision}.</p>}
          <div className="row">
            <Button type="button" size="sm" variant="outline" onClick={restoreLocalDraft}>Restore local edits</Button>
            <Button type="button" size="sm" variant="ghost" onClick={() => { clearLocalBuffer(); noteRef.current?.focus() }}>Discard local copy</Button>
          </div>
        </section>
      )}
      <RevisionHistory sessionId={sessionId} answerId={item.id} revision={item.revision} conflict={conflict}/>
      <form className="stack" onSubmit={save} onChange={() => setSaved(false)}>
        <div className="dual">
          <label className="field">
            Review outcome
            <select
              disabled={!!worksheet || busy || conflict}
              value={disposition}
              onChange={(e) => setDisposition(e.target.value as Disposition)}
            >
              <option value="pending">Pending review</option>
              <option value="explained">Explained</option>
              <option value="unresolved">Unresolved</option>
              <option value="disclosed">Candidate disclosed assistance</option>
            </select>
          </label>
        </div>
        <label className="field">
          Interviewer note
          <Textarea
            ref={noteRef}
            disabled={busy}
            required={disposition === "disclosed"}
            maxLength={worksheet ? 2 * MAX_NOTE_CHARACTERS : 12000 + (note.startsWith(earlierNotePrefix) ? earlierNotePrefix.length : 0)}
            aria-invalid={oversizedWorksheetNote || undefined}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="Record the candidate’s explanation and your observations."
          />
        </label>
        {conflict && <ConflictReview sessionId={sessionId} answerId={item.id} resolve={(latest, keepDraft) => {
          setItem(latest); setConflict(false); setSaved(false)
          if (!keepDraft) {
            clearLocalBuffer(); setNote(latest.note); setDisposition(latest.disposition); onSave(latest)
          }
        }} />}
        {oversizedWorksheetNote && <p role="alert">A worksheet note can contain up to 12,000 characters.</p>}
        {worksheetBlocked && <section className="notice stack" aria-label="Worksheet save reconciliation">
          <Button type="button" size="sm" variant="outline" disabled={busy} onClick={() => void reconcile(false)}>Check saved review</Button>
          {compared && <>
            <div><strong>Current saved note</strong><p className="transcript-text">{compared.answer.note || "No saved note."}</p></div>
            <p>Saved outcome: {compared.answer.disposition}</p>
            <Button type="button" size="sm" variant="outline" disabled={busy} onClick={() => void reconcile(true)}>Keep my edited note on this version</Button>
          </>}
        </section>}
        {reconcileNotice && <p role="status">{reconcileNotice}</p>}
        {error && <p role="alert" className="error">{error}</p>}
        <div className="row">
          <Button disabled={busy || conflict || worksheetBlocked || oversizedWorksheetNote || (!!worksheet && !dirty)} variant="outline">
            <ClipboardCheck />
            Save review
          </Button>
          {canAdvance && disposition !== "pending" &&
            <Button type="submit" value="next" disabled={busy || conflict || worksheetBlocked || oversizedWorksheetNote || (!!worksheet && !dirty)}>Save and review next</Button>}
          {(dirty || worksheet) && !conflict && (
            <Button
              type="button"
              variant="ghost"
              disabled={busy}
              onClick={() => {
                clearLocalBuffer(); setWorksheet(null); setSubmittedNote(null); setCompared(null); setReconcileNotice("")
                setNote(item.note); setDisposition(item.disposition)
                if (item.revision > initial.revision) onSave(item)
                setError(""); setSaved(false)
              }}
            >
              Discard review changes
            </Button>
          )}
          {saved && <small role="status">Review saved</small>}
        </div>
      </form>
    </article>
  )
}
