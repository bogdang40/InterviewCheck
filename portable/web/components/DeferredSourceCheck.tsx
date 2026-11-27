"use client"

import { useEffect, useRef, useState } from "react"
import { message } from "@/lib/api"
import { changeDeferred, readDeferred, readDeferredSource, type DeferredQuestion, type SourceReview } from "@/lib/deferredQuestions"
import { Button } from "./ui/button"

type Props = {
  sessionId: string; questionId: string; reopen?: boolean; disabled?: boolean; confirmLabel?: string
  onConfirmed: (item: DeferredQuestion, signal: AbortSignal) => Promise<void> | void
  onBusy: (busy: boolean) => void
}

export default function DeferredSourceCheck({ sessionId, questionId, reopen, disabled, confirmLabel, onConfirmed, onBusy }: Props) {
  const [review, setReview] = useState<{ item: DeferredQuestion; source: SourceReview } | null>(null)
  const [error, setError] = useState("")
  const [working, setWorking] = useState(false)
  const request = useRef<AbortController | null>(null)
  useEffect(() => () => request.current?.abort(), [])

  async function inspectOrConfirm() {
    if (disabled || request.current) return
    const controller = new AbortController()
    request.current = controller
    setWorking(true); onBusy(true); setError("")
    try {
      if (!review) {
        const item = await readDeferred(sessionId, questionId, controller.signal)
        if (item.status !== (reopen ? "dismissed" : "pending")) throw new Error("The saved question changed. Reload the list.")
        const source = await readDeferredSource(sessionId, item.parent_answer_id, controller.signal)
        if (!controller.signal.aborted) setReview({ item, source })
      } else {
        // Recheck the source the interviewer just inspected even if another tab already confirmed it.
        const latest = await readDeferredSource(sessionId, review.item.parent_answer_id, controller.signal)
        if (latest.material !== review.source.material) throw new Error("The source changed again. Inspect the current exchange.")
        const item = await readDeferred(sessionId, questionId, controller.signal)
        if (item.version !== review.item.version || item.status !== review.item.status) throw new Error("The saved question changed. Inspect it again.")
        const saved = (reopen || item.needs_reconfirmation)
          ? await changeDeferred(item, reopen ? "reopen" : "reconfirm", controller.signal, latest.material)
          : item
        if (!controller.signal.aborted) {
          await onConfirmed(saved, controller.signal)
          if (!controller.signal.aborted) setReview(null)
        }
      }
    } catch (e) {
      if (!controller.signal.aborted) { setReview(null); setError(message(e)) }
    } finally {
      if (!controller.signal.aborted) setWorking(false)
      request.current = null; onBusy(false)
    }
  }
  return <div className="stack">
    {error && <p className="error" role="alert">{error}</p>}
    {review && <section className="notice stack" aria-label="Current source exchange">
      <h4>Source exchange {review.source.ordinal}</h4>
      <p className="whitespace-pre-wrap break-words">{review.source.answer.question}</p>
      <p className="whitespace-pre-wrap break-words">{review.source.answer.answer}</p>
      <p>Question to keep: {review.item.question}</p>
    </section>}
    <div className="row flex-wrap">
      <Button type="button" size="sm" variant="outline" disabled={disabled || working} onClick={() => void inspectOrConfirm()}>
        {review ? confirmLabel ?? (reopen ? "Reopen with this source" : "Confirm current source")
          : reopen ? "Review source to reopen" : "Review current source"}
      </Button>
      {review && <Button type="button" size="sm" variant="ghost" disabled={working} onClick={() => setReview(null)}>Cancel</Button>}
    </div>
  </div>
}
