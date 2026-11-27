"use client"

import { useEffect, useRef, useState } from "react"
import { message } from "@/lib/api"
import { ApiError } from "@/lib/http"
import { accessLost, changeDeferred, readDeferred, readDeferredSource, type DeferredQuestion, type SourceReview } from "@/lib/deferredQuestions"
import { Button } from "./ui/button"

type Props = {
  sessionId: string; questionId: string; reopen?: boolean; disabled?: boolean; confirmLabel?: string
  onConfirmed: (item: DeferredQuestion, signal: AbortSignal) => Promise<void> | void
  onBusy: (busy: boolean) => void; onUnavailable: () => void
}

export default function DeferredSourceCheck({ sessionId, questionId, reopen, disabled, confirmLabel, onConfirmed, onBusy, onUnavailable }: Props) {
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
        let saved = item
        if (reopen || item.needs_reconfirmation) {
          try {
            saved = await changeDeferred(item, reopen ? "reopen" : "reconfirm", controller.signal, latest.material)
          } catch (e) {
            if (controller.signal.aborted || e instanceof ApiError && e.status < 500 && e.status !== 409) throw e
            // A PATCH acknowledgement can be lost after the write. Recover by reading
            // the exact item and the material inspected, without a second write.
            const stored = await readDeferred(sessionId, questionId, controller.signal)
            const current = await readDeferredSource(sessionId, review.item.parent_answer_id, controller.signal)
            if (stored.status !== "pending" || stored.needs_reconfirmation || stored.version === item.version ||
                stored.parent_answer_id !== item.parent_answer_id || stored.question !== item.question ||
                current.material !== review.source.material) throw e
            saved = stored
          }
        }
        if (!controller.signal.aborted) {
          await onConfirmed(saved, controller.signal)
          if (!controller.signal.aborted) setReview(null)
        }
      }
    } catch (e) {
      if (!controller.signal.aborted) {
        setReview(null)
        if (accessLost(e)) onUnavailable()
        else setError(message(e))
      }
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
      <h5>Saved comparison finding</h5>
      <p>{review.source.answer.result.status === "match" ? "Passage match" :
        review.source.answer.result.status === "no_match" ? "No passage match" : "Limited evidence"}</p>
      <p className="whitespace-pre-wrap break-words">{review.source.answer.result.explanation}</p>
      {review.source.answer.result.passages.length ? <ol>{review.source.answer.result.passages.map((passage, index) =>
        <li key={index} className="stack">
          <strong>{passage.label} · {passage.words} matched words</strong>
          <span>Answer excerpt</span><blockquote className="whitespace-pre-wrap break-words">{passage.answer_excerpt}</blockquote>
          <span>Source excerpt</span><blockquote className="whitespace-pre-wrap break-words">{passage.source_excerpt}</blockquote>
        </li>)}</ol> : <p className="muted">No matched passages were recorded.</p>}
      <p>Suggested follow up: {review.source.answer.result.follow_up}</p>
      <h5>Resource policy</h5>
      <p className="whitespace-pre-wrap break-words">{review.source.session.policy}</p>
      <h5>Exchange sources</h5>
      {review.source.answer.references.length ? <ul>{review.source.answer.references.map((r, i) => <li key={i}>
        <details><summary className="break-words">{r.label} · {r.permitted ? "Permitted" : "Comparison only"}</summary>
          <p className="whitespace-pre-wrap break-words">{r.text}</p></details>
      </li>)}</ul> : <p className="muted">No exchange sources.</p>}
      <h5>Interview permitted materials</h5>
      {review.source.session.permitted_sources.length ? <ul>{review.source.session.permitted_sources.map((r, i) => <li key={i}>
        <details><summary className="break-words">{r.label}</summary><p className="whitespace-pre-wrap break-words">{r.text}</p></details>
      </li>)}</ul> : <p className="muted">No permitted materials recorded.</p>}
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
