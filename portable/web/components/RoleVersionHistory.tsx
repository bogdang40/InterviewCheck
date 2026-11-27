"use client"

import { useCallback, useEffect, useRef, useState } from "react"
import { GitCompare, History, RotateCcw, X } from "lucide-react"
import { dateLabel } from "@/lib/api"
import {
  fetchRoleVersions,
  restoreRoleVersion,
  RoleApiError,
  type CalibratedRole,
  type RoleVersionsResponse,
} from "@/lib/roleCalibration"
import RoleVersionComparison from "./RoleVersionComparison"
import { GuideButton } from "./InterviewerGuide"
import { Badge } from "./ui/badge"
import { Button } from "./ui/button"
import { Input } from "./ui/input"

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
  const [restoringVersion, setRestoringVersion] = useState<number | null>(null)
  const [inspected, setInspected] = useState<number | null>(null)
  const restoredVersionRef = useRef<number | null>(null)

  const loadVersions = useCallback(async (signal?: AbortSignal) => {
    setLoading(true)
    setError("")
    try {
      setData(await fetchRoleVersions(role.id, signal))
    } catch (err) {
      if (err instanceof DOMException && err.name === "AbortError") return
      setError(err instanceof Error ? err.message : "Failed to load version history.")
    } finally {
      setLoading(false)
    }
  }, [role.id])

  useEffect(() => {
    setStatus("")
    restoredVersionRef.current = null
  }, [role.id])

  useEffect(() => {
    if (restoredVersionRef.current !== null && role.version_number === restoredVersionRef.current) {
      restoredVersionRef.current = null
      return
    }
    const controller = new AbortController()
    setConflict(false)
    void loadVersions(controller.signal)
    return () => controller.abort()
  }, [loadVersions, role.version, role.version_number])

  async function handleRestore(versionNumber: number) {
    setRestoringVersion(versionNumber)
    setError("")
    setStatus("")
    setConflict(false)
    try {
      const updated = await restoreRoleVersion(role.id, versionNumber, {
        expected_version: role.version,
        change_note: restoreNote.trim(),
      })
      restoredVersionRef.current = updated.version_number ?? null
      setRestoreNote("")
      setInspected(null)
      setStatus(`Restored version ${versionNumber} as version ${updated.version_number ?? "latest"}.`)
      onRestored(updated)
      await loadVersions()
    } catch (err) {
      if (err instanceof RoleApiError && err.status === 409) {
        setConflict(true)
        setError(`Version conflict (409): ${err.message || "The saved role changed before restore."} Reload the latest role before rolling back.`)
      } else {
        setError(err instanceof Error ? err.message : "Failed to restore role version.")
      }
    } finally {
      setRestoringVersion(null)
    }
  }

  const current = data?.versions.find(v => v.version_number === data.current_version_number)

  return (
    <section className="panel stack" aria-label={`Version history for ${role.name}`}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <span className="eyebrow">RUBRIC VERSIONING</span>
          <h2 className="mt-1 flex items-center gap-2">
            <History className="size-5 shrink-0" aria-hidden="true" />
            <span>Version history</span>
          </h2>
          <p className="muted text-sm">{`${role.name} | Current live version: v${data?.current_version_number ?? role.version_number ?? 1}`}</p>
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
      ) : !data?.versions.length ? (
        <p className="muted text-sm">No saved versions found for this role.</p>
      ) : (
        <div className="stack">
          {data.versions.map((entry) => {
            const isLive = entry.version_number === data.current_version_number
            const isInspected = inspected === entry.version_number
            return (
              <div key={entry.id} className="rounded-lg border border-[var(--line)] bg-[var(--subtle)] p-3 stack">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <div className="flex flex-wrap items-center gap-2 min-w-0">
                    <Badge variant={isLive ? "default" : "outline"}>v{entry.version_number}</Badge>
                    {isLive && <Badge variant="success">Live</Badge>}
                    <strong className="text-sm">{entry.change_note || "No change note"}</strong>
                  </div>
                  <div className="flex flex-wrap items-center gap-2">
                    <GuideButton role={entry} historical />
                    <Button type="button" variant="outline" size="sm" disabled={!current} aria-expanded={isInspected} onClick={() => setInspected(isInspected ? null : entry.version_number)}>
                      <GitCompare aria-hidden="true" />
                      {isInspected ? "Hide diff" : "Inspect diff"}
                    </Button>
                    <Button type="button" variant="outline" size="sm" disabled={isLive || restoringVersion !== null} onClick={() => void handleRestore(entry.version_number)}>
                      <RotateCcw aria-hidden="true" />
                      {restoringVersion === entry.version_number ? "Restoring..." : "Restore version"}
                    </Button>
                  </div>
                </div>
                <div className="flex flex-wrap gap-x-4 gap-y-1 text-xs text-[var(--muted)]">
                  <span>Author: {entry.created_by || "local-operator"}</span>
                  <span>{entry.questions.length} questions</span>
                  <span>{entry.rubric.length} rubric criteria</span>
                  {entry.created_at && <span>{dateLabel(entry.created_at)}</span>}
                </div>
                {isInspected && current && <RoleVersionComparison source={entry} current={current} versions={data.versions} />}
              </div>
            )
          })}
        </div>
      )}
    </section>
  )
}
