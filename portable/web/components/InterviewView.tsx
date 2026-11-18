import { useCallback, useState } from "react"
import { Plus } from "lucide-react"
import { Button } from "./ui/button"
import { api, message, type Answer, type Interview } from "@/lib/api"
import { useDraftGuard } from "@/lib/useDraftGuard"
import ATSNote from "./ATSNote"
import ReportExport from "./ReportExport"
import Evidence from "./Evidence"
import AnswerEditor from "./AnswerEditor"

export default function InterviewView({
  session,
  onTransition,
  changed,
}: {
  session: Interview
  onTransition: (session: Interview) => void
  changed: (id: string, answer: Answer) => void
}) {
  const [edit, setEdit] = useState<string | null>(
    session.consent && !session.ended_at && !session.answers.length ? "new" : null,
  )
  const [followUp, setFollowUp] = useState("")
  const [dirty, setDirty] = useState<Set<string>>(() => new Set())
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const onDirty = useCallback((id: string, value: boolean) => {
    setDirty((old) => {
      if (old.has(id) === value) return old
      const next = new Set(old)
      if (value) next.add(id)
      else next.delete(id)
      return next
    })
  }, [])
  useDraftGuard(dirty.size > 0)
  async function transition() {
    if (busy || dirty.size) return
    setError("")
    setBusy(true)
    try {
      const action = session.ended_at ? "reopen" : "finish"
      const next = await api<Interview>("sessions/" + session.id + "/" + action, "POST")
      setEdit(null)
      onTransition(next)
    } catch (e) {
      setError(message(e))
    } finally {
      setBusy(false)
    }
  }
  function save(item: Answer) {
    changed(session.id, item)
    setEdit(null)
  }
  return (
    <>
      <div className="page-title spread">
        <div>
          <span className="eyebrow">INTERVIEW RECORD</span>
          <h1>{session.candidate}</h1>
          <p>
            {session.role} · {session.ended_at ? "Finished" : "In progress"}
          </p>
        </div>
        <div className="row">
          <ReportExport sessionId={session.id} disabled={dirty.size > 0 || busy} />
          {session.consent && (
            <Button variant="outline" size="sm" onClick={transition} disabled={busy || dirty.size > 0}>
              {session.ended_at ? "Reopen interview" : "Finish interview"}
            </Button>
          )}
          {session.consent && !session.ended_at && !edit && (
            <Button
              size="sm"
              disabled={busy || dirty.size > 0}
              onClick={() => {
                setFollowUp("")
                setEdit("new")
              }}
            >
              <Plus />
              Add exchange
            </Button>
          )}
        </div>
      </div>
      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
      {dirty.size > 0 && (
        <p className="notice" role="status">
          Save or discard your changes before finishing the interview or exporting its report.
        </p>
      )}
      <div className="policy">
        <strong>Assistance policy</strong>
        <p>{session.policy}</p>
      </div>
      {!session.consent && (
        <p className="notice">The native record has no recorded notice. Review the archived material here.</p>
      )}
      {session.consent && !session.ended_at && edit && (
        <AnswerEditor
          key={edit}
          session={session}
          onDirty={onDirty}
          firstQuestion={edit === "new" ? followUp : ""}
          initial={session.answers.find((a) => a.id === edit)}
          onSave={save}
          onCancel={() => setEdit(null)}
        />
      )}
      {session.answers.map((a, i) =>
        a.id === edit ? null : (
          <Evidence
            key={a.id + ":" + a.question + ":" + a.answer}
            sessionId={session.id}
            item={a}
            index={i}
            onDirty={onDirty}
            onSave={(item) => changed(session.id, item)}
            onFollowUp={
              session.consent && !session.ended_at && !edit && !dirty.size && !busy
                ? () => {
                    setFollowUp(a.result.follow_up)
                    setEdit("new")
                    window.scrollTo(0, 0)
                  }
                : undefined
            }
            onEdit={
              session.consent && !session.ended_at && !edit && !dirty.size && !busy
                ? () => {
                    setEdit(a.id)
                    window.scrollTo(0, 0)
                  }
                : undefined
            }
          />
        ),
      )}
      {!dirty.size && <ATSNote key={session.id} session={session} />}
    </>
  )
}
