import { useEffect, useState, type FormEvent } from "react"
import { Plus, Trash2, ScanText } from "lucide-react"
import { api, message, type Answer, type Interview, type Source } from "@/lib/api"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import { Textarea } from "./ui/textarea"
import Authoring from "./Authoring"
import LiveComparison from "./LiveComparison"
import Capture from "./Capture"
import TranscriptImport from "./TranscriptImport"

const emptySource = () => ({ label: "", text: "", permitted: false })
export default function AnswerEditor({
  session,
  onDirty,
  initial,
  firstQuestion = "",
  onSave,
  onCancel,
}: {
  session: Interview
  onDirty: (id: string, value: boolean) => void
  firstQuestion?: string
  initial?: Answer
  onSave: (a: Answer) => void
  onCancel?: () => void
}) {
  const [id] = useState(() => initial?.id || crypto.randomUUID())
  const [question, setQuestion] = useState(initial?.question || firstQuestion)
  const [answer, setAnswer] = useState(initial?.answer || "")
  const [sources, setSources] = useState<Source[]>(initial?.references || [])
  const [capturePending, setCapturePending] = useState(false)
  const [generating, setGenerating] = useState(false)
  const [busy, setBusy] = useState("")
  const [error, setError] = useState("")
  const dirty =
    question !== (initial?.question ?? "") ||
    answer !== (initial?.answer ?? "") ||
    JSON.stringify(sources) !== JSON.stringify(initial?.references ?? []) ||
    capturePending ||
    generating ||
    !!busy
  useEffect(() => {
    onDirty("editor", dirty)
    return () => onDirty("editor", false)
  }, [onDirty, dirty])
  function change(index: number, update: Partial<Source>) {
    setSources((s) => s.map((r, i) => (i === index ? { ...r, ...update } : r)))
  }
  async function submit(e: FormEvent) {
    e.preventDefault()
    if (capturePending || generating || busy) return
    setBusy("save")
    setError("")
    try {
      const path = `sessions/${session.id}/answers` + (initial ? `/${initial.id}` : "")
      onSave(await api<Answer>(path, initial ? "PUT" : "POST", { id, question, answer, references: sources }))
    } catch (e) {
      setError(message(e))
    } finally {
      setBusy("")
    }
  }
  return (
    <section className="panel form-panel">
      <div className="form-heading">
        <span className="eyebrow">CAPTURE</span>
        <h2>{initial ? "Edit exchange" : "Add an exchange"}</h2>
      </div>
      <form className="stack" onSubmit={submit}>
        <TranscriptImport
          apply={(q, a) => {
            setQuestion(q)
            setAnswer(a)
          }}
        />
        {session.planned_questions.length > 0 && (
          <label className="field">
            Planned question
            <select defaultValue="" onChange={(e) => setQuestion(e.target.value)}>
              <option value="">Choose a question</option>
              {session.planned_questions.map((q, i) => (
                <option key={i}>{q}</option>
              ))}
            </select>
          </label>
        )}
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
            disabled={sources.length >= 12 || !!busy}
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
            inputs: () => ({ role: session.role, question }),
            append: (s) => setSources((list) => [...list, s]),
          }}
        />
        <LiveComparison question={question} answer={answer} sources={sources} />
        {initial && <small className="muted">An edit reopens the review and keeps the existing note.</small>}
        {capturePending && <p className="notice">Apply or discard the captured excerpt before saving.</p>}
        {error && (
          <p className="error" role="alert">
            {error}
          </p>
        )}
        <div className="row">
          <Button disabled={!!busy || generating || capturePending}>
            <ScanText />
            {busy === "save" ? "Saving…" : "Save and compare"}
          </Button>
          {onCancel && (
            <Button
              type="button"
              variant="ghost"
              disabled={capturePending || generating || !!busy}
              onClick={onCancel}
            >
              Cancel
            </Button>
          )}
        </div>
      </form>
    </section>
  )
}
