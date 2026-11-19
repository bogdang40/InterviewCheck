import { useEffect, useState } from "react"
import { api, message, type Answer, type Source } from "@/lib/api"
import { Findings } from "./Evidence"
import SemanticSimilarityPanel from "./SemanticSimilarityPanel"

export default function LiveComparison({
  sessionId,
  question,
  answer,
  sources,
  embeddingAvailable,
}: {
  sessionId: string
  question: string
  answer: string
  sources: Source[]
  embeddingAvailable?: boolean
}) {
  const [open, setOpen] = useState(false)
  const [result, setResult] = useState<Answer["result"] | null>(null)
  const [error, setError] = useState("")
  const ready = !!question.trim() && !!answer.trim() && sources.every((s) => s.label.trim() && s.text.trim())
  useEffect(() => {
    setResult(null)
    setError("")
    if (!open || !ready) return
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      api<Answer["result"]>(`sessions/${sessionId}/preview`, "POST", { question, answer, references: sources }, controller.signal)
        .then((data) => {
          if (!controller.signal.aborted) setResult(data)
        })
        .catch((e) => {
          if (!controller.signal.aborted) setError(message(e))
        })
    }, 400)
    return () => {
      window.clearTimeout(timer)
      controller.abort()
    }
  }, [open, ready, sessionId, question, answer, sources])
  return (
    <details className="import" onToggle={(e) => setOpen(e.currentTarget.open)}>
      <summary>Live comparison</summary>
      {open && (
        <>
          {result ? (
            <Findings result={result} />
          ) : (
            <p role="status" className={error ? "error" : "muted"}>
              {error ||
                (ready
                  ? "Comparing the current draft…"
                  : "Enter the question and answer. Complete each source you add.")}
            </p>
          )}
          <SemanticSimilarityPanel
            embeddingAvailable={embeddingAvailable}
            answer={answer}
            sources={sources}
          />
        </>
      )}
    </details>
  )
}
