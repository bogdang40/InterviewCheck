import { useRef, useState, type FormEvent } from "react"
import dynamic from "next/dynamic"
import { Plus, Trash2, ScanText } from "lucide-react"
import { api, message, DraftConflict, type Draft, type QuestionOrigin, RevisionConflict, type Answer, type Interview, type Source } from "@/lib/api"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import { Textarea } from "./ui/textarea"
import Authoring from "./Authoring"
import LiveComparison from "./LiveComparison"
import { DraftConflictView } from "./SavedDraft"
import TranscriptImport from "./TranscriptImport"
import { noQuestionOrigin, originOf, OriginPicker } from "./QuestionLineage"
import { editorDraftKey, formatDraftTimestamp, useLocalDraftRecovery } from "@/lib/localDraftBuffer"
import { useIsomorphicLayoutEffect } from "@/lib/useIsomorphicLayoutEffect"
import UnlinkedDraftCopy from "./UnlinkedDraftCopy"

const Capture = dynamic(() => import("./Capture"), { ssr: false })
const ConflictReview = dynamic(() => import("./ConflictReview"), { ssr: false })

const emptySource = () => ({ label: "", text: "", permitted: false })
export default function AnswerEditor({
  session, onDirty, initial: original, firstQuestion = "", firstOrigin,
  draft: resumed, onDraftSaved, onSave, onCancel, embeddingAvailable,
}: {
  session: Interview
  onDirty: (id: string, value: boolean) => void
  draft?: Draft
  onDraftSaved: (saved:Draft)=>void
  firstQuestion?: string
  firstOrigin?: QuestionOrigin
  initial?: Answer
  onSave: (a: Answer) => void
  onCancel?: () => void
  embeddingAvailable?: boolean
}) {
  const [initial, setInitial] = useState(original)
  const [conflict, setConflict] = useState(false)
  const [baseline,setBaseline] = useState(resumed)
  const [draftConflict,setDraftConflict] = useState(false)
  const [id,setId] = useState(() => initial?.id || resumed?.id || crypto.randomUUID())
  const [origin, setOrigin] = useState<QuestionOrigin>(originOf(initial || resumed || firstOrigin))
  const authoringVersion = useRef(0)
  const answerField = useRef<HTMLTextAreaElement>(null)
  const [question, writeQuestion] = useState(initial?.question || resumed?.question || firstQuestion)
  const [answer, setAnswer] = useState(initial?.answer || resumed?.answer || "")
  const [sources, setSources] = useState<Source[]>(initial?.references || resumed?.references || [])
  const [capturePending, setCapturePending] = useState(false)
  const [generating, setGenerating] = useState(false)
  const [busy, setBusy] = useState("")
  const [error, setError] = useState("")
  const serverRevision = initial?.revision ?? baseline?.revision
  const savedOrigin = originOf(initial || baseline)
  const sourcesJson = JSON.stringify(sources)
  const contentDirty =
    (origin.parent_answer_id ?? null) !== (savedOrigin.parent_answer_id ?? null) ||
    (origin.planned_slot ?? null) !== (savedOrigin.planned_slot ?? null) ||
    question !== (initial?.question ?? baseline?.question ?? "") ||
    answer !== (initial?.answer ?? baseline?.answer ?? "") ||
    sourcesJson !== JSON.stringify(initial?.references ?? baseline?.references ?? [])
  const dirty = contentDirty || draftConflict || conflict || capturePending || generating || !!busy
  useIsomorphicLayoutEffect(() => {
    onDirty("editor", dirty)
    return () => onDirty("editor", false)
  }, [onDirty, dirty])
  const snapshot = JSON.stringify([question, answer, sources, origin.parent_answer_id ?? null, origin.planned_slot ?? null])
  const { recovered, clear: clearLocalBuffer, markRestored } = useLocalDraftRecovery(
    editorDraftKey(session.id, initial?.id, baseline?.id), contentDirty, snapshot,
    () => ({ text: answer, question, sources, origin, answerId: initial?.id, draftId: baseline?.id, baseRevision: serverRevision }),
    (b) => {
      if ((b.answerId && b.answerId !== initial?.id) || (b.draftId && b.draftId !== baseline?.id)) return true
      const sQ = initial?.question ?? baseline?.question ?? "", sA = initial?.answer ?? baseline?.answer ?? ""
      const sS = initial?.references ?? baseline?.references ?? [], bo = b.origin ?? savedOrigin
      return b.text === sA && (b.question ?? sQ) === sQ &&
        JSON.stringify(b.sources ?? sS) === JSON.stringify(sS) &&
        (bo.parent_answer_id ?? null) === (savedOrigin.parent_answer_id ?? null) &&
        (bo.planned_slot ?? null) === (savedOrigin.planned_slot ?? null)
    },
  )
  const restoreLocalDraft = () => {
    answerField.current?.focus()
    if (!recovered || !markRestored()) return
    authoringVersion.current += 1
    if (recovered.question !== undefined) writeQuestion(recovered.question)
    setAnswer(recovered.text)
    if (recovered.sources !== undefined) setSources(recovered.sources)
    if (recovered.origin !== undefined) setOrigin(recovered.origin)
  }
  const setQuestion = (value: string) => { authoringVersion.current += 1; writeQuestion(value) }
  const change = (index: number, update: Partial<Source>) => setSources((s) => s.map((r, i) => (i === index ? { ...r, ...update } : r)))
  async function park() {
    if(capturePending || generating || busy || draftConflict) return
    setBusy("draft");setError("")
    try{
      const saved=await api<Draft>("sessions/"+session.id+"/draft","PUT",{id,question,answer,references:sources,...origin,expected_revision:baseline?.revision??0})
      clearLocalBuffer(); onDraftSaved(saved)
    }catch(e){if(e instanceof DraftConflict)setDraftConflict(true);else setError(message(e))}finally{setBusy("")}
  }
  async function submit(e: FormEvent) {
    e.preventDefault()
    if (capturePending || generating || busy || conflict || draftConflict) return
    setBusy("save"); setError("")
    try {
      const path = baseline ? `sessions/${session.id}/draft/publish` : `sessions/${session.id}/answers` + (initial ? `/${initial.id}` : "")
      const saved = await api<Answer>(path, initial ? "PUT" : "POST", { id, question, answer, references: sources, ...origin,
        ...(initial || baseline ? { expected_revision: (initial || baseline)?.revision } : {}) })
      clearLocalBuffer(); onSave(saved)
    } catch (e) {
      if(e instanceof DraftConflict) setDraftConflict(true)
      else if (e instanceof RevisionConflict) setConflict(true)
      else setError(message(e))
    } finally { setBusy("") }
  }
  const stale = recovered && recovered.baseRevision !== undefined && recovered.baseRevision !== serverRevision
  return (
    <section className="panel form-panel">
      <div className="form-heading">
        <span className="eyebrow">CAPTURE</span>
        <h2>{initial ? "Edit exchange" : "Add an exchange"}</h2>
      </div>
      <UnlinkedDraftCopy sessionId={session.id} afterDiscard={() => answerField.current?.focus()} />
      {recovered && (
        <section className="notice stack" role="region" aria-label="Local draft recovery" style={{ marginBottom: "14px" }}>
          <div className="spread">
            <strong>Unsaved local edits found</strong>
            <small>Saved <time dateTime={recovered.savedAt}>{formatDraftTimestamp(recovered.savedAt)}</time></small>
          </div>
          {stale && <p className="error" role="status">Server revision changed ({serverRevision ?? "none"}) since base revision {recovered.baseRevision}.</p>}
          <div className="row">
            <Button type="button" size="sm" variant="outline" onClick={restoreLocalDraft}>Restore local edits</Button>
            <Button type="button" size="sm" variant="ghost" onClick={() => { clearLocalBuffer(); answerField.current?.focus() }}>Discard local copy</Button>
          </div>
        </section>
      )}
      <form className="stack" onSubmit={submit}>
        <fieldset className="editor-fields stack" disabled={!!busy}>

        <TranscriptImport
          apply={(q, a) => {
            setQuestion(q)
            setAnswer(a)
            setOrigin(noQuestionOrigin)
          }}
        />
        <OriginPicker session={session} answerId={id} origin={origin} change={(value, text) => {
          authoringVersion.current += 1
          setOrigin(value); if (text !== undefined) setQuestion(text)
        }} />
        <label className="field">
          Question
          <Textarea
            value={question}
            onChange={(e) => setQuestion(e.target.value)}
            required
            maxLength={4000}
            placeholder="What did you ask?"
          />
        </label>
        <label className="field">
          Candidate answer
          <Textarea
            ref={answerField}
            value={answer}
            onChange={(e) => setAnswer(e.target.value)}
            required
            maxLength={24000}
            rows={4}
            placeholder="Enter or import the candidate’s words."
          />
        </label>
        {!initial && (
          <Capture
            onPendingChange={setCapturePending}
            onText={(text) => setAnswer((a) => [a, text].filter(Boolean).join(" "))}
          />
        )}
        <div className="form-heading">
          <h3>Comparison sources</h3>
          <p className="muted">Add a named reference. Mark any material the candidate could use.</p>
        </div>
        {sources.map((s, i) => (
          <fieldset className="source-box stack" key={i}>
            <legend>Source {i + 1}</legend>
            <label className="field">
              Source name
              <Input
                required
                maxLength={180}
                value={s.label}
                onChange={(e) => change(i, { label: e.target.value })}
              />
            </label>
            <label className="field">
              Source passage
              <Textarea
                required
                maxLength={24000}
                value={s.text}
                onChange={(e) => change(i, { text: e.target.value })}
              />
            </label>
            <div className="spread">
              <label className="check">
                <input
                  type="checkbox"
                  checked={s.permitted}
                  onChange={(e) => change(i, { permitted: e.target.checked })}
                />
                Permitted material
              </label>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onClick={() => setSources((m) => m.filter((_, j) => i !== j))}
                aria-label={`Remove source ${i + 1}`}
              >
                <Trash2 />
              </Button>
            </div>
          </fieldset>
        ))}
        <div className="row">
          <Button
            type="button"
            variant="outline"
            size="sm"
            disabled={sources.length >= 12 || !!busy || generating}
            onClick={() => setSources((s) => [...s, emptySource()])}
          >
            <Plus />
            Add source
          </Button>
        </div>
        <Authoring
          disabled={sources.length >= 12 || !!busy}
          pending={setGenerating}
          task={{
            mode: "reference",
            id: session.id + "/" + id, role: session.role, question, version: authoringVersion, count: sources.length,
            append: incoming => setSources(list => [...list, ...incoming.slice(0, 12 - list.length)]),
          }}
        />
        <LiveComparison
          sessionId={session.id}
          question={question}
          answer={answer}
          sources={sources}
          embeddingAvailable={embeddingAvailable}
        />
        {initial && <small className="muted">An edit reopens the review and keeps the existing note.</small>}
        {capturePending && <p className="notice">Apply or discard the captured excerpt before saving.</p>}
        {conflict && initial && <ConflictReview sessionId={session.id} answerId={id} resolve={(latest, keepDraft) => {
          setInitial(latest)
          setConflict(false)
          if (!keepDraft) { clearLocalBuffer(); onSave(latest) }
        }} />}
        {error && (
          <p className="error" role="alert">
            {error}
          </p>
        )}
        {draftConflict && <DraftConflictView sessionId={session.id} resolve={(latest,keep)=>{
          setBaseline(latest??undefined);setId(latest?.id??crypto.randomUUID());setDraftConflict(false)
          if(latest && !keep){writeQuestion(latest.question);setAnswer(latest.answer);setSources(latest.references);setOrigin(originOf(latest));clearLocalBuffer()}
        }}/>}
        <div className="row">
          <Button disabled={!!busy || generating || capturePending || conflict || draftConflict}>
            <ScanText />
            {busy === "save" ? "Saving…" : "Save and compare"}
          </Button>
          {!initial && <Button type="button" variant="outline" disabled={!!busy || capturePending || generating || draftConflict ||
            !(question.trim() || answer.trim() || sources.some(s=>s.label.trim() || s.text.trim()))} onClick={park}>Save draft</Button>}
          {onCancel && (
            <Button
              type="button"
              variant="ghost"
              disabled={capturePending || generating || !!busy}
              onClick={() => {
                clearLocalBuffer()
                if (initial && original && initial.revision > original.revision) onSave(initial)
                else onCancel()
              }}
            >
              Cancel
            </Button>
          )}
        </div>
        </fieldset>
      </form>
    </section>
  )
}
