import { useState } from "react"
import { FilePenLine } from "lucide-react"
import { api, message, type Draft, type DraftSummary } from "@/lib/api"
import { Button } from "./ui/button"

export default function SavedDraft({
  sessionId,
  summary,
  disabled,
  resume,
  discard,
}: {
  sessionId: string
  summary: DraftSummary
  disabled: boolean
  resume: (d: Draft) => void
  discard: () => void
}) {
  const [busy, setBusy] = useState(false),
    [error, setError] = useState("")
  const [confirm, setConfirm] = useState(false)
  async function act(remove: boolean) {
    setBusy(true)
    setError("")
    try {
      if (remove) {
        await api("sessions/" + sessionId + "/draft/discard", "POST", {
          id: summary.id,
          expected_revision: summary.revision,
        })
        discard()
      } else {
        const draft = await api<Draft | null>("sessions/" + sessionId + "/draft")
        if (draft) resume(draft)
        else discard()
      }
    } catch (e) {
      setError(message(e))
    } finally {
      setBusy(false)
      setConfirm(false)
    }
  }
  return (
    <section className="draft-banner">
      <div>
        <FilePenLine size={18} />
        <strong>Saved exchange draft</strong>
        <small>{new Date(summary.updated_at).toLocaleString()}</small>
      </div>
      <div className="row">
        {confirm ? (
          <>
            <span>Discard this saved draft?</span>
            <Button size="sm" variant="outline" disabled={disabled || busy} onClick={() => act(true)}>
              Confirm discard
            </Button>
            <Button size="sm" variant="ghost" onClick={() => setConfirm(false)}>
              Keep draft
            </Button>
          </>
        ) : (
          <>
            <Button size="sm" disabled={disabled || busy} onClick={() => act(false)}>
              Resume draft
            </Button>
            <Button size="sm" variant="ghost" disabled={disabled || busy} onClick={() => setConfirm(true)}>
              Discard saved draft
            </Button>
          </>
        )}
      </div>
      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
    </section>
  )
}

export function DraftConflictView({
  sessionId,
  resolve,
}: {
  sessionId: string
  resolve: (latest: Draft | null, keep: boolean) => void
}) {
  const [latest, setLatest] = useState<Draft | null | undefined>(undefined)
  const [error, setError] = useState("")
  async function load() {
    try {
      setLatest(await api<Draft | null>("sessions/" + sessionId + "/draft"))
      setError("")
    } catch (e) {
      setError(message(e))
    }
  }
  return (
    <div className="notice stack" role="region" aria-label="Conflicting draft">
      <p role="alert">The saved draft changed in another view. Your edits are still here.</p>
      {latest === undefined ? (
        <Button type="button" variant="outline" onClick={load}>
          Compare saved draft
        </Button>
      ) : latest ? (
        <>
          <div>
            <strong>Saved revision {latest.revision}</strong>
            <p>{latest.question}</p>
            <p>{latest.answer}</p>
            {latest.references.map((r, i) => (
              <details key={i}>
                <summary>{r.label || "Untitled source"}</summary>
                <p>{r.text}</p>
              </details>
            ))}
          </div>
          <div className="row">
            <Button type="button" variant="outline" onClick={() => resolve(latest, true)}>
              Keep my edits
            </Button>
            <Button type="button" variant="ghost" onClick={() => resolve(latest, false)}>
              Use saved draft
            </Button>
          </div>
        </>
      ) : (
        <>
          <p>This draft was published or discarded.</p>
          <Button type="button" onClick={() => resolve(null, true)}>
            Start a new draft with my edits
          </Button>
        </>
      )}
      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
    </div>
  )
}
