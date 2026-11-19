import { useEffect, useState, type FormEvent } from "react"
import { ClipboardCheck, Pencil, Quote } from "lucide-react"
import { api, message, RevisionConflict, statusText, type Answer, type Disposition } from "@/lib/api"
import CandidateResponse from "./CandidateResponse"
import MarkedText from "./MarkedText"
import RevisionHistory from "./RevisionHistory"
import ConflictReview from "./ConflictReview"
import { Button } from "./ui/button"
import { Textarea } from "./ui/textarea"

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
  sessionId,
  onSave,
  onEdit,
  onDirty,
  onFollowUp,
  canAdvance,
}: {
  item: Answer
  index: number
  sessionId: string
  onSave: (a: Answer, advance?: boolean) => void
  canAdvance?: boolean
  onFollowUp?: () => void
  onDirty: (id: string, value: boolean) => void
  onEdit?: () => void
}) {
  const [item, setItem] = useState(initial)
  const [conflict, setConflict] = useState(false)
  const [note, setNote] = useState(item.note)
  const [disposition, setDisposition] = useState<Disposition>(item.disposition)
  const [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [saved, setSaved] = useState(false)
  const dirty = note !== item.note || disposition !== item.disposition
  useEffect(() => {
    if (!dirty && !busy && !conflict && initial.revision > item.revision) {
      setItem(initial)
      setNote(initial.note)
      setDisposition(initial.disposition)
      setSaved(false)
    }
  }, [initial, item.revision, dirty, busy, conflict])
  useEffect(() => {
    onDirty(item.id, dirty || busy || conflict)
    return () => onDirty(item.id, false)
  }, [item.id, dirty, busy, conflict, onDirty])
  async function save(e: FormEvent) {
    e.preventDefault()
    if (busy || conflict) return
    const submitter = (e.nativeEvent as SubmitEvent).submitter
    const advance = !!canAdvance && disposition !== "pending" && submitter?.getAttribute("value") === "next"
    setError("")
    setBusy(true)
    try {
      const result = await api<Answer>(`sessions/${sessionId}/answers/${item.id}`, "PATCH", {
        note, disposition, expected_revision: item.revision,
      })
      setItem(result)
      setNote(result.note)
      setDisposition(result.disposition)
      onSave(result, advance)
      setSaved(true)
    } catch (e) {
      if (e instanceof RevisionConflict) setConflict(true)
      else setError(message(e))
    } finally {
      setBusy(false)
    }
  }
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
      {onFollowUp && (
        <Button variant="outline" size="sm" onClick={onFollowUp}>
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
      <RevisionHistory sessionId={sessionId} answerId={item.id} revision={item.revision} conflict={conflict}/>
      <form className="stack" onSubmit={save} onChange={() => setSaved(false)}>
        <div className="dual">
          <label className="field">
            Review outcome
            <select
              disabled={busy}
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
            disabled={busy}
            required={disposition === "disclosed"}
            maxLength={12000 + (note.startsWith(earlierNotePrefix) ? earlierNotePrefix.length : 0)}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="Record the candidate’s explanation and your observations."
          />
        </label>
        {conflict && <ConflictReview sessionId={sessionId} answerId={item.id} resolve={(latest, keepDraft) => {
          setItem(latest)
          setConflict(false)
          setSaved(false)
          if (!keepDraft) {
            setNote(latest.note)
            setDisposition(latest.disposition)
            onSave(latest)
          }
        }} />}
        {error && (
          <p role="alert" className="error">
            {error}
          </p>
        )}
        <div className="row">
          <Button disabled={busy || conflict} variant="outline">
            <ClipboardCheck />
            Save review
          </Button>
          {canAdvance && disposition !== "pending" &&
            <Button type="submit" value="next" disabled={busy || conflict}>Save and review next</Button>}
          {dirty && !conflict && (
            <Button
              type="button"
              variant="ghost"
              disabled={busy}
              onClick={() => {
                setNote(item.note)
                setDisposition(item.disposition)
                if (item.revision > initial.revision) onSave(item)
                setError("")
                setSaved(false)
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
