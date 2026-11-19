"use client"

import { useEffect, useRef, useState } from "react"
import { Sparkles } from "lucide-react"
import { message, type Source } from "@/lib/api"
import {
  formatScoringModel,
  runSemanticSimilarity,
  useScoringCapabilities,
  type SemanticScoreResult,
} from "@/lib/scoringHooks"
import { Button } from "./ui/button"

export default function SemanticSimilarityPanel({
  embeddingAvailable,
  answer,
  sources,
}: {
  embeddingAvailable?: boolean
  answer: string
  sources: Source[]
}) {
  const capabilities = useScoringCapabilities(embeddingAvailable === undefined)
  const available = embeddingAvailable ?? capabilities.embedding
  const eligible =
    available === true &&
    !!answer.trim() &&
    sources.some((s) => s.permitted === false && !!s.label.trim() && !!s.text.trim())

  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const [result, setResult] = useState<SemanticScoreResult | null>(null)
  const abortRef = useRef<AbortController | null>(null)
  const sourceKey = JSON.stringify(sources)

  useEffect(() => {
    abortRef.current?.abort()
    abortRef.current = null
    setBusy(false)
    setError("")
    setResult(null)
  }, [answer, sourceKey])

  useEffect(() => () => abortRef.current?.abort(), [])

  if (!eligible) return null

  async function check() {
    abortRef.current?.abort()
    const controller = new AbortController()
    abortRef.current = controller
    setBusy(true)
    setError("")
    try {
      const data = await runSemanticSimilarity(answer, sources, controller.signal)
      if (!controller.signal.aborted) {
        setResult(data)
      }
    } catch (e) {
      if (!controller.signal.aborted) {
        setError(message(e))
      }
    } finally {
      if (!controller.signal.aborted) {
        setBusy(false)
      }
    }
  }

  const modelLabel = result ? formatScoringModel(result.provider, result.model) : ""

  return (
    <div className="semantic-panel stack mt-3 border-t border-[var(--line)] pt-3">
      <div className="row">
        <Button type="button" variant="outline" size="sm" disabled={busy} onClick={check}>
          <Sparkles size={15} aria-hidden="true" />
          {busy ? "Checking similarity…" : "Check semantic similarity"}
        </Button>
      </div>
      {busy && (
        <p role="status" className="muted">
          Checking semantic similarity…
        </p>
      )}
      {error && (
        <p role="alert" className="error">
          {error}
        </p>
      )}
      {result && !busy && (
        <div className="stack gap-2 rounded-md border border-[var(--line)] bg-[var(--surface)] p-3">
          <div className="spread flex-wrap gap-2">
            <span className="eyebrow">SEMANTIC SIMILARITY</span>
            {modelLabel && <small className="muted">{modelLabel}</small>}
          </div>
          {!result.available ? (
            <p className="muted">{result.reason || "Semantic similarity unavailable."}</p>
          ) : (
            <ul className="m-0 list-none space-y-1.5 p-0 text-sm">
              {result.matches.map((match) => (
                <li
                  key={`${match.source_index}-${match.label}`}
                  className="flex flex-wrap items-baseline justify-between gap-2 border-b border-[var(--line)] pb-1 last:border-b-0 last:pb-0"
                >
                  <span className="min-w-0 break-words">{match.label}</span>
                  <span className="font-mono text-xs text-[var(--green-ink)]">
                    {match.cosine.toFixed(3)}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </div>
  )
}
