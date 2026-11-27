"use client"

import { useEffect, useRef, useState } from "react"
import { Sparkles } from "lucide-react"
import { message, type Answer } from "@/lib/api"
import {
  formatScoringModel,
  runJudgeCheck,
  useScoringCapabilities,
  type JudgeReviewResult,
} from "@/lib/scoringHooks"
import { Button } from "./ui/button"

export default function JudgeAssist({
  sessionId,
  item,
  judgeAvailable,
  onFollowUp,
}: {
  sessionId: string
  item: Answer
  judgeAvailable?: boolean
  onFollowUp?: (questionText?: string) => void
}) {
  const capabilities = useScoringCapabilities(judgeAvailable === undefined)
  const available = judgeAvailable ?? capabilities.judge

  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const [result, setResult] = useState<JudgeReviewResult | null>(null)
  const abortRef = useRef<AbortController | null>(null)

  useEffect(() => () => abortRef.current?.abort(), [])

  if (available !== true) return null
  if (item.result.status !== "match" || !item.result.passages.length || result?.status === "insufficient_evidence") {
    return <p className="muted" role="status">No eligible passage for AI review. This check sends no text to a model.</p>
  }

  async function evaluate() {
    abortRef.current?.abort()
    const controller = new AbortController()
    abortRef.current = controller
    setBusy(true)
    setError("")
    setResult(null)
    try {
      const data = await runJudgeCheck(sessionId, item, controller.signal)
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

  return (
    <section
      className="judge-assist stack my-4 rounded-lg border border-[var(--line)] bg-[var(--subtle)] p-4"
      aria-label="AI review check"
    >
      <div className="spread flex-wrap gap-2">
        <span className="eyebrow">AI follow up questions</span>
        <Button
          type="button"
          variant="outline"
          size="sm"
          className="border-[var(--icon)] bg-[var(--surface)]"
          disabled={busy}
          onClick={evaluate}
        >
          <Sparkles size={15} aria-hidden="true" />
          {busy ? "Generating questions…" : "Suggest questions"}
        </Button>
      </div>
      <p className="muted">Sends the interview question and the matched excerpts to the connected model.</p>
      {busy && <p role="status" className="muted">Generating questions…</p>}
      {error && (
        <p role="alert" className="error">
          {error}
        </p>
      )}
      {result && !busy && (
        <div className="stack gap-3">
          <small className="muted">{formatScoringModel(result.provider, result.model)}</small>
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
          {onFollowUp && <small className="muted">Choose a question to open a draft.</small>}
        </div>
      )}
    </section>
  )
}
