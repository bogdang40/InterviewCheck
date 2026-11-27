"use client"

import { useCallback, useEffect, useRef, useState } from "react"
import { message, type Answer, type Interview } from "@/lib/api"
import { ApiError } from "@/lib/http"
import { useReportDirty, type DirtyReporter } from "@/lib/dirtyTracking"
import { keepDeferred, readDeferred } from "@/lib/deferredQuestions"
import { currentWorksheet } from "@/lib/reviewWorksheet"
import { Button } from "./ui/button"
import { Textarea } from "./ui/textarea"

type Props = { session: Interview; parent: Answer; ordinal: number; disabled: boolean; onDirty: DirtyReporter; onSaved: () => void }

export default function KeepQuestion({ session, parent, ordinal, disabled, onDirty, onSaved }: Props) {
  const [custom, setCustom] = useState(false)
  const [value, setValue] = useState("")
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const [uncertain, setUncertain] = useState(false)
  const [savedText, setSavedText] = useState<string | null>(null)
  const operation = useRef<{ id: string; text: string; material: string } | null>(null)
  const abort = useRef<AbortController | null>(null)
  const text = custom ? value.trim() : parent.result.follow_up
  const saved = savedText === text
  const clear = useCallback(() => { operation.current = null; setUncertain(false); setError(""); setSavedText(null) }, [])
  useEffect(() => () => abort.current?.abort(), [])
  useReportDirty(busy || uncertain || (custom && !!value.trim() && !saved), onDirty)

  function acknowledge() {
    operation.current = null
    setUncertain(false); setSavedText(text); setError(""); onSaved()
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
      if (checkOnly) {
        const stored = await readDeferred(session.id, id, controller.signal)
        if (stored.parent_answer_id !== parent.id || stored.question !== queued) throw new Error("The stored item does not match this question.")
      } else {
        await keepDeferred(session.id, id, parent.id, queued, material, controller.signal)
      }
      if (!controller.signal.aborted) acknowledge()
    } catch (e) {
      if (!controller.signal.aborted) {
        const rejected = e instanceof ApiError && [400, 401, 402, 403, 409, 422].includes(e.status)
        if (rejected && !checkOnly) operation.current = null
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
      <Button size="sm" type="button" disabled={disabled || busy || !text || saved} onClick={() => void keep()}>
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
    {saved && <p role="status">Question kept for later.</p>}
    {uncertain && <p role="status">The save is unconfirmed. Check the saved question or retry the same request.</p>}
    {error && <p className="error" role="alert">{error}</p>}
  </section>
}
