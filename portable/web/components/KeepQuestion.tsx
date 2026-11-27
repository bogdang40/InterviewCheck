"use client"

import { useCallback, useEffect, useRef, useState } from "react"
import { message, type Answer, type Interview } from "@/lib/api"
import { ApiError } from "@/lib/http"
import { useReportDirty, type DirtyReporter } from "@/lib/dirtyTracking"
import { accessLost, checkDeferredCreation, keepDeferred } from "@/lib/deferredQuestions"
import { currentWorksheet } from "@/lib/reviewWorksheet"
import { Button } from "./ui/button"
import { Textarea } from "./ui/textarea"

type Props = { session: Interview; parent: Answer; ordinal: number; disabled: boolean; onDirty: DirtyReporter; onSaved: () => void; onUnavailable: () => void }

export default function KeepQuestion({ session, parent, ordinal, disabled, onDirty, onSaved, onUnavailable }: Props) {
  const [custom, setCustom] = useState(false)
  const [value, setValue] = useState("")
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const [uncertain, setUncertain] = useState(false)
  const [matchingText, setMatchingText] = useState<string | null>(null)
  const [savedText, setSavedText] = useState<string | null>(null)
  const operation = useRef<{ id: string; text: string; material: string } | null>(null)
  const abort = useRef<AbortController | null>(null)
  const text = custom ? value.trim() : parent.result.follow_up
  const saved = savedText === text
  const clear = useCallback(() => { operation.current = null; setUncertain(false); setError(""); setSavedText(null); setMatchingText(null) }, [])
  useEffect(() => () => abort.current?.abort(), [])
  useReportDirty(busy || uncertain || (custom && !!value.trim() && !saved && matchingText !== text), onDirty)

  function acknowledge(confirmed: string) {
    operation.current = null
    setUncertain(false); setSavedText(confirmed); setError(""); onSaved()
  }
  async function keep(checkOnly = false) {
    if (disabled || !text || abort.current) return
    const controller = new AbortController()
    abort.current = controller
    setBusy(true); setError("")
    try {
      if (!operation.current) {
        const source = await currentWorksheet(session, parent, ordinal, controller.signal)
        operation.current = { id: crypto.randomUUID(), text, material: source.material }
      }
      const { id, text: queued, material } = operation.current
      if (checkOnly || uncertain) {
        const check = await checkDeferredCreation(session.id, id, parent.id, queued, material, controller.signal)
        if (controller.signal.aborted) return
        if (check.outcome === "confirmed") { acknowledge(queued); return }
        if (check.outcome === "matching_unconfirmed") {
          // Whole-workspace JSON can recreate this ID and text without the original receipt.
          operation.current = null; setMatchingText(queued); setUncertain(false); setError(""); onSaved()
          return
        }
        if (check.outcome === "mismatch") throw new Error("This ID belongs to a different saved question. Inspect the list.")
        if (checkOnly) throw new Error("This Keep request has no saved item. Retry the same question to submit it.")
      }
      await keepDeferred(session.id, id, parent.id, queued, material, controller.signal)
      if (!controller.signal.aborted) acknowledge(queued)
    } catch (e) {
      if (!controller.signal.aborted) {
        if (accessLost(e)) { operation.current = null; onUnavailable(); return }
        const rejected = e instanceof ApiError && [400, 401, 402, 403, 409, 422].includes(e.status)
        if (rejected && !uncertain && !checkOnly) operation.current = null
        setUncertain(!!operation.current)
        setError(message(e))
      }
    } finally {
      if (!controller.signal.aborted) setBusy(false)
      abort.current = null
    }
  }
  return <section className="stack" aria-label="Keep a question">
    <h4>Follow up to exchange {ordinal}</h4>
    {custom ? <label className="field">Question to keep
      <Textarea value={value} maxLength={4000} rows={2} disabled={busy || uncertain} onChange={e => { clear(); setValue(e.target.value) }} />
    </label> : <p className="whitespace-pre-wrap break-words">{parent.result.follow_up}</p>}
    <div className="row flex-wrap">
      <Button size="sm" type="button" disabled={disabled || busy || !text || saved || matchingText === text} onClick={() => void keep()}>
        {uncertain ? "Retry same question" : "Keep for later"}
      </Button>
      {uncertain && <Button variant="outline" size="sm" type="button" disabled={busy} onClick={() => void keep(true)}>Check saved question</Button>}
      {uncertain && <Button variant="ghost" size="sm" type="button" disabled={busy}
        onClick={() => { clear(); setValue(""); setCustom(false) }}>Discard local entry</Button>}
      {!uncertain && <Button variant="ghost" size="sm" type="button" disabled={disabled || busy}
        onClick={() => { clear(); setValue(""); setCustom(!custom) }}>
        {custom ? "Use suggested question" : "Write a different question"}
      </Button>}
    </div>
    {savedText !== null && <p role="status">{saved ? "Question kept for later."
      : "Your earlier question was kept. Review the current suggestion before adding it."}</p>}
    {matchingText !== null && <p role="status">A matching saved question exists. Its original Keep receipt is unavailable.
      Inspect the question and its source in the list below.</p>}
    {uncertain && <p role="status">The save is unconfirmed. Check the saved question or retry the same request.</p>}
    {error && <p className="error" role="alert">{error}</p>}
  </section>
}
