import { useState } from "react"
import { Plus } from "lucide-react"
import { Button } from "./ui/button"
import type { Answer, Interview, Role } from "@/lib/api"
import ATSNote from "./ATSNote"
import ReportExport from "./ReportExport"
import Evidence from "./Evidence"
import AnswerEditor from "./AnswerEditor"

export default function InterviewView({
  session,
  roles,
  changed,
}: {
  session: Interview
  roles: Role[]
  changed: (id: string, answer: Answer) => void
}) {
  const [edit, setEdit] = useState<string | null>(session.consent && !session.answers.length ? "new" : null)
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
          <p>{session.role}</p>
        </div>
        <div className="row">
          <ReportExport sessionId={session.id} />
          {session.consent && !edit && (
            <Button size="sm" onClick={() => setEdit("new")}>
              <Plus />
              Add exchange
            </Button>
          )}
        </div>
      </div>
      <div className="policy">
        <strong>Assistance policy</strong>
        <p>{session.policy}</p>
      </div>
      {!session.consent && (
        <p className="notice">The native record has no recorded notice. Review the archived material here.</p>
      )}
      {session.consent && edit && (
        <AnswerEditor
          key={edit}
          session={session}
          role={roles.find((r) => r.name === session.role)}
          initial={session.answers.find((a) => a.id === edit)}
          onSave={save}
          onCancel={session.answers.length ? () => setEdit(null) : undefined}
        />
      )}
      {session.answers.map((a, i) =>
        a.id === edit ? null : (
          <Evidence
            key={a.id + ":" + a.question + ":" + a.answer}
            sessionId={session.id}
            item={a}
            index={i}
            onSave={(item) => changed(session.id, item)}
            onEdit={
              session.consent && !edit
                ? () => {
                    setEdit(a.id)
                    window.scrollTo(0, 0)
                  }
                : undefined
            }
          />
        ),
      )}
      <ATSNote key={session.id} session={session} />
    </>
  )
}
