import { useState, type FormEvent } from "react"
import { ClipboardCheck, Pencil, Quote } from "lucide-react"
import { api, message, statusText, type Answer, type Disposition } from "@/lib/api"
import { Button } from "./ui/button"
import { Textarea } from "./ui/textarea"

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
  item,
  index,
  sessionId,
  onSave,
  onEdit,
}: {
  item: Answer
  index: number
  sessionId: string
  onSave: (a: Answer) => void
  onEdit?: () => void
}) {
  const [note, setNote] = useState(item.note)
  const [disposition, setDisposition] = useState<Disposition>(item.disposition)
  const [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [saved, setSaved] = useState(false)
  async function save(e: FormEvent) {
    e.preventDefault()
    setError("")
    setBusy(true)
    try {
      onSave(await api<Answer>(`sessions/${sessionId}/answers/${item.id}`, "PATCH", { note, disposition }))
      setSaved(true)
    } catch (e) {
      setError(message(e))
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
      <p className="transcript-text">{item.answer}</p>
      <Findings result={item.result} />
      {item.references.length > 0 && (
        <details>
          <summary>Source texts ({item.references.length})</summary>
          {item.references.map((s, i) => (
            <div key={i}>
              <strong>
                {s.label}
                {s.permitted ? " · permitted" : ""}
              </strong>
              <p>{s.text}</p>
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
      <form className="stack" onSubmit={save} onChange={() => setSaved(false)}>
        <div className="dual">
          <label className="field">
            Review outcome
            <select value={disposition} onChange={(e) => setDisposition(e.target.value as Disposition)}>
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
            required={disposition === "disclosed"}
            maxLength={12000}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="Record the candidate’s explanation and your observations."
          />
        </label>
        {error && (
          <p role="alert" className="error">
            {error}
          </p>
        )}
        <div className="row">
          <Button disabled={busy} variant="outline">
            <ClipboardCheck />
            Save review
          </Button>
          {saved && <small role="status">Review saved</small>}
        </div>
      </form>
    </article>
  )
}
