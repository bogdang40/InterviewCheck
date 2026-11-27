"use client"

import { useEffect, useRef, useState } from "react"
import { api, message, type Answer, type Draft, type Interview } from "@/lib/api"
import { useReportDirty, type DirtyReporter } from "@/lib/dirtyTracking"
import { accessLost, changeDeferred, deferredStates, listDeferred, matchesDeferredDraft, saveDeferredDraft,
  type DeferredFilter, type DeferredPage, type DeferredQuestion } from "@/lib/deferredQuestions"
import { Button } from "./ui/button"
import DeferredSourceCheck from "./DeferredSourceCheck"
import KeepQuestion from "./KeepQuestion"

type Props = {
  detailsRef: (node: HTMLDetailsElement | null) => void; session: Interview; parent?: Answer; locked: boolean; onDirty: DirtyReporter
  onUnavailable: () => void; openDraft: (draft: Draft) => void; foundDraft: (draft: Draft) => void; select: (id: string) => void
}

export default function DeferredQuestions({ detailsRef, session, parent, locked, onDirty, openDraft, foundDraft, select, onUnavailable }: Props) {
  const [open, setOpen] = useState(false)
  const [filter, setFilter] = useState<DeferredFilter>("all")
  const [page, setPage] = useState(1)
  const [tick, setTick] = useState(0)
  const [report, setReport] = useState<DeferredPage | null>(null)
  const [authorized, setAuthorized] = useState(false)
  const [readError, setReadError] = useState("")
  const [actionError, setActionError] = useState("")
  const [working, setWorking] = useState(false)
  const [sourceBusy, setSourceBusy] = useState<string | null>(null)
  const [editingQuestion, setEditingQuestion] = useState(false)
  const [notice, setNotice] = useState("")
  const active = useRef<AbortController | null>(null)
  const childId = useRef<{ questionId: string; id: string } | null>(null)
  const controlsLocked = locked || working || !!sourceBusy || editingQuestion
  const editable = session.consent && !session.ended_at && (!session.privacy_state || session.privacy_state === "unmarked")
  useReportDirty(working || !!sourceBusy || editingQuestion, onDirty)
  useEffect(() => () => active.current?.abort(), [])

  function reload() { setTick(n => n + 1) }
  useEffect(() => {
    if (!open) return
    const request = new AbortController()
    setReport(null); setReadError("")
    listDeferred(session.id, filter, page, request.signal).then(next => {
      if (request.signal.aborted) return
      setAuthorized(true)
      if (next.page !== page) setPage(next.page)
      else setReport(next)
    }).catch(err => {
      if (!request.signal.aborted) {
        if (accessLost(err)) { childId.current = null; onUnavailable(); return }
        setReadError(message(err))
      }
    })
    return () => request.abort()
  }, [session.id, session.answers, session.draft, filter, page, tick, open, onUnavailable])

  async function act(item: DeferredQuestion, action: "dismiss" | "ask") {
    if (!editable || controlsLocked || active.current) return
    const controller = new AbortController()
    active.current = controller
    setWorking(true); setNotice(""); setActionError("")
    try {
      if (action === "dismiss") {
        await changeDeferred(item, "dismiss", controller.signal)
        if (!controller.signal.aborted) setNotice("Question dismissed.")
      } else {
        const existing = await api<Draft | null>(`sessions/${session.id}/draft`, "GET", undefined, controller.signal)
        if (existing) {
          if (!matchesDeferredDraft(existing, item)) {
            foundDraft(existing)
            if (existing.deferred_question?.id === item.id) throw new Error("This saved draft needs the current source. Resume it from the saved draft banner.")
            throw new Error("Another exchange draft is saved. Resume or discard that draft before asking this question.")
          }
          if (!controller.signal.aborted) openDraft(existing)
          return
        }
        const id = childId.current?.questionId === item.id ? childId.current.id : crypto.randomUUID()
        childId.current = { questionId: item.id, id }
        const draft = await saveDeferredDraft(item, id, 0, "", [], controller.signal)
        if (!controller.signal.aborted) { childId.current = null; openDraft(draft) }
      }
    } catch (e) {
      if (!controller.signal.aborted) {
        if (accessLost(e)) { childId.current = null; onUnavailable() }
        else setActionError(message(e))
      }
    } finally {
      if (!controller.signal.aborted) { setWorking(false); reload() }
      active.current = null
    }
  }

  function ordinal(id: string) { return session.answers.findIndex(a => a.id === id) + 1 }
  return <details ref={detailsRef} id="deferred-questions" className="panel inset stack" onToggle={e => { if (e.currentTarget.open) setOpen(true) }}>
    <summary className="cursor-pointer font-semibold">Questions for later</summary>
    {open && <div className="stack">
      {editable && authorized && parent && <KeepQuestion key={parent.id}
        onUnavailable={onUnavailable} session={session} parent={parent} ordinal={ordinal(parent.id)} disabled={locked || working || !!sourceBusy}
        onDirty={setEditingQuestion} onSaved={() => { setFilter("all"); setPage(1); reload() }} />}
      <div className="spread flex-wrap">
        <label className="field">Show questions
          <select aria-label="Deferred question status" value={filter} disabled={controlsLocked}
            onChange={e => { setFilter(e.target.value as DeferredFilter); setPage(1); setNotice("") }}>
            <option value="all">All</option>
            {deferredStates.map(state => <option key={state} value={state}>{state[0].toUpperCase() + state.slice(1)}</option>)}
          </select>
        </label>
        <Button type="button" size="sm" variant="outline" disabled={working || !!sourceBusy} onClick={reload}>Reload questions</Button>
      </div>
      {readError && <p className="error" role="alert">{readError}</p>}
      {actionError && <p className="error" role="alert">{actionError}</p>}
      {notice && <p role="status">{notice}</p>}
      {!report && !readError && <p className="muted" role="status">Loading deferred questions…</p>}
      {report && <>
        {report.items.length === 0 ? <p className="muted">No {filter === "all" ? "deferred" : filter} questions.</p>
          : <p className="muted">{report.pending_count} pending · Page {page} of {Math.max(1, Math.ceil(report.total / report.page_size))}</p>}
        <ol className="stack">
          {report.items.map(item => <li key={item.id} className="panel inset stack" aria-label={`Deferred question from exchange ${ordinal(item.parent_answer_id)}`}>
            <div><strong className="whitespace-pre-wrap break-words">{item.question}</strong> <span className="muted">{item.status}</span></div>
            <div className="row flex-wrap">
              <Button type="button" size="sm" variant="outline" disabled={controlsLocked} onClick={() => select(item.parent_answer_id)}>
                View source exchange {ordinal(item.parent_answer_id) || ""}
              </Button>
              {item.child_answer_id && <Button type="button" size="sm" variant="outline" disabled={controlsLocked}
                onClick={() => select(item.child_answer_id!)}>View saved answer</Button>}
              {editable && item.status === "pending" && <>
                {!item.needs_reconfirmation && <Button type="button" size="sm" disabled={controlsLocked}
                  onClick={() => void act(item, "ask")}>Open answer draft</Button>}
                <Button type="button" size="sm" variant="ghost" disabled={controlsLocked}
                  onClick={() => void act(item, "dismiss")}>Dismiss question</Button>
              </>}
            </div>
            {item.status === "pending" && item.needs_reconfirmation && <p role="status">The source exchange changed. Confirm it before opening a draft.</p>}
            {editable && (item.status === "dismissed" || item.status === "pending" && item.needs_reconfirmation) && <DeferredSourceCheck onUnavailable={onUnavailable} questionId={item.id} sessionId={session.id}
              disabled={locked || working || editingQuestion || (sourceBusy !== null && sourceBusy !== item.id)}
              reopen={item.status === "dismissed"} onBusy={value => setSourceBusy(old => value ? item.id : old === item.id ? null : old)}
              onConfirmed={() => { setNotice("Source confirmed."); reload() }} />}
          </li>)}
        </ol>
        {report.total > report.page_size && <div className="row flex-wrap">
          <Button type="button" size="sm" variant="outline" disabled={controlsLocked || page === 1} onClick={() => setPage(page - 1)}>Previous questions</Button>
          <Button type="button" size="sm" variant="outline" disabled={controlsLocked || page * report.page_size >= report.total} onClick={() => setPage(page + 1)}>Next questions</Button>
        </div>}
      </>}
    </div>}
  </details>
}
