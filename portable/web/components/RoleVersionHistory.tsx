"use client"

import { useCallback, useEffect, useRef, useState } from "react"
import { GitCompare, History, RotateCcw, X } from "lucide-react"
import { dateLabel } from "@/lib/api"
import { revisionNumber } from "@/lib/revisionNumber"
import {
  fetchRoleVersions,
  restoreRoleVersion,
  RoleApiError,
  type CalibratedRole,
  type RoleVersionsResponse,
} from "@/lib/roleCalibration"
import dynamic from "next/dynamic"
import { GuideButton } from "./InterviewerGuide"
import { Badge } from "./ui/badge"
import { Button } from "./ui/button"
import { Input } from "./ui/input"

const RoleVersionComparison = dynamic(() => import("./RoleVersionComparison"), {
  ssr: false,
  loading: () => <p className="muted" role="status">Opening the comparison...</p>,
})

type Props = {
  role: CalibratedRole
  onRestored: (updated: CalibratedRole) => void
  onConflictReload?: () => void
  onClose?: () => void
}

export default function RoleVersionHistory({ role, onRestored, onConflictReload, onClose }: Props) {
  const [data, setData] = useState<RoleVersionsResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState("")
  const [conflict, setConflict] = useState(false)
  const [status, setStatus] = useState("")
  const [restoreNote, setRestoreNote] = useState("")
  const [restoringVersion, setRestoringVersion] = useState<string | null>(null)
  const [inspected, setInspected] = useState<string | null>(null)
  const restoredVersionRef = useRef<string | null>(null)

  const loadSequence = useRef(0)
  const unavailable = useCallback((message: string) => {
    ++loadSequence.current
    setData(null)
    setInspected(null)
    setLoading(false)
    setError(message)
  }, [])

  const loadVersions = useCallback(async (signal?: AbortSignal) => {
    const request = ++loadSequence.current
    setLoading(true)
    setError("")
    try {
      const history = await fetchRoleVersions(role.id, signal)
      if (signal?.aborted || request !== loadSequence.current) return
      if (history.role_id !== role.id) throw new Error("The history did not match the selected role.")
      setData(history)
    } catch (err) {
      if (signal?.aborted || request !== loadSequence.current) return
      const message = err instanceof Error ? err.message : "Failed to load version history."
      if (err instanceof RoleApiError && [401, 402, 403, 404].includes(err.status)) unavailable(message)
      else setError(message)
    } finally {
      if (!signal?.aborted && request === loadSequence.current) setLoading(false)
    }
  }, [role.id, unavailable])

  useEffect(() => {
    setStatus("")
    restoredVersionRef.current = null
  }, [role.id])

  useEffect(() => {
    if (restoredVersionRef.current !== null && revisionNumber(role.version_number, role.version_number_text) === restoredVersionRef.current) {
      restoredVersionRef.current = null
      return
    }
    const controller = new AbortController()
    setConflict(false)
    void loadVersions(controller.signal)
    return () => controller.abort()
  }, [loadVersions, role.version, role.version_number, role.version_number_text])

  async function handleRestore(versionNumber: string) {
    setRestoringVersion(versionNumber)
    setError("")
    setStatus("")
    setConflict(false)
    try {
      const updated = await restoreRoleVersion(role.id, versionNumber, {
        expected_version: role.version,
        change_note: restoreNote.trim(),
      })
      restoredVersionRef.current = revisionNumber(updated.version_number, updated.version_number_text)
      setRestoreNote("")
      setInspected(null)
      setStatus(`Restored version ${versionNumber} as version ${restoredVersionRef.current || "latest"}.`)
      onRestored(updated)
      await loadVersions()
    } catch (err) {
      if (err instanceof RoleApiError && [401, 402, 403, 404].includes(err.status)) {
        unavailable(err.message)
      } else if (err instanceof RoleApiError && err.status === 409) {
        setConflict(true)
        setError(`Version conflict (409): ${err.message || "The saved role changed before restore."} Reload the latest role before rolling back.`)
      } else {
        setError(err instanceof Error ? err.message : "Failed to restore role version.")
      }
    } finally {
      setRestoringVersion(null)
    }
  }

  const liveNumber = data ? revisionNumber(data.current_version_number, data.current_version_number_text) : revisionNumber(role.version_number, role.version_number_text)

  return (
    <section className="panel stack" aria-label={`Version history for ${role.name}`}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <span className="eyebrow">RUBRIC VERSIONING</span>
          <h2 className="mt-1 flex items-center gap-2">
            <History className="size-5 shrink-0" aria-hidden="true" />
            <span>Version history</span>
          </h2>
          <p className="muted text-sm">{`${role.name} | Current live version: v${liveNumber || "unavailable"}`}</p>
        </div>
        {onClose && (
          <Button type="button" variant="outline" size="sm" onClick={onClose}>
            <X aria-hidden="true" />
            Close history
          </Button>
        )}
      </div>
      <label className="field">
        Rollback note (optional)
        <Input
          value={restoreNote}
          maxLength={300}
          placeholder="Explain why you are rolling back to an earlier version"
          onChange={(e) => setRestoreNote(e.target.value)}
        />
      </label>
      {error && (
        <div className="error stack" role="alert">
          <p>{error}</p>
          {!data && <Button type="button" size="sm" variant="outline" onClick={() => void loadVersions()}>Reload history</Button>}
          {conflict && (
            <div>
              <Button type="button" variant="outline" size="sm" onClick={() => {
                setConflict(false); setError(""); onConflictReload?.(); void loadVersions()
              }}>
                Reload latest role
              </Button>
            </div>
          )}
        </div>
      )}
      {status && (
        <p className="rounded-md border border-[var(--success-line)] bg-[var(--success-bg)] px-3 py-2 text-sm text-[var(--success-text)]" role="status">
          {status}
        </p>
      )}
      {loading && !data ? (
        <p className="muted text-sm" role="status">Loading version history...</p>
      ) : !data && error ? null : !data?.versions.length ? (
        <p className="muted text-sm">No saved versions found for this role.</p>
      ) : (
        <div className="stack">
          {data.versions.map((entry) => {
            const number = revisionNumber(entry.version_number, entry.version_number_text)
            const isLive = number === liveNumber && entry.content_sha256 === data.current_version
            const isInspected = inspected === entry.id
            return (
              <div key={entry.id} className="rounded-lg border border-[var(--line)] bg-[var(--subtle)] p-3 stack">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <div className="flex flex-wrap items-center gap-2 min-w-0">
                    <Badge variant={isLive ? "default" : "outline"}>v{number || "unavailable"}</Badge>
                    {isLive && <Badge variant="success">Live</Badge>}
                    <strong className="text-sm">{entry.change_note || "No change note"}</strong>
                  </div>
                  <div className="flex flex-wrap items-center gap-2">
                    <GuideButton role={entry} historical />
                    <Button type="button" variant="outline" size="sm" disabled={!number} aria-expanded={isInspected} onClick={() => setInspected(isInspected ? null : entry.id)}>
                      <GitCompare aria-hidden="true" />
                      {isInspected ? "Hide diff" : "Inspect diff"}
                    </Button>
                    <Button type="button" variant="outline" size="sm" disabled={!number || isLive || restoringVersion !== null} onClick={() => void handleRestore(number)}>
                      <RotateCcw aria-hidden="true" />
                      {restoringVersion === number ? "Restoring..." : "Restore version"}
                    </Button>
                  </div>
                </div>
                <div className="flex flex-wrap gap-x-4 gap-y-1 text-xs text-[var(--muted)]">
                  <span>Author: {entry.created_by || "local-operator"}</span>
                  <span>{entry.questions.length} questions</span>
                  <span>{entry.rubric.length} rubric criteria</span>
                  {entry.created_at && <span>{dateLabel(entry.created_at)}</span>}
                </div>
                {isInspected && <RoleVersionComparison source={entry} versions={data.versions} onUnavailable={unavailable} />}
              </div>
            )
          })}
        </div>
      )}
    </section>
  )
}
