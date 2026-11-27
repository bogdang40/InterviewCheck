"use client"

import { useEffect, useId, useState } from "react"
import { Button } from "@/components/ui/button"
import { AdminApiError } from "@/lib/adminModels"
import { getSavedReviewRehearsal, type RehearsalCase } from "@/lib/savedReviewRehearsal"

export default function SavedReviewRehearsal({ onAuthInvalid }: { onAuthInvalid: (message: string) => void }) {
  const [open, setOpen] = useState(false)
  const [cases, setCases] = useState<RehearsalCase[]>([])
  const [caseId, setCaseId] = useState("brief")
  const [scriptId, setScriptId] = useState("anchored")
  const [retry, setRetry] = useState(0)
  const [error, setError] = useState("")
  const caseInput = useId()
  const scriptInput = useId()
  useEffect(() => {
    if (!open) return
    const controller = new AbortController()
    setError("")
    getSavedReviewRehearsal(controller.signal).then(items => {
      if (!controller.signal.aborted) setCases(items)
    }).catch(err => {
      if (controller.signal.aborted) return
      setCases([])
      if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) onAuthInvalid(err.message)
      else setError(err instanceof Error ? err.message : "Could not load the rehearsal examples.")
    })
    return () => controller.abort()
  }, [open, retry, onAuthInvalid])
  const selected = cases.find(item => item.id === caseId) ?? cases[0]
  const script = selected?.scripts.find(item => item.id === scriptId) ?? selected?.scripts[0]
  return <details className="panel inset" onToggle={event => {
    const expanded = event.currentTarget.open
    setOpen(expanded)
    if (!expanded) setCases([])
  }}>
    <summary>Rehearse saved review</summary>
    {open && <div className="stack pt-3">
      <p className="muted">Inspect a fictional exchange and the follow up a reviewer would see. The rehearsal uses scripted replies and makes zero provider calls.</p>
      {error && <div><p role="alert" className="error">{error}</p><Button type="button" variant="outline" onClick={() => setRetry(n => n + 1)}>Reload examples</Button></div>}
      {!selected && !error && <p role="status">Loading examples...</p>}
      {selected && <>
        <div className="field"><label htmlFor={caseInput}>Fictional case</label>
          <select id={caseInput} value={selected.id} onChange={event => { setCaseId(event.target.value); setScriptId("anchored") }}>
            {cases.map(item => <option key={item.id} value={item.id}>{item.label}</option>)}
          </select>
        </div>
        <article className="panel inset stack" aria-label="Fictional exchange">
          <h3>{selected.question}</h3>
          <p className="whitespace-pre-wrap break-words">{selected.answer}</p>
          <small>{selected.notice ? "Candidate notice recorded" : "Candidate notice unrecorded"}</small>
        </article>
        <p>{selected.gate === "notice_required" ? "Saved review requires recorded notice before sending excerpts." : selected.explanation}</p>
        {selected.payload && <details key={selected.id} className="import">
          <summary>Show transfer payload</summary>
          <p className="muted">A reviewer would have to choose Suggest questions to send these fields to the connected model.</p>
          <pre className="whitespace-pre-wrap break-words">{JSON.stringify(selected.payload, null, 2)}</pre>
        </details>}
        {script && <>
          <div className="field"><label htmlFor={scriptInput}>Scripted reply</label>
            <select id={scriptInput} value={script.id} onChange={event => setScriptId(event.target.value)}>
              {selected.scripts.map(item => <option key={item.id} value={item.id}>{item.label}</option>)}
            </select>
          </div>
          <details key={selected.id + script.id} className="import"><summary>Show scripted reply</summary>
            <pre className="whitespace-pre-wrap break-words">{JSON.stringify(script.reply, null, 2)}</pre>
          </details>
        </>}
        <section aria-label="Reviewer result" className="panel inset stack" aria-live="polite">
          <h3>{!selected.payload ? "Local follow up" : script?.questions.length ? "Suggested follow up" : "Unusable model suggestion"}</h3>
          {!selected.payload && <p>Saved review keeps this exchange local.</p>}
          {selected.payload && !script?.questions.length && <p>The reply contains no usable question anchored to this passage. The saved local question remains available.</p>}
          {script?.questions.length ? <ul className="list-disc pl-5">{script.questions.map(q => <li key={q}>{q}</li>)}</ul>
            : <p className="break-words">{selected.local_question}</p>}
        </section>
      </>}
    </div>}
  </details>
}
