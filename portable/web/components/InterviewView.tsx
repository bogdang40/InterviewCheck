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
import { useReportDirty, type DirtyReporter } from "@/lib/dirtyTracking"
import { useReviewHotkeys } from "@/lib/useReviewHotkeys"
import { useScoringCapabilities } from "@/lib/scoringHooks"
import SavedDraft from "./SavedDraft"
import MoveToTrash from "./MoveToTrash"
import ReportExport from "./ReportExport"
import Evidence, { type EvidenceHotkeyControls } from "./Evidence"
import QuestionLineage from "./QuestionLineage"
import QuestionNavigator, { needsReview, nextPending } from "./QuestionNavigator"

const ATSNote = dynamic(() => import("./ATSNote"), { ssr: false })
const LocalRecordingPlayback = dynamic(() => import("./LocalRecordingPlayback"), { ssr: false })
const TranscriptBatchImport = dynamic(() => import("./TranscriptBatchImport"), { ssr: false })
const SessionScorecardPanel = dynamic(() => import("./SessionScorecardPanel"), { ssr: false })
const AnswerEditor = dynamic(() => import("./AnswerEditor"), {
  ssr: false,
  loading: () => <p role="status">Loading exchange editor...</p>,
})

type Props = {
  session: Interview
  answerId: string | null
  assignmentDirty: boolean
  onDirtyChange: DirtyReporter
  changed: (id: string, answer: Answer) => void
  onDraftChange: (draft: DraftSummary | null) => void
  onTransition: (session: Interview) => void
}

export default function InterviewView({ session, answerId, assignmentDirty, onDirtyChange, changed, onTransition, onDraftChange }: Props) {
  const protectedRecord = session.privacy_state === "anonymized" || session.privacy_state === "legacy_unverified"
  const captureAllowed = !protectedRecord && session.consent && !session.ended_at
  const [edit, setEdit] = useState<string | null>(
    captureAllowed && !session.draft && !session.answers.length ? "new" : null,
  )
  const [resumed, setResumed] = useState<Draft>()
  const [followUp, setFollowUp] = useState("")
  const [firstOrigin,setFirstOrigin] = useState<QuestionOrigin>()
  const [dirty, setDirty] = useState<Set<string>>(() => new Set())
  const [scorecardDirty, setScorecardDirty] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const focusTarget = useRef<HTMLDivElement>(null)
  const evidenceControls = useRef<EvidenceHotkeyControls | null>(null)
  const focusOnChange = useRef(false)
  const lastSelection = useRef(answerId)
  const selected = answerId ? session.answers.find((a) => a.id === answerId) : session.answers[0]
  const index = selected ? session.answers.indexOf(selected) : -1
  const next = selected && nextPending(session.answers, selected.id)
  const unsaved = dirty.size > 0 || scorecardDirty
  const blocked = unsaved || busy
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
  useReportDirty(unsaved, onDirtyChange)
  const moveExchange = (delta: -1 | 1) => {
    if (edit || blocked) return "Save or discard changes before switching exchanges."
    const idx = index < 0 ? 0 : index + delta
    if (idx < 0 || idx >= session.answers.length) return idx < 0 ? "Already on first exchange." : "Already on last exchange."
    select(session.answers[idx].id)
    return `Question ${idx + 1} of ${session.answers.length}: ${session.answers[idx].question}`
  }
  const applyOutcome = (value: "explained" | "unresolved") => {
    if (edit || !selected || !evidenceControls.current) return "Open an exchange in review mode to set outcome."
    if (!evidenceControls.current.setOutcome(value)) return "Cannot update outcome while saving or resolving a conflict."
    return `Review outcome set to ${value === "explained" ? "Explained" : "Unresolved"}. Save review to persist.`
  }
  const { announcement } = useReviewHotkeys({
    enabled: session.answers.length > 0,
    onNext: () => moveExchange(1),
    onPrev: () => moveExchange(-1),
    onNextPending: () => {
      if (edit || blocked) return "Save or discard changes before switching exchanges."
      if (!next) return "No pending matches remaining."
      select(next.id)
      return `Next pending match: Question ${session.answers.indexOf(next) + 1} of ${session.answers.length}: ${next.question}`
    },
    onExplained: () => applyOutcome("explained"),
    onUnresolved: () => applyOutcome("unresolved"),
    onFocusNote: () => (!edit && selected && evidenceControls.current?.focusNote() ? "Focused interviewer note." : "Interviewer note is unavailable."),
  })
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
              {protectedRecord ? "Read only" : session.ended_at ? "Finished" : session.consent ? "In progress" : "Archive only"}
            </span>
            <time dateTime={session.created_at}>{dateLabel(session.created_at)}</time>
          </div>
          <h1>{session.candidate}</h1>
          <p>{session.role}</p>
        </div>
        <div className="record-actions">
          <ReportExport sessionId={session.id} disabled={blocked} />
          {session.consent && !protectedRecord && (
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
      {protectedRecord && <p className="notice" role="status">{session.privacy_state === "anonymized"
        ? "Retention anonymized this interview. Its retained records are read only."
        : "This older archive has an unverified privacy hold. Its records are read only."}</p>}
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
      {unsaved && (
        <p className="notice" role="status">
          Save or discard your changes before switching questions, finishing or exporting.
        </p>
      )}
      {!protectedRecord && session.draft && edit !== "draft" && (
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
      <p role="status" aria-live="polite" aria-atomic="true" style={{ fontSize: "12px", color: "var(--secondary-ink)", margin: announcement ? "0 0 10px" : "0", overflowWrap: "anywhere", maxWidth: "100%" }}>
        {announcement}
      </p>
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
            ) : selected && protectedRecord ? (
              <section className="panel inset stack" aria-label="Retained exchange">
                <h2>{selected.question}</h2>
                <p className="preserve">{selected.answer}</p>
                <p>Saved review outcome: {selected.disposition}</p>
                {selected.note && <p className="preserve">{selected.note}</p>}
              </section>
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
                controlsRef={evidenceControls}
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
            {!protectedRecord && session.answers.some((a) => a.import_origin) && (
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
      <SessionScorecardPanel readOnly={protectedRecord} key={`scorecard-${session.id}`} sessionId={session.id} onDirtyChange={setScorecardDirty} />
      {!dirty.size && <ATSNote key={session.id} session={session} />}
      <div className="record-management"><MoveToTrash sessionId={session.id} candidate={session.candidate} disabled={blocked || assignmentDirty}/></div>
    </>
  )
}

function CircleIndicator() {
  return <span className="pending-dot" aria-hidden="true" />
}
