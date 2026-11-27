"use client"

import { useCallback, useEffect, useRef, useState } from "react"
import { message, type Answer } from "@/lib/api"
import { useReportDirty } from "@/lib/dirtyTracking"
import { ApiError } from "@/lib/http"
import { displayedEvidence, panelLabels, readPanel, writePanel, type PanelAction, type PanelCase } from "@/lib/panelReview"
import { useAccountStatus } from "@/lib/useAccountStatus"
import { Button } from "./ui/button"
import { Textarea } from "./ui/textarea"

type Props = { sessionId: string; item: Answer; locked: boolean; onDirty: (key: string, value: boolean) => void }

export default function PanelDiscussion(props: Props) {
  const element = useRef<HTMLDetailsElement>(null)
  const [started, setStarted] = useState(false)
  useEffect(() => {
    if (window.location.hash === "#panel-discussion" && element.current) {
      element.current.open = true
      setStarted(true)
      if (document.activeElement === document.body) element.current.scrollIntoView({ block: "start" })
    }
  }, [props.item.id])
  return <details id="panel-discussion" ref={element} className="panel inset" onToggle={event => {
    if (event.currentTarget.open) setStarted(true)
  }}>
    <summary>Panel discussion</summary>
    {started && <PanelSession {...props} />}
  </details>
}

function PanelSession(props: Props) {
  const { account, status, isAdmin, loading, refresh } = useAccountStatus()
  useEffect(() => {
    const resume = () => { if (document.visibilityState === "visible") refresh() }
    const restored = (event: PageTransitionEvent) => { if (event.persisted) resume() }
    window.addEventListener("pageshow", restored)
    window.addEventListener("focus", resume)
    document.addEventListener("visibilitychange", resume)
    return () => {
      window.removeEventListener("pageshow", restored)
      window.removeEventListener("focus", resume)
      document.removeEventListener("visibilitychange", resume)
    }
  }, [refresh])
  if (!loading && !status) return <Button variant="outline" onClick={refresh}>Recheck panel access</Button>
  if (!loading && status?.access && (!status.signedIn || !account?.active)) {
    return <p className="muted">Sign in with active workspace access to read this panel discussion.</p>
  }
  const scope = JSON.stringify([account?.email, account?.active, isAdmin])
  return <PanelEditor key={scope} {...props} isAdmin={isAdmin && account?.active === true} authLoading={loading} />
}

function PanelEditor({ sessionId, item, locked, onDirty, isAdmin, authLoading }:
  Props & { isAdmin: boolean; authLoading: boolean }) {
  const editorContext = useRef<string | undefined>(undefined)
  const [privateNotes, setPrivateNotes] = useState(false)
  const [data, setData] = useState<PanelCase | null>(null)
  const [query, setQuery] = useState({ before: null as number | null, reload: 0 })
  const [rationale, setRationale] = useState("")
  const [action, setAction] = useState<PanelAction | "">("")
  const [error, setError] = useState("")
  const [notice, setNotice] = useState("")
  const [busy, setBusy] = useState(false)
  const submit = useRef<AbortController | null>(null)
  const report = useCallback((value: boolean) => onDirty("panel", value), [onDirty])
  useReportDirty(busy || !!rationale, report)

  useEffect(() => {
    const controller = new AbortController()
    submit.current?.abort()
    setBusy(false)
    setData(null)
    setError("")
    if (!authLoading) {
      Promise.all([readPanel(sessionId, item.id, query.before, controller.signal, privateNotes && isAdmin, isAdmin), displayedEvidence(item)])
        .then(([record, evidence]) => {
          if (controller.signal.aborted) return
          if (record.evidence !== evidence) throw new Error("The displayed exchange changed. Reload the interview to review its current text.")
          const changedEditor = !!editorContext.current && record.editor !== editorContext.current
          editorContext.current = record.editor
          if (changedEditor) {
            setRationale("")
            setNotice("")
            setPrivateNotes(false)
            if (privateNotes) return
          }
          setData(record)
          setAction("")
        }).catch(err => {
          if (!controller.signal.aborted) {
            if (err instanceof ApiError && [401, 402, 403, 404].includes(err.status)) setRationale("")
            setError(message(err))
          }
        })
    }
    return () => { controller.abort(); submit.current?.abort() }
  }, [sessionId, item, query, authLoading, isAdmin, privateNotes])

  function refresh(before: number | null = null) {
    setNotice("")
    setQuery(old => ({ before, reload: old.reload + 1 }))
  }

  async function save() {
    if (!data || !action || locked || busy || !isAdmin || !rationale.trim() || query.before !== null) return
    const controller = new AbortController()
    submit.current = controller
    setBusy(true); setError(""); setNotice("")
    try {
      const next = await writePanel(data, action, rationale.trim(), controller.signal)
      if (controller.signal.aborted) return
      if (next.history_count !== data.history_count + 1 || next.basis !== data.basis ||
          next.editor !== data.editor || next.history[0]?.action !== action || next.history[0]?.rationale !== rationale.trim()) {
        throw new Error("The server could not confirm this decision. Read the latest panel record before another change.")
      }
      setData(next); setRationale(""); setNotice("Panel decision recorded.")
      setAction("")
    } catch (err) {
      if (!controller.signal.aborted) {
        setData(null)
        if (err instanceof ApiError && ([401, 402, 403, 404].includes(err.status) || err.code === "panel-authority")) {
          setRationale("")
          setAction("")
          setPrivateNotes(false)
          editorContext.current = undefined
        }
        setError(message(err))
      }
    } finally {
      if (!controller.signal.aborted) setBusy(false)
    }
  }

  if (authLoading) return <p className="muted" role="status">Checking access to panel discussion…</p>
  const last = data?.history.at(-1)
  const mayReopen = data && ["discussion_complete", "follow_up_required"].includes(data.status)
  return <div className="stack">
    {error && <p role="alert" className="error">{error}</p>}
    {error && <Button type="button" variant="outline" onClick={() => window.location.reload()}>Reload interview</Button>}
    {rationale && <Button type="button" variant="outline" disabled={busy} onClick={() => {
      setRationale(""); setAction("")
    }}>Discard panel draft</Button>}
    {notice && <p role="status">{notice}</p>}
    {!data && !error && <p role="status">Loading the panel discussion...</p>}
    <div className="row">
      {data && <strong>{panelLabels[data.status]}</strong>}
      <Button type="button" variant="outline" disabled={busy} onClick={() => refresh()}>Read latest panel record</Button>
    </div>
    {data && <>
      {data.status === "none" ? <p>No disagreement has been recorded for this exchange.</p> : <>
        <p className="muted">Panel decisions track the discussion. Each reviewer’s opinion and the saved interview outcome remain separate.</p>
        {data.status === "changed" && <p role="status">The saved evidence or reviewer opinions changed after the last decision. Review them again.</p>}
        <div>
          <strong>Latest recorded opinions</strong>
          {data.reviewers.length ? <ul>{data.reviewers.map((r, i) =>
            <li key={i}>{r.reviewer_email} · {r.disposition}</li>)}</ul> : <p>No active opinions.</p>}
          <small className="muted">Earlier opinions can refer to an earlier version of the exchange.</small>
        </div>
        {isAdmin && query.before === null ? <fieldset className="stack" disabled={busy || locked}>
          <legend>Record the panel’s next step</legend>
          <label className="field">Discussion action
            <select aria-label="Discussion action" value={action} onChange={e => setAction(e.target.value as PanelAction | "")}>
              <option value="">Choose an action</option>
              {data.status !== "discussion_complete" && <option value="discussion_complete">Mark discussion complete</option>}
              {data.status !== "discussion_complete" && data.status !== "follow_up_required" && <option value="follow_up_required">Request follow up</option>}
              {mayReopen && <option value="reopened">Reopen discussion</option>}
            </select>
          </label>
          <label className="field">Reason for this panel decision
            <Textarea value={rationale} maxLength={1000} onChange={e => setRationale(e.target.value)} />
          </label>
          <Button type="button" disabled={!action || !rationale.trim()} onClick={() => void save()}>Record panel decision</Button>
        </fieldset> : !isAdmin && <p className="muted">A signed in administrator can record a panel decision.</p>}
      </>}
      {!!data.history_count && <div className="stack">
        <h3>Panel history</h3>
        {isAdmin && <Button type="button" variant="outline" disabled={busy || !!rationale}
          onClick={() => setPrivateNotes(!privateNotes)}>{privateNotes ? "Hide private panel notes" : "Read private panel notes"}</Button>}
        <p>{data.history_count} recorded {data.history_count === 1 ? "change" : "changes"}.</p>
        <ol>{data.history.map(h => <li key={h.sequence}>
          <strong>{panelLabels[h.action]}</strong> · {privateNotes && isAdmin && h.actor_email && <>{h.actor_email} · </>}<time dateTime={h.created_at}>{new Date(h.created_at).toLocaleString()}</time>
          {privateNotes && isAdmin && h.rationale && <p className="whitespace-pre-wrap break-words">{h.rationale}</p>}
        </li>)}</ol>
        {last && last.sequence > 1 && <Button type="button" variant="outline" disabled={busy || !!rationale}
          onClick={() => refresh(last.sequence)}>Older panel history</Button>}
      </div>}
    </>}
  </div>
}
