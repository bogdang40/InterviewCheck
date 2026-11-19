"use client"

import dynamic from "next/dynamic"
import { useCallback, useEffect, useRef, useState } from "react"
import { ArrowRight, CheckCheck, ClipboardList, FileText, Plus } from "lucide-react"
import { Button } from "./ui/button"
import {
  api,
  dateLabel,
  message,
  type Draft,
  type DraftSummary,
  type Answer,
  type Interview,
  type QuestionOrigin,
} from "@/lib/api"
import { useDraftGuard } from "@/lib/useDraftGuard"
import { useScoringCapabilities } from "@/lib/scoringHooks"
import SavedDraft from "./SavedDraft"
import MoveToTrash from "./MoveToTrash"
import ATSNote from "./ATSNote"
import ReportExport from "./ReportExport"
import Evidence from "./Evidence"
import AnswerEditor from "./AnswerEditor"
import QuestionLineage from "./QuestionLineage"
import QuestionNavigator, { needsReview, nextPending } from "./QuestionNavigator"

const LocalRecordingPlayback = dynamic(() => import("./LocalRecordingPlayback"), { ssr: false })
const TranscriptBatchImport = dynamic(() => import("./TranscriptBatchImport"), { ssr: false })

type Props = {
  session: Interview
  answerId: string | null
  changed: (id: string, answer: Answer) => void
  onDraftChange: (draft: DraftSummary | null) => void
  onTransition: (session: Interview) => void
}

export default function InterviewView({ session, answerId, changed, onTransition, onDraftChange }: Props) {
  const captureAllowed = session.consent && !session.ended_at
  const [edit, setEdit] = useState<string | null>(
    captureAllowed && !session.draft && !session.answers.length ? "new" : null,
  )
  const [resumed, setResumed] = useState<Draft>()
  const [followUp, setFollowUp] = useState("")
  const [firstOrigin,setFirstOrigin] = useState<QuestionOrigin>()
  const [dirty, setDirty] = useState<Set<string>>(() => new Set())
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const focusTarget = useRef<HTMLDivElement>(null)
  const focusOnChange = useRef(false)
  const lastSelection = useRef(answerId)
  const selected = answerId ? session.answers.find((a) => a.id === answerId) : session.answers[0]
  const index = selected ? session.answers.indexOf(selected) : -1
  const next = selected && nextPending(session.answers, selected.id)
  const blocked = dirty.size > 0 || busy
  const pending = session.answers.filter(needsReview).length
  const capabilities = useScoringCapabilities()

  const onDirty = useCallback((id: string, value: boolean) => {
    setDirty((old) => {
      if (old.has(id) === value) return old
      const updated = new Set(old)
      if (value) updated.add(id)
      else updated.delete(id)
      return updated
    })
  }, [])
  useDraftGuard(dirty.size > 0)
  useEffect(() => {
    if (lastSelection.current !== answerId) {
      setEdit(null)
      lastSelection.current = answerId
    }
    if (focusOnChange.current && selected) {
      focusOnChange.current = false
      focusTarget.current?.focus({ preventScroll: true })
      focusTarget.current?.scrollIntoView({ block: "nearest" })
    }
  }, [answerId, selected])

  function select(id: string, replace = false) {
    setEdit(null)
    if (answerId === id) return
    const url = new URL(window.location.href)
    url.searchParams.set("answer", id)
    focusOnChange.current = true
    if (replace) window.history.replaceState(null, "", url)
    else window.history.pushState(null, "", url)
  }
  async function imported(result: { answer_ids: string[] }) {
    setError("")
    setBusy(true)
    try {
      const latest = await api<Interview>("sessions/" + session.id)
      onTransition(latest)
      if (result.answer_ids[0]) select(result.answer_ids[0], true)
      setEdit(null)
    } catch (e) {
      setError("Exchanges were saved. Reload the record to view them. " + message(e))
    } finally {
      setBusy(false)
    }
  }
  async function transition() {
    if (blocked) return
    setError("")
    setBusy(true)
    try {
      const action = session.ended_at ? "reopen" : "finish"
      onTransition(await api<Interview>("sessions/" + session.id + "/" + action, "POST"))
      setEdit(null)
    } catch (e) {
      setError(message(e))
    } finally {
      setBusy(false)
    }
  }
  function save(item: Answer, advance = false) {
    changed(session.id, item)
    if (item.id === session.draft?.id) onDraftChange(null)
    const destination = advance && item.disposition !== "pending" && next ? next.id : item.id
    select(destination, !advance)
  }
  function begin(question = "", origin?: QuestionOrigin) {
    setFirstOrigin(origin)
    setFollowUp(question)
    setEdit("new")
    window.scrollTo(0, 0)
  }
  return (
    <>
      <header className="record-header">
        <div>
          <div className="record-state">
            <span className={session.ended_at ? "ended" : "active"}>
              {session.ended_at ? "Finished" : session.consent ? "In progress" : "Archive only"}
            </span>
            <time dateTime={session.created_at}>{dateLabel(session.created_at)}</time>
          </div>
          <h1>{session.candidate}</h1>
          <p>{session.role}</p>
        </div>
        <div className="record-actions">
          <ReportExport sessionId={session.id} disabled={blocked} />
          {session.consent && (
            <Button variant="outline" size="sm" onClick={transition} disabled={blocked || !!session.draft}>
              {session.ended_at ? "Reopen interview" : "Finish interview"}
            </Button>
          )}
          {captureAllowed && !session.draft && !edit && (
            <Button size="sm" disabled={blocked} onClick={() => begin()}>
              <Plus />
              Add exchange
            </Button>
          )}
        </div>
      </header>
      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
      {!session.consent && (
        <p className="notice">The native record has no recorded notice. Review the archived material here.</p>
      )}
      <div className="record-context">
        <details>
          <summary>
            <ClipboardList size={16} />
            Assistance policy
          </summary>
          <p>{session.policy}</p>
          {session.permitted_sources?.map((source, i) => (
            <details key={i} className="policy-source">
              <summary>{source.label}</summary>
              <p>{source.text}</p>
            </details>
          ))}
        </details>
        <span className={pending ? "outstanding" : "clear"}>
          {pending ? <CircleIndicator /> : <CheckCheck size={15} />} {pending} pending{" "}
          {pending === 1 ? "match" : "matches"}
        </span>
      </div>
      {dirty.size > 0 && (
        <p className="notice" role="status">
          Save or discard your changes before switching questions, finishing or exporting.
        </p>
      )}
      {session.draft && edit !== "draft" && (
        <SavedDraft
          sessionId={session.id}
          summary={session.draft}
          disabled={blocked || !!edit}
          discard={() => onDraftChange(null)}
          resume={(draft) => {
            setResumed(draft)
            setEdit("draft")
          }}
        />
      )}
      {captureAllowed && (
        <TranscriptBatchImport
          sessionId={session.id}
          disabled={busy || Array.from(dirty).some((key) => key !== "transcript-import")}
          onDirty={onDirty}
          onImported={imported}
        />
      )}
      <fieldset disabled={dirty.has("transcript-import")} className="review-lock">
        <div className={session.answers.length ? "review-grid" : "review-grid single"}>
          {!!session.answers.length && (
            <QuestionNavigator
              answers={session.answers}
              active={selected?.id}
              disabled={blocked}
              onSelect={(a) => select(a.id)}
            />
          )}
          <div className="review-pane" tabIndex={-1} ref={focusTarget} aria-label="Selected exchange">
            {captureAllowed && edit ? (
              <AnswerEditor
                key={edit}
                session={session}
                firstQuestion={edit === "new" ? followUp : ""}
                firstOrigin={edit === "new" ? firstOrigin : undefined}
                draft={edit === "draft" ? resumed : undefined}
                onDraftSaved={(saved) => {
                  onDraftChange(saved)
                  setEdit(null)
                }}
                initial={session.answers.find((a) => a.id === edit)}
                onDirty={onDirty}
                onSave={save}
                onCancel={() => setEdit(null)}
                embeddingAvailable={capabilities.embedding}
              />
            ) : selected ? (
              <Evidence
                key={selected.id}
                sessionId={session.id}
                item={selected}
                index={index}
                onDirty={onDirty}
                canAdvance={!!next}
                onSave={save}
                judgeAvailable={capabilities.judge}
                onFollowUp={
                  captureAllowed && !session.draft && !blocked
                    ? (questionText?: string) =>
                        begin(questionText ?? selected.result.follow_up, { parent_answer_id: selected.id })
                    : undefined
                }
                onEdit={captureAllowed && !blocked ? () => setEdit(selected.id) : undefined}
              />
            ) : (
              <section className="panel empty">
                <FileText size={24} />
                <strong>{answerId ? "Question unavailable" : "No exchanges captured"}</strong>
                <p>
                  {answerId
                    ? "This question does not belong to the interview. Select one from the question list."
                    : "Captured questions and reviewed evidence will appear here."}
                </p>
              </section>
            )}
            {!edit && <QuestionLineage session={session} selected={selected} disabled={blocked} navigate={select}
              askSlot={captureAllowed && !session.draft ? slot => begin(session.planned_questions[slot-1], {planned_slot:slot}) : undefined}/>}
            {session.answers.some((a) => a.import_origin) && (
              <LocalRecordingPlayback
                key={session.id}
                sessionId={session.id}
                selectedAnswer={selected}
                disabled={busy || !!edit || dirty.has("transcript-import")}
              />
            )}
            {!edit && next && (
              <Button variant="outline" disabled={blocked} onClick={() => select(next.id)}>
                Next pending match <ArrowRight />
              </Button>
            )}
          </div>
        </div>
      </fieldset>
      {!dirty.size && <ATSNote key={session.id} session={session} />}
      <div className="record-management"><MoveToTrash sessionId={session.id} candidate={session.candidate} disabled={blocked}/></div>
    </>
  )
}

function CircleIndicator() {
  return <span className="pending-dot" aria-hidden="true" />
}
