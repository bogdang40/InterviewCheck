"use client"

import { useCallback, useEffect, useRef, useState, type FormEvent } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { getAllowance, MAX_ATTEMPTS, saveAllowance, type AttemptAllowance } from "@/lib/adminAllowance"
import { useReportDirty, type DirtyReporter } from "@/lib/dirtyTracking"
import { AdminApiError } from "@/lib/adminModels"

type Draft = { value: string; revision: number }
type Props = { refreshKey: number; onAuthInvalid: (message: string) => void; onDirtyChange: DirtyReporter }

function limitText(limit: number | null) {
  return limit === null ? "" : String(limit)
}

function stamp(iso: string) {
  return iso.slice(0, 16).replace("T", " ") + " UTC"
}

export function UsageAllowance({ refreshKey, onAuthInvalid, onDirtyChange }: Props) {
  const [report, setReport] = useState<AttemptAllowance | null>(null)
  const [draft, setDraft] = useState<Draft | null>(null)
  const [working, setWorking] = useState<"read" | "write" | null>("read")
  const [error, setError] = useState("")
  const [notice, setNotice] = useState("")
  const [unconfirmed, setUnconfirmed] = useState(false)
  const sequence = useRef(0)
  const writing = useRef(false)

  function authError(err: unknown) {
    return err instanceof AdminApiError && (err.status === 401 || err.status === 403)
  }

  const load = useCallback(async (reconcile: boolean) => {
    if (writing.current) return
    const serial = ++sequence.current
    setWorking("read")
    try {
      const next = await getAllowance()
      if (serial !== sequence.current) return
      setReport(next)
      // A normal refresh updates the counter. Only an explicit reload rebases an edit.
      if (reconcile) {
        setUnconfirmed(false)
        setDraft(current => current && { value: current.value, revision: next.revision })
        setNotice("Current policy loaded. Compare it with your entry before saving.")
      }
      setError("")
    } catch (err) {
      if (serial !== sequence.current) return
      if (authError(err)) onAuthInvalid((err as Error).message)
      else setError(err instanceof Error ? err.message : "Could not load the AI attempt allowance.")
    } finally {
      if (serial === sequence.current) setWorking(null)
    }
  }, [onAuthInvalid])

  useEffect(() => { void load(false) }, [load, refreshKey])
  useEffect(() => () => { ++sequence.current }, [])

  const value = draft?.value ?? (report ? limitText(report.monthly_limit) : "")
  const limit = value === "" ? null : Number(value)
  const invalid = value !== "" && (!/^\d+$/.test(value) || !Number.isSafeInteger(limit) || Number(limit) > MAX_ATTEMPTS)
  const stale = !!(report && draft && draft.revision !== report.revision)
  const mustReload = stale || unconfirmed
  useReportDirty(!!draft && (unconfirmed || invalid || limit !== report?.monthly_limit), onDirtyChange)
  const canSave = !!report && !!draft && !invalid && !mustReload && limit !== report.monthly_limit && !working

  async function save(event: FormEvent) {
    event.preventDefault()
    if (!canSave || !draft || writing.current) return
    const serial = ++sequence.current
    writing.current = true
    setWorking("write")
    setError("")
    setNotice("")
    try {
      const next = await saveAllowance(limit, draft.revision)
      if (serial !== sequence.current) return
      setReport(next)
      setDraft(null)
      setNotice("Allowance saved.")
    } catch (err) {
      if (serial !== sequence.current) return
      if (authError(err)) onAuthInvalid((err as Error).message)
      else {
        setUnconfirmed(true)
        setError(err instanceof AdminApiError && err.status === 409
          ? "Another administrator changed the policy."
          : "The save was not confirmed. Check the saved policy before trying again.")
      }
    } finally {
      writing.current = false
      if (serial === sequence.current) setWorking(null)
    }
  }

  return (
    <section className="panel stack" aria-label="Monthly AI attempt allowance">
      <h3>Monthly AI attempt allowance</h3>
      <p className="muted">Counts text generation and embedding attempts, including Playground, retries and fallback models.
        Connection tests and transcription are excluded. A provider timeout uses an attempt.</p>
      {error && <p role="alert" className="error">{error}</p>}
      {!report && working === "read" && <p role="status">Loading allowance...</p>}
      {report && <>
        <p className="admin-mono">{report.month} UTC · {report.used} used · {report.remaining === null ? "Unlimited" : `${report.remaining} remaining`}
          {report.monthly_limit !== null && ` · Saved limit ${report.monthly_limit}`}</p>
        <p className="muted">Resets {stamp(report.next_reset_at)}. Tracking started {stamp(report.tracking_started_at)}.</p>
        <form className="stack" onSubmit={save}>
          <div className="field">
            <label htmlFor="ai-attempt-limit">Monthly attempt limit</label>
            <Input id="ai-attempt-limit" inputMode="numeric" value={value} disabled={working === "write"}
              aria-describedby="ai-attempt-guidance" aria-invalid={invalid}
              onChange={event => {
                setDraft({ value: event.target.value, revision: draft?.revision ?? report.revision })
                setNotice("")
              }} />
            <small className="muted" id="ai-attempt-guidance">Leave blank for unlimited. Enter 0 to pause new attempts.</small>
          </div>
          {invalid && <p role="alert" className="error">Enter a whole number from 0 to {MAX_ATTEMPTS.toLocaleString()}.</p>}
          {mustReload && <p role="status">Reload the saved policy to keep editing. Your entry will stay here.</p>}
          {notice && <p role="status">{notice}</p>}
          <div className="admin-header-actions">
            <Button type="submit" size="sm" disabled={!canSave}>{working === "write" ? "Saving..." : "Save allowance"}</Button>
            {(mustReload || error) && <Button type="button" size="sm" variant="outline" disabled={!!working}
              onClick={() => void load(true)}>Reload saved policy</Button>}
          </div>
        </form>
      </>}
      {!report && error && <Button type="button" size="sm" variant="outline" disabled={!!working}
        onClick={() => void load(false)}>Reload saved policy</Button>}
    </section>
  )
}
