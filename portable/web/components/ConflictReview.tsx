import { useState } from "react"
import { api, message, type Answer } from "@/lib/api"
import { Button } from "./ui/button"

export default function ConflictReview({
  sessionId,
  answerId,
  resolve,
}: {
  sessionId: string
  answerId: string
  resolve: (latest: Answer, keepDraft: boolean) => void
}) {
  const [latest, setLatest] = useState<Answer>()
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState("")
  async function reload() {
    setLoading(true)
    setError("")
    try {
      setLatest(await api<Answer>(`sessions/${sessionId}/answers/${answerId}`))
    } catch (error) {
      setError(message(error))
    } finally {
      setLoading(false)
    }
  }
  return (
    <section className="notice stack" aria-label="Conflicting edits">
      <p role="alert">This exchange changed in another view. Your draft is still here.</p>
      {!latest ? (
        <Button type="button" variant="outline" disabled={loading} onClick={reload}>
          {loading ? "Loading…" : "Reload saved exchange"}
        </Button>
      ) : (
        <>
          <div>
            <strong>Saved revision {latest.revision}</strong>
            <p>{latest.question}</p>
            <p className="transcript-text">{latest.answer}</p>
            {latest.references.map((source, i) => (
              <details key={i}>
                <summary>
                  {source.label} {source.permitted ? "(permitted)" : ""}
                </summary>
                <p>{source.text}</p>
              </details>
            ))}
            <p>Review outcome: {latest.disposition}</p>
            <p className="transcript-text">{latest.note || "No saved interviewer note."}</p>
          </div>
          <p>Compare the saved version with your draft before saving again.</p>
          <div className="row">
            <Button type="button" variant="outline" onClick={() => resolve(latest, true)}>
              Keep editing my draft
            </Button>
            <Button type="button" variant="ghost" onClick={() => resolve(latest, false)}>
              Discard draft and use saved version
            </Button>
          </div>
        </>
      )}
      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
    </section>
  )
}
