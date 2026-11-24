"use client"

import { type FormEvent, useCallback, useEffect, useId, useRef, useState } from "react"
import { CalendarClock, Trash2, UserCheck } from "lucide-react"
import { message } from "@/lib/api"
import { useReportDirty, type DirtyReporter } from "@/lib/dirtyTracking"
import { isResourceUnavailable } from "@/lib/http"
import {
  AssignmentConflict, clearSessionAssignment, deadlineLabel, fetchSessionAssignment, isDueOverdue, saveSessionAssignment,
  toDateInputValue, toDueAtIso, type AssignmentPriority, type SessionAssignment, type SessionAssignmentResponse,
} from "@/lib/sessionAssignment"
import WorkspaceError from "./WorkspaceError"
import { Badge } from "./ui/badge"
import { Button } from "./ui/button"
import { Input } from "./ui/input"

const PRIORITY_VARIANT: Record<AssignmentPriority, "secondary" | "outline" | "warning"> = {
  low: "secondary", normal: "outline", high: "warning",
}
const PRIORITY_LABEL: Record<AssignmentPriority, string> = {
  low: "Low priority", normal: "Normal priority", high: "High priority",
}
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

type Fields = Pick<SessionAssignment, "assignee_email" | "priority" | "due_at">
type Review = { before: SessionAssignment | null; proposed: Fields | null; latest?: SessionAssignmentResponse }

function reviewedFields({ before, proposed, latest }: Review): Fields | null {
  if (!proposed || !latest?.assignment) return proposed
  const saved = latest.assignment
  return {
    assignee_email: proposed.assignee_email === (before?.assignee_email ?? "").trim().toLowerCase() ? saved.assignee_email : proposed.assignee_email,
    priority: proposed.priority === (before?.priority ?? "normal") ? saved.priority : proposed.priority,
    due_at: proposed.due_at === (before?.due_at ?? null) ? saved.due_at : proposed.due_at,
  }
}

function AssignmentValues({ title, fields }: { title: string; fields: Fields | null }) {
  return <section className="panel inset stack min-w-0 break-words" aria-label={title}>
    <h4>{title}</h4>
    {fields ? <dl className="grid gap-1">
      <dt>Assignee</dt><dd className="break-all">{fields.assignee_email}</dd>
      <dt>Priority</dt><dd>{PRIORITY_LABEL[fields.priority]}</dd>
      <dt>Deadline</dt><dd>{fields.due_at ? <time className="break-all" dateTime={fields.due_at}>{fields.due_at}</time> : "None"}</dd>
    </dl> : <p>Unassigned</p>}
  </section>
}

export default function SessionAssignmentBar({ sessionId, onDirtyChange }: { sessionId: string; onDirtyChange: DirtyReporter }) {
  const datalistId = useId()
  const dueHelpId = useId()
  const [assignment, setAssignment] = useState<SessionAssignment | null>(null)
  const [version, setVersion] = useState<string | null>(null)
  const [review, setReview] = useState<Review | null>(null)
  const reviewHeading = useRef<HTMLHeadingElement>(null)
  const emailField = useRef<HTMLInputElement>(null)
  const [suggestions, setSuggestions] = useState<string[]>([])
  const [assigneeEmail, setAssigneeEmail] = useState("")
  const [priority, setPriority] = useState<AssignmentPriority>("normal")
  const [dueDate, setDueDate] = useState("")
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState("")
  const [accessIssue, setAccessIssue] = useState("")
  const [actionError, setActionError] = useState("")
  const [statusNotice, setStatusNotice] = useState("")
  const [busy, setBusy] = useState<"save" | "clear" | "reload" | null>(null)
  const [read, setRead] = useState({ attempt: 0, verify: false })
  const edited = assigneeEmail.trim().toLowerCase() !== (assignment?.assignee_email ?? "").trim().toLowerCase() ||
    priority !== (assignment?.priority ?? "normal") || dueDate !== toDateInputValue(assignment?.due_at)
  useReportDirty(!!review || (!loading && edited), onDirtyChange)

  const accept = useCallback((saved: SessionAssignment | null, nextVersion: string | null) => {
    setAssignment(saved)
    setVersion(nextVersion)
    setAssigneeEmail(saved?.assignee_email ?? "")
    setPriority(saved?.priority ?? "normal")
    setDueDate(toDateInputValue(saved?.due_at))
    setReview(null)
  }, [])

  const withhold = useCallback((source: "read" | "write") => {
    accept(null, null)
    setSuggestions([])
    setActionError("")
    setStatusNotice("")
    setLoadError("")
    setAccessIssue(source === "write" ? "The assignment change was refused. Reload the assignment before editing again."
      : "The assignment is unavailable. Reload it to check current access.")
  }, [accept])

  function reload(verify = false) { setRead(old => ({ attempt: old.attempt + 1, verify })) }

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true)
    setLoadError("")
    fetchSessionAssignment(sessionId, controller.signal)
      .then((res) => {
        if (controller.signal.aborted) return
        if (read.verify && !res.version) { setLoadError("The server did not return a current assignment version."); return }
        accept(res.assignment, res.version)
        setSuggestions(res.suggested_reviewers)
        setAccessIssue("")
      })
      .catch(err => {
        if (controller.signal.aborted) return
        if (isResourceUnavailable(err)) withhold("read")
        else setLoadError(message(err))
      })
      .finally(() => { if (!controller.signal.aborted) setLoading(false) })
    return () => controller.abort()
  }, [sessionId, read, accept, withhold])

  useEffect(() => { if (review?.latest) reviewHeading.current?.focus() }, [review?.latest])

  async function reloadConflict(change: Review) {
    setBusy("reload")
    setReview({ ...change, latest: undefined })
    setActionError("")
    try {
      const latest = await fetchSessionAssignment(sessionId)
      if (!latest.version) { withhold("read"); return }
      setSuggestions(latest.suggested_reviewers)
      setAssignment(latest.assignment)
      setVersion(latest.version)
      if (!change.proposed && !latest.assignment) {
        accept(null, latest.version)
        setStatusNotice("Another reviewer already cleared this assignment.")
        requestAnimationFrame(() => emailField.current?.focus())
      } else {
        setReview({ ...change, latest })
      }
    } catch (err) {
      if (isResourceUnavailable(err)) withhold("read")
      else setActionError(message(err))
    } finally {
      setBusy(null)
    }
  }

  async function write(proposed: Fields | null, before: SessionAssignment | null, expected: string | null) {
    if (!expected || busy) return
    setBusy(proposed ? "save" : "clear")
    setActionError("")
    setStatusNotice("")
    try {
      const result = proposed ? await saveSessionAssignment(sessionId, proposed, expected) : await clearSessionAssignment(sessionId, expected)
      const saved = result.assignment
      accept(saved, result.version)
      if (saved) setSuggestions(prev => prev.includes(saved.assignee_email) ? prev : [saved.assignee_email, ...prev])
      setStatusNotice(saved ? `Assigned to ${saved.assignee_email} (${saved.priority} priority).` : "Session assignment cleared.")
      if (review) requestAnimationFrame(() => emailField.current?.focus())
    } catch (err) {
      if (err instanceof AssignmentConflict) await reloadConflict({ before, proposed })
      else if (isResourceUnavailable(err)) withhold("write")
      else setActionError(message(err))
    } finally {
      setBusy(null)
    }
  }

  function handleSave(e: FormEvent) {
    e.preventDefault()
    if (!version || review || busy) return
    const email = assigneeEmail.trim().toLowerCase()
    if (!email) return setActionError("Enter an assignee email address.")
    if (!EMAIL_RE.test(email)) return setActionError("Enter a valid email address.")
    void write({ assignee_email: email, priority, due_at: toDueAtIso(dueDate, assignment?.due_at) }, assignment, version)
  }

  function discardEdits() {
    if (busy) return
    accept(assignment, version)
    setActionError("")
    setStatusNotice("Assignment edits discarded.")
    requestAnimationFrame(() => emailField.current?.focus())
  }

  if (accessIssue) return <section className="panel inset stack" aria-label="Session assignment">
    <p role="alert" className="error">{accessIssue} {loadError}</p>
    <Button type="button" variant="outline" disabled={loading || !!busy} onClick={() => reload(true)}>Reload assignment</Button>
  </section>
  if (loadError) return <WorkspaceError text={loadError} retry={() => reload()} showAccount={false} />
  const locked = loading || !!busy || !!review || !version
  const latest = review?.latest

  return (
    <section className="panel inset stack" aria-label="Session assignment">
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <UserCheck className="size-4 shrink-0 text-[var(--green-ink)]" aria-hidden="true" />
        <span className="eyebrow">REVIEW ASSIGNMENT</span>
        {loading ? (
          <Badge variant="secondary">Loading...</Badge>
        ) : assignment ? (
          <>
            <Badge variant="default" className="max-w-full whitespace-normal break-all text-left">
              {assignment.assignee_email}
            </Badge>
            <Badge variant={PRIORITY_VARIANT[assignment.priority]}>{PRIORITY_LABEL[assignment.priority]}</Badge>
            {assignment.due_at && (
              <>
                <Badge variant="outline">
                  <CalendarClock className="size-3" aria-hidden="true" />
                  Due <time dateTime={assignment.due_at}>{deadlineLabel(assignment.due_at)}</time>
                </Badge>
                {isDueOverdue(assignment.due_at) && <Badge variant="warning">Overdue</Badge>}
              </>
            )}
          </>
        ) : (
          <Badge variant="secondary">Unassigned</Badge>
        )}
      </div>

      <form
        className="grid gap-3 md:grid-cols-[minmax(0,1.5fr)_minmax(130px,0.8fr)_minmax(145px,0.9fr)_auto] md:items-end"
        noValidate
        onSubmit={(e) => void handleSave(e)}
      >
        <label className="field">
          Assignee email
          <Input
            ref={emailField} type="email" list={datalistId} aria-label="Assignee email" value={assigneeEmail} placeholder="reviewer@example.com"
            maxLength={254} disabled={locked} onChange={(e) => setAssigneeEmail(e.target.value)}
          />
          <datalist id={datalistId}>
            {suggestions.map((email) => <option key={email} value={email} />)}
          </datalist>
        </label>

        <label className="field">
          Priority
          <select aria-label="Priority" value={priority} disabled={locked}
            onChange={(e) => setPriority(e.target.value as AssignmentPriority)}>
            <option value="low">Low</option>
            <option value="normal">Normal</option>
            <option value="high">High</option>
          </select>
        </label>

        <label className="field">
          Due date (UTC)
          <Input type="date" aria-describedby={dueHelpId} value={dueDate} disabled={locked} onChange={(e) => setDueDate(e.target.value)} />
        </label>

        <div className="flex flex-wrap items-center gap-2">
          <Button type="submit" size="sm" className="min-h-[44px] md:min-h-8" disabled={locked}>
            {busy === "save" ? "Saving..." : "Save assignment"}
          </Button>
          <Button
            type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8"
            disabled={locked || !assignment} onClick={() => void write(null, assignment, version)}
          >
            <Trash2 className="size-3.5" aria-hidden="true" />
            {busy === "clear" ? "Clearing..." : "Clear assignment"}
          </Button>
          {edited && !review && <Button type="button" variant="ghost" size="sm" className="min-h-[44px] md:min-h-8"
            disabled={!!busy} onClick={discardEdits}>Discard assignment changes</Button>}
        </div>
      </form>
      <small id={dueHelpId}>Changing the date sets the deadline to 23:59:59 UTC. A blank date clears it.</small>

      {!loading && !version && !review && <div className="notice stack" role="status">
        The server did not return an assignment version. Refresh before making changes.
        <Button variant="outline" size="sm" onClick={() => reload()}>Refresh assignment</Button>
      </div>}
      {review && <section className="notice stack" aria-label="Assignment conflict">
        <h3 ref={reviewHeading} tabIndex={-1}>Review assignment changes</h3>
        {latest ? <>
          <p>{review.proposed && latest.assignment
            ? "The assignment changed before your update. The proposal keeps the latest values for fields you left unchanged."
            : "The assignment changed before your update. Review the latest assignment before confirming."}</p>
          <div className="grid gap-2 sm:grid-cols-2">
            <AssignmentValues title="Latest assignment" fields={latest.assignment} />
            <AssignmentValues title="Proposed assignment" fields={reviewedFields(review)} />
          </div>
          <div className="row">
            <Button size="sm" className="min-h-[44px] md:min-h-8" disabled={!!busy} onClick={() => void write(reviewedFields(review), latest.assignment, latest.version)}>
              {review.proposed ? "Save reviewed assignment" : "Confirm clear assignment"}
            </Button>
            <Button variant="outline" size="sm" className="min-h-[44px] md:min-h-8" disabled={!!busy} onClick={() => {
              accept(latest.assignment, latest.version)
              setActionError("")
              setStatusNotice("Kept the latest assignment.")
              requestAnimationFrame(() => emailField.current?.focus())
            }}>Use latest assignment</Button>
          </div>
        </> : busy ? <p role="status">Loading the latest assignment…</p> : <div className="row">
          <Button variant="outline" size="sm" onClick={() => void reloadConflict(review)}>Reload latest assignment</Button>
          <Button variant="ghost" size="sm" onClick={discardEdits}>Discard assignment changes</Button>
        </div>}
      </section>}
      {statusNotice && <p role="status" aria-live="polite" className="notice">{statusNotice}</p>}
      {actionError && <p role="alert" className="error">{actionError}</p>}
    </section>
  )
}
