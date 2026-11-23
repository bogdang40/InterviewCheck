"use client"

import { type FormEvent, useEffect, useId, useState } from "react"
import { CalendarClock, Trash2, UserCheck } from "lucide-react"
import { message } from "@/lib/api"
import {
  clearSessionAssignment, deadlineLabel, fetchSessionAssignment, isDueOverdue, saveSessionAssignment,
  toDateInputValue, toDueAtIso, type AssignmentPriority, type SessionAssignment,
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

export default function SessionAssignmentBar({ sessionId }: { sessionId: string }) {
  const datalistId = useId()
  const dueHelpId = useId()
  const [assignment, setAssignment] = useState<SessionAssignment | null>(null)
  const [suggestions, setSuggestions] = useState<string[]>([])
  const [assigneeEmail, setAssigneeEmail] = useState("")
  const [priority, setPriority] = useState<AssignmentPriority>("normal")
  const [dueDate, setDueDate] = useState("")
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState("")
  const [actionError, setActionError] = useState("")
  const [statusNotice, setStatusNotice] = useState("")
  const [busy, setBusy] = useState<"save" | "clear" | null>(null)
  const [refreshSeq, setRefreshSeq] = useState(0)

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true)
    setLoadError("")
    fetchSessionAssignment(sessionId, controller.signal)
      .then((res) => {
        if (controller.signal.aborted) return
        setAssignment(res.assignment)
        setSuggestions(res.suggested_reviewers)
        setAssigneeEmail(res.assignment?.assignee_email ?? "")
        setPriority(res.assignment?.priority ?? "normal")
        setDueDate(toDateInputValue(res.assignment?.due_at))
      })
      .catch((err) => { if (!(err instanceof DOMException && err.name === "AbortError")) setLoadError(message(err)) })
      .finally(() => { if (!controller.signal.aborted) setLoading(false) })
    return () => controller.abort()
  }, [sessionId, refreshSeq])

  async function handleSave(e: FormEvent) {
    e.preventDefault()
    if (busy) return
    const trimmedEmail = assigneeEmail.trim().toLowerCase()
    if (!trimmedEmail) return setActionError("Enter an assignee email address.")
    if (!EMAIL_RE.test(trimmedEmail)) return setActionError("Enter a valid email address.")
    setBusy("save")
    setActionError("")
    setStatusNotice("")
    try {
      const saved = await saveSessionAssignment(sessionId, {
        assignee_email: trimmedEmail, priority, due_at: toDueAtIso(dueDate, assignment?.due_at),
      })
      setAssignment(saved)
      setAssigneeEmail(saved.assignee_email)
      setPriority(saved.priority)
      setDueDate(toDateInputValue(saved.due_at))
      setSuggestions((prev) => (prev.includes(saved.assignee_email) ? prev : [saved.assignee_email, ...prev]))
      setStatusNotice(`Assigned to ${saved.assignee_email} (${saved.priority} priority).`)
    } catch (err) {
      setActionError(message(err))
    } finally {
      setBusy(null)
    }
  }

  async function handleClear() {
    if (busy || !assignment) return
    setBusy("clear")
    setActionError("")
    setStatusNotice("")
    try {
      await clearSessionAssignment(sessionId)
      setAssignment(null)
      setAssigneeEmail("")
      setPriority("normal")
      setDueDate("")
      setStatusNotice("Session assignment cleared.")
    } catch (err) {
      setActionError(message(err))
    } finally {
      setBusy(null)
    }
  }

  if (loadError) return <WorkspaceError text={loadError} retry={() => setRefreshSeq((n) => n + 1)} showAccount={false} />

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
            type="email" list={datalistId} value={assigneeEmail} placeholder="reviewer@example.com"
            maxLength={254} disabled={loading || busy !== null} onChange={(e) => setAssigneeEmail(e.target.value)}
          />
          <datalist id={datalistId}>
            {suggestions.map((email) => <option key={email} value={email} />)}
          </datalist>
        </label>

        <label className="field">
          Priority
          <select aria-label="Priority" value={priority} disabled={loading || busy !== null}
            onChange={(e) => setPriority(e.target.value as AssignmentPriority)}>
            <option value="low">Low</option>
            <option value="normal">Normal</option>
            <option value="high">High</option>
          </select>
        </label>

        <label className="field">
          Due date (UTC)
          <Input type="date" aria-describedby={dueHelpId} value={dueDate} disabled={loading || busy !== null} onChange={(e) => setDueDate(e.target.value)} />
        </label>

        <div className="flex flex-wrap items-center gap-2">
          <Button type="submit" size="sm" className="min-h-[44px] md:min-h-8" disabled={loading || busy !== null}>
            {busy === "save" ? "Saving..." : "Save assignment"}
          </Button>
          <Button
            type="button" variant="outline" size="sm" className="min-h-[44px] md:min-h-8"
            disabled={loading || busy !== null || !assignment} onClick={() => void handleClear()}
          >
            <Trash2 className="size-3.5" aria-hidden="true" />
            {busy === "clear" ? "Clearing..." : "Clear assignment"}
          </Button>
        </div>
      </form>
      <small id={dueHelpId}>Changing the date sets the deadline to 23:59:59 UTC. A blank date clears it.</small>

      {statusNotice && <p role="status" aria-live="polite" className="notice">{statusNotice}</p>}
      {actionError && <p role="alert" className="error">{actionError}</p>}
    </section>
  )
}
