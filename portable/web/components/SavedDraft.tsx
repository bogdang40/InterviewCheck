import { useState } from "react"
import { FilePenLine } from "lucide-react"
import { accessLost } from "@/lib/deferredQuestions"
import { useReviewNavigationGuard } from "@/lib/dirtyTracking"
import { api, message, DeferredConflict, DraftConflict, type Draft, type DraftSummary } from "@/lib/api"
import { Button } from "./ui/button"

export default function SavedDraft({
  sessionId,
  selectedId,
  summary,
  disabled,
  resume,
  discard,
  refresh,
  onUnavailable,
}: {
  sessionId: string
  selectedId?: string
  summary: DraftSummary
  disabled: boolean
  resume: (d: Draft) => void
  discard: () => void
  refresh: (d: Draft | null) => void
  onUnavailable: () => void
}) {
  const [busy, setBusy] = useState(false),
    [error, setError] = useState("")
  const [confirm, setConfirm] = useState<DraftSummary | null>(null)
  const guardNavigation = useReviewNavigationGuard(disabled, selectedId)
  async function act(remove: boolean) {
    const mayResume = guardNavigation()
    setBusy(true)
    setError("")
    try {
      if (remove && confirm) {
        const ack = await api<{ discarded: boolean }>("sessions/" + sessionId + "/draft/discard", "POST", {
          id: confirm.id,
          expected_revision: confirm.revision,
          ...(confirm.deferred_question ? { deferred_question: confirm.deferred_question, deferred_draft_token: confirm.deferred_draft_token } : {}),
        })
        if (!ack?.discarded) throw new Error("The server did not confirm the discard. Check the current draft.")
        discard()
      } else {
        const draft = await api<Draft | null>("sessions/" + sessionId + "/draft")
        if (!mayResume()) {
          setError(draft ? "The draft is still saved. Finish your current changes, then choose Resume draft."
            : "The saved draft changed. Finish your current changes, then check the draft again.")
        } else if (draft) resume(draft)
        else discard()
      }
    } catch (e) {
      if (summary.deferred_question && accessLost(e)) { onUnavailable(); return }
      if (remove && (e instanceof DeferredConflict || e instanceof DraftConflict)) {
        try {
          refresh(await api<Draft | null>("sessions/" + sessionId + "/draft"))
          setError("The saved draft changed. Review the current draft before confirming a discard.")
        } catch (readError) { if (summary.deferred_question && accessLost(readError)) onUnavailable(); else setError(message(readError)) }
      } else setError(message(e))
    } finally {
      setBusy(false)
      setConfirm(null)
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
            <Button size="sm" variant="ghost" onClick={() => setConfirm(null)}>
              Keep draft
            </Button>
          </>
        ) : (
          <>
            <Button size="sm" disabled={disabled || busy} onClick={() => act(false)}>
              Resume draft
            </Button>
            <Button size="sm" variant="ghost" disabled={disabled || busy} onClick={() => setConfirm(summary)}>
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
  onUnavailable,
  sessionId,
  resolve,
}: {
  sessionId: string
  onUnavailable?: () => void
  resolve: (latest: Draft | null, keep: boolean) => void
}) {
  const [latest, setLatest] = useState<Draft | null | undefined>(undefined)
  const [error, setError] = useState("")
  async function load() {
    try {
      setLatest(await api<Draft | null>("sessions/" + sessionId + "/draft"))
      setError("")
    } catch (e) {
      if (onUnavailable && accessLost(e)) onUnavailable()
      else setError(message(e))
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
