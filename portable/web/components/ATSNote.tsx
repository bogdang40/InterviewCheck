"use client"

import { useEffect, useState } from "react"
import { Send } from "lucide-react"
import { api, message, type Session } from "@/lib/api"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import { Textarea } from "./ui/textarea"

type Recipient = { candidate: string; role: string; target_id: string }
type Record = { id: string; provider: string; remote_id: string; recipient: string; state: string }
type Draft = Record & { draft: string }
type State = { providers: string[]; history: Record[] }

export function ATSNote({ session }: { session: Session }) {
  const base = "sessions/" + session.id + "/ats"
  const [state, setState] = useState<State>()
  const [provider, setProvider] = useState("")
  const [email, setEmail] = useState("")
  const [targets, setTargets] = useState<Recipient[]>([])
  const [draft, setDraft] = useState<Draft>()
  const [note, setNote] = useState("")
  const [confirmed, setConfirmed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const [status, setStatus] = useState("")

  useEffect(() => {
    let active = true
    api<State>(base).then(value => {
      if (active) { setState(value); setProvider(value.providers[0] || "") }
    }).catch(error => { if (active) setError(message(error)) })
    return () => { active = false }
  }, [base])

  function clearSelection() {
    setTargets([]); setDraft(undefined); setConfirmed(false); setStatus(""); setError("")
  }
  async function run(work: () => Promise<void>) {
    setBusy(true); setError(""); setStatus("")
    try { await work() } catch (error) { setError(message(error)) } finally { setBusy(false) }
  }
  function find() {
    clearSelection()
    void run(async () => {
      const rows = await api<Recipient[]>(base + "/recipients", "POST", { provider, email })
      setTargets(rows)
      if (!rows.length) setStatus("No matching recipient was found.")
    })
  }
  function preview(target: Recipient) {
    void run(async () => {
      const item = await api<Draft>(base + "/drafts", "POST", { provider, email, target_id: target.target_id })
      setDraft(item); setNote(item.draft); setConfirmed(false)
    })
  }
  function send() {
    if (!draft || !confirmed || !note.trim()) return
    void run(async () => {
      try {
        await api(base + "/drafts/" + draft.id + "/send", "POST", { note, confirmed: true })
      } catch (error) {
        const current = await api<State>(base)
        setState(current)
        if (current.history.some(item => item.id === draft.id && item.state === "attempted")) {
          setDraft(undefined); setTargets([]); setConfirmed(false)
        }
        throw error
      }
      setDraft(undefined); setTargets([]); setConfirmed(false)
      setStatus("The provider accepted the private note.")
      setState(await api<State>(base))
    })
  }

  return <details className="import">
    <summary>Send a private ATS note</summary>
    <div className="stack">
      {state && !state.providers.length && <p>Configure an ATS connection with permission to write private notes.</p>}
      {!!state?.providers.length && <>
        <form className="stack" onSubmit={event => { event.preventDefault(); find() }}>
          <div className="dual">
            <label className="field">Destination ATS<select disabled={busy} value={provider}
              onChange={event => { clearSelection(); setProvider(event.target.value) }}>
              {state.providers.map(p => <option key={p} value={p}>{p}</option>)}
            </select></label>
            <label className="field">Candidate email<Input type="email" value={email} required maxLength={254} disabled={busy}
              onChange={event => { clearSelection(); setEmail(event.target.value) }}/></label>
          </div>
          <div><Button disabled={busy} variant="outline">Find recipient</Button></div>
        </form>
        {!draft && targets.map(target => <div className="spread" key={target.target_id}>
          <p>{target.candidate} · {target.role || "Role unspecified"} · {target.target_id}</p>
          <Button disabled={busy} variant="outline" onClick={() => preview(target)}>Preview note</Button>
        </div>)}
        {draft && <div className="stack notice">
          <p><strong>Destination</strong> {draft.provider} · {draft.recipient} · {draft.remote_id}</p>
          <label className="field">Private note<Textarea value={note} disabled={busy} maxLength={8000}
            onChange={event => { setNote(event.target.value); setConfirmed(false) }}/></label>
          <label className="check"><input type="checkbox" checked={confirmed} disabled={busy}
            onChange={event => setConfirmed(event.target.checked)}/>I verified the recipient and the note.</label>
          <div className="row"><Button type="button" disabled={busy || !confirmed || !note.trim()} onClick={send}><Send/>Send private note</Button>
            <Button type="button" variant="ghost" disabled={busy} onClick={() => setDraft(undefined)}>Cancel</Button></div>
        </div>}
      </>}
      {error && <p role="alert" className="error">{error}</p>}
      {status && <p role="status">{status}</p>}
      {!!state?.history.some(item => item.state !== "draft") && <details>
        <summary>Delivery history</summary>
        {state.history.filter(item => item.state !== "draft").map(item =>
          <p key={item.id}>{item.provider} · {item.recipient} · {item.state === "sent" ? "Accepted by provider" : "Delivery unconfirmed"}</p>)}
      </details>}
    </div>
  </details>
}

export default ATSNote
