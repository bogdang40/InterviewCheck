"use client"

import { useEffect, useRef, useState } from "react"
import { Sparkles } from "lucide-react"
import { message, type Answer } from "@/lib/api"
import {
  formatScoringModel,
  runJudgeCheck,
  useScoringCapabilities,
  type JudgeConfidence,
  type JudgeScoreResult,
} from "@/lib/scoringHooks"
import { Badge } from "./ui/badge"
import { Button } from "./ui/button"

function confidenceVariant(confidence: JudgeConfidence) {
  if (confidence === "high") return "default" as const
  if (confidence === "medium") return "warning" as const
  return "secondary" as const
}

export default function JudgeAssist({
  item,
  judgeAvailable,
  onFollowUp,
}: {
  item: Answer
  judgeAvailable?: boolean
  onFollowUp?: (questionText?: string) => void
}) {
  const capabilities = useScoringCapabilities(judgeAvailable === undefined)
  const available = judgeAvailable ?? capabilities.judge

  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const [result, setResult] = useState<JudgeScoreResult | null>(null)
  const abortRef = useRef<AbortController | null>(null)

  useEffect(() => {
    abortRef.current?.abort()
    abortRef.current = null
    setBusy(false)
    setError("")
    setResult(null)
  }, [item.id, item.revision])

  useEffect(() => () => abortRef.current?.abort(), [])

  if (available !== true) return null

  async function evaluate() {
    abortRef.current?.abort()
    const controller = new AbortController()
    abortRef.current = controller
    setBusy(true)
    setError("")
    try {
      const data = await runJudgeCheck(item, controller.signal)
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
    <section
      className="judge-assist stack my-4 rounded-lg border border-[var(--line)] bg-[var(--subtle)] p-4"
      aria-label="AI review check"
    >
      <div className="spread flex-wrap gap-2">
        <span className="eyebrow">AI REVIEW CHECK</span>
        <Button
          type="button"
          variant="outline"
          size="sm"
          className="border-[var(--icon)] bg-[var(--surface)]"
          disabled={busy}
          onClick={evaluate}
        >
          <Sparkles size={15} aria-hidden="true" />
          {busy ? "Running AI review check…" : "Run AI review check"}
        </Button>
      </div>
      {busy && (
        <p role="status" className="muted">
          Running AI review check…
        </p>
      )}
      {error && (
        <p role="alert" className="error">
          {error}
        </p>
      )}
      {result && !busy && (
        <div className="stack gap-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="flex flex-wrap items-center gap-2">
              <span className="text-sm font-semibold">
                Assistance likelihood: {result.likelihood}%
              </span>
              <Badge variant={confidenceVariant(result.confidence)} aria-label={`Confidence: ${result.confidence}`}>
                {result.confidence}
              </Badge>
            </div>
            {modelLabel && <small className="muted">{modelLabel}</small>}
          </div>
          {result.evidence.length > 0 && (
            <div>
              <span className="small-label">Evidence</span>
              <ul className="mt-1 mb-0 list-disc space-y-1 pl-5 text-sm">
                {result.evidence.map((point, idx) => (
                  <li key={idx} className="break-words">
                    {point}
                  </li>
                ))}
              </ul>
            </div>
          )}
          {result.follow_up_questions.length > 0 && (
            <div className="stack gap-2">
              <span className="small-label">Suggested follow-ups</span>
              <div className="flex flex-col items-start gap-2">
                {result.follow_up_questions.map((questionText, idx) => (
                  <Button
                    key={idx}
                    type="button"
                    variant="outline"
                    size="sm"
                    className="h-auto max-w-full justify-start whitespace-normal border-[var(--icon)] bg-[var(--surface)] py-1.5 text-left"
                    disabled={!onFollowUp}
                    onClick={() => onFollowUp?.(questionText)}
                  >
                    {questionText}
                  </Button>
                ))}
              </div>
            </div>
          )}
          <small className="muted">Advisory only. Review outcome and note are saved only when you save.</small>
        </div>
      )}
    </section>
  )
}
