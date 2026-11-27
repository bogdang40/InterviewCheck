import { useEffect, useId, useState } from "react"
import { fetchRoleVersionDiff, RoleApiError, type RoleVersionDetailResponse, type RoleVersionSnapshot } from "@/lib/roleCalibration"
import { revisionNumber } from "@/lib/revisionNumber"
import RoleChangeDetails from "./RoleChangeDetails"

type Snapshot = RoleVersionSnapshot
type Props = { source: Snapshot; versions: Snapshot[]; onUnavailable: (message: string) => void }
type Selection = { number: string; digest: string } | null

function resolvedTarget(reply: RoleVersionDetailResponse): Snapshot {
  const { diff, version } = reply
  return {
    ...version,
    version_number: diff.against_version_number,
    version_number_text: diff.against_version_number_text,
    version: diff.against_version,
    content_sha256: diff.against_version,
    name: diff.changes.name?.live ?? version.name,
    policy: diff.changes.policy?.live ?? version.policy,
    description: diff.changes.description?.live ?? version.description,
    questions: diff.changes.questions?.live ?? version.questions,
    rubric: diff.changes.rubric?.live ?? version.rubric,
    permitted_sources: diff.changes.permitted_sources?.live ?? version.permitted_sources,
  }
}

export default function RoleVersionComparison({ source, versions, onUnavailable }: Props) {
  const labelId = useId()
  const [target, setTarget] = useState<Selection>(null)
  const [result, setResult] = useState<{ key: string; reply: RoleVersionDetailResponse } | null>(null)
  const [failure, setFailure] = useState<{ key: string; message: string } | null>(null)
  const from = revisionNumber(source.version_number, source.version_number_text)
  const to = target?.number
  const expected = target?.digest
  const key = [source.role_id, from, source.content_sha256, to ?? "live", expected].join("/")
  useEffect(() => {
    const controller = new AbortController()
    setFailure(null)
    fetchRoleVersionDiff(source.role_id, from, controller.signal, to).then(reply => {
      if (controller.signal.aborted) return
      const { diff, version } = reply
      const actual = revisionNumber(diff.against_version_number, diff.against_version_number_text)
      if (!actual || reply.role_id !== source.role_id || revisionNumber(version.version_number, version.version_number_text) !== from
          || version.content_sha256 !== source.content_sha256 || !/^[a-f0-9]{64}$/.test(diff.against_version)
          || (to !== undefined && (actual !== to || expected !== diff.against_version))) {
        throw new Error("The selected role revisions changed. Reload the history before comparing them.")
      }
      setResult({ key, reply })
    }).catch(err => {
      if (controller.signal.aborted) return
      const message = err instanceof Error ? err.message : "Could not compare the selected revisions."
      if (err instanceof RoleApiError && [401, 402, 403, 404].includes(err.status)) onUnavailable(message)
      else setFailure({ key, message })
    })
    return () => controller.abort()
  }, [key, source.role_id, from, source.content_sha256, to, expected, onUnavailable])

  const error = failure?.key === key ? failure.message : ""
  const reply = result?.key === key && !error ? result.reply : null
  const after = reply && resolvedTarget(reply)
  const targetNumber = after ? revisionNumber(after.version_number, after.version_number_text) : ""
  const wasLive = reply && targetNumber === revisionNumber(reply.current_version_number, reply.current_version_number_text)
    && reply.current_version === reply.diff.against_version
  return <div className="rounded-md border border-[var(--line)] bg-[var(--surface)] p-3 text-sm stack" role="region" aria-label="Revision comparison">
    <div className="field">
      <label htmlFor={labelId}>Compare revision {from} with</label>
      <select id={labelId} value={to ?? "live"} onChange={event => {
        const value = event.target.value
        const item = versions.find(v => revisionNumber(v.version_number, v.version_number_text) === value)
        setTarget(item ? { number: value, digest: item.content_sha256 } : null)
      }}>
        <option value="live">Live role</option>
        {versions.map(v => {
          const n = revisionNumber(v.version_number, v.version_number_text)
          return n && <option key={v.id} value={n}>{n} · Saved revision</option>
        })}
      </select>
    </div>
    {error && <p className="error" role="alert">{error}</p>}
    {!reply && !error && <p className="muted" role="status">Loading comparison...</p>}
    {reply && after && <>
      <strong>{target === null && wasLive ? `Diff vs live v${targetNumber} (when compared)` : `Comparing v${from} with v${targetNumber}`}</strong>
      {reply.diff.has_changes ? <>
        <p>Changed fields: {reply.diff.changed_fields.map(field => field === "permitted_sources" ? "permitted materials" : field).join(", ")}</p>
        <RoleChangeDetails key={key} before={source} after={after} diff={reply.diff} />
      </> : <p>No content changes between these revisions.</p>}
    </>}
  </div>
}
