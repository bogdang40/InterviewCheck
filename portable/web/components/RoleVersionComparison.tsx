import { useEffect, useId, useState } from "react"
import { fetchRoleVersionDiff, type RoleVersionDiff, type RoleVersionSnapshot } from "@/lib/roleCalibration"
import RoleChangeDetails from "./RoleChangeDetails"

type Props = { source: RoleVersionSnapshot; versions: RoleVersionSnapshot[]; current: RoleVersionSnapshot }

export default function RoleVersionComparison({ source, versions, current }: Props) {
  const labelId = useId()
  const [target, setTarget] = useState(current)
  const [result, setResult] = useState<{ key: string; diff: RoleVersionDiff; liveNumber: number } | null>(null)
  const [failure, setFailure] = useState<{ key: string; message: string } | null>(null)
  const key = [source.role_id, source.version_number, source.content_sha256, target.version_number, target.content_sha256].join("/")
  useEffect(() => {
    const controller = new AbortController()
    setFailure(null)
    fetchRoleVersionDiff(source.role_id, source.version_number, controller.signal, target.version_number)
      .then(data => {
        if (controller.signal.aborted) return
        if (data.role_id !== source.role_id || data.version.version_number !== source.version_number
          || data.version.content_sha256 !== source.content_sha256 || data.diff.against_version_number !== target.version_number
          || data.diff.against_version !== target.content_sha256) {
          throw new Error("The saved revisions changed. Reload the history before comparing them.")
        }
        setResult({ key, diff: data.diff, liveNumber: data.current_version_number })
      }).catch(err => {
        if (!controller.signal.aborted) setFailure({ key, message: err instanceof Error ? err.message : "Could not compare the selected revisions." })
      })
    return () => controller.abort()
  }, [key, source.role_id, source.version_number, source.content_sha256, target.version_number, target.content_sha256])

  const error = failure?.key === key ? failure.message : ""
  const loaded = result?.key === key && !error ? result : null
  return <div className="rounded-md border border-[var(--line)] bg-[var(--surface)] p-3 text-sm stack" role="region" aria-label="Revision comparison">
    <div className="field">
      <label htmlFor={labelId}>Compare revision {source.version_number} with</label>
      <select id={labelId} value={target.version_number} onChange={event => {
        const selected = versions.find(item => item.version_number === Number(event.target.value))
        if (selected) setTarget(selected)
      }}>
        {versions.map(v => <option key={v.id} value={v.version_number}>Revision {v.version_number}</option>)}
      </select>
    </div>
    {error && <p className="error" role="alert">{error}</p>}
    {!loaded && !error && <p className="muted" role="status">Loading comparison...</p>}
    {loaded && <>
      <strong>{loaded.liveNumber === target.version_number && current.version_number === target.version_number
        ? `Diff vs live v${target.version_number}` : `Comparing v${source.version_number} with v${target.version_number}`}</strong>
      {loaded.diff.has_changes ? <>
        <p>Changed fields: {loaded.diff.changed_fields.join(", ")}</p>
        <RoleChangeDetails key={key} before={source} after={target} diff={loaded.diff} />
      </> : <p>No content changes between these revisions.</p>}
    </>}
  </div>
}
