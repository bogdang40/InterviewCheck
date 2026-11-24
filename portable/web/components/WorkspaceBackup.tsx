"use client"

import { useCallback, useEffect, useRef, useState } from "react"
import { ArchiveRestore, Download, FileCheck2 } from "lucide-react"
import Link from "next/link"
import { message } from "@/lib/api"
import { canRestore, submitBackup, UncertainRestoreError, type BackupOperation, type BackupPreview } from "@/lib/backupRestore"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import BackupInterviewPicker from "./BackupInterviewPicker"

function joinList(items: string[]) {
  return items.length > 1 ? items.slice(0, -1).join(", ") + " and " + items[items.length - 1] : items[0]
}

function FileContents({ preview }: { preview: BackupPreview }) {
  const fields: [number | undefined, string, string][] = [
    [preview.answers, "captured exchange", "captured exchanges"], [preview.drafts, "saved draft", "saved drafts"],
    [preview.assignments, "review assignment", "review assignments"], [preview.handoff_notes, "panel handoff note", "panel handoff notes"],
    [preview.scorecard_items, "rubric score", "rubric scores"],
  ]
  const known = fields.flatMap(([n, one, many]) => n === undefined ? [] : [`${n} ${n === 1 ? one : many}`])
  const missing = fields.filter(([n]) => n === undefined).map(([, , many]) => many)
  return <p>
    This file contains {joinList(known)}.{" "}
    {preview.trashed} {preview.trashed === 1 ? "interview" : "interviews"} will remain in Trash.
    {missing.length > 0 && <> Counts for {joinList(missing)} were not reported.</>}
  </p>
}

function conflictLabel(label: string, kind: "roles" | "sessions") {
  if (!label) return kind === "roles" ? "Unnamed role" : "Unnamed interview"
  return label.length <= 180 ? label : label.slice(0, 179).replace(/[\uD800-\uDBFF]$/, "") + "…"
}

export default function WorkspaceBackup() {
  const [listRevision, setListRevision] = useState(0)
  const refreshAfterUncertainRestore = useRef(false)
  const fileInput = useRef<HTMLInputElement>(null)
  const active = useRef<AbortController | null>(null)
  const [hydrated, setHydrated] = useState(false)
  const [file, setFile] = useState<File>()
  const [expectedSha256, setExpectedSha256] = useState("")
  const [preview, setPreview] = useState<BackupPreview>()
  const [busy, setBusy] = useState<"preview" | "restore" | null>(null)
  const [error, setError] = useState("")
  const [success, setSuccess] = useState("")
  const selectFile = useCallback((f?: File) => {
    active.current?.abort()
    active.current = null
    setBusy(null)
    setPreview(undefined)
    setError("")
    setSuccess("")
    setFile(undefined)
    if (f && f.size > 20 * 1024 * 1024) {
      setError("Select a file no larger than 20 MiB.")
      return
    }
    setFile(f)
  }, [])
  useEffect(() => {
    setHydrated(true)
    const preselected = fileInput.current?.files?.[0]
    if (preselected) selectFile(preselected)
    return () => { active.current?.abort(); active.current = null }
  }, [selectFile])
  const applyAllowed = !!preview && canRestore(preview)
  async function submit(action: "preview" | "restore") {
    const operation: BackupOperation | null = action === "preview" ? { action } :
      preview && applyAllowed ? { action, preview } : null
    if (active.current || !file || !operation) return
    const controller = new AbortController()
    active.current = controller
    setBusy(action)
    setError("")
    setSuccess("")
    try {
      const result = await submitBackup(file, expectedSha256, operation, controller.signal)
      if (active.current !== controller) return
      if (action === "preview") {
        setPreview(result)
        if (refreshAfterUncertainRestore.current) {
          refreshAfterUncertainRestore.current = false
          setListRevision(n => n + 1)
        }
      } else {
        setSuccess(
          `Restored ${result.sessions.new} interviews and ${result.roles.new} roles. Skipped ${result.sessions.identical + result.roles.identical} identical records.`,
        )
        setPreview(undefined)
        setFile(undefined)
        setExpectedSha256("")
        if (fileInput.current) fileInput.current.value = ""
        refreshAfterUncertainRestore.current = false
        setListRevision(n => n + 1)
      }
    } catch (e) {
      if (active.current !== controller) return
      if (e instanceof UncertainRestoreError) refreshAfterUncertainRestore.current = true
      setError(message(e))
      setPreview(undefined)
    } finally {
      if (active.current === controller) { active.current = null; setBusy(null) }
    }
  }
  return (
    <div className="data-grid">
      <section className="panel data-panel">
        <Download className="data-symbol" size={22} aria-hidden="true" />
        <h2>Download a backup</h2>
        <p>
          Save role plans, interviews, sources, saved drafts and review notes in one JSON file.
          A workspace backup includes records in Trash. JSON saves only the current answer revision.
          A consistent SQLite backup preserves earlier revisions and their attribution.
        </p>
        <p>
          The file contains private interview text. Each panel handoff note includes its text, category,
          author and creation time. The author can be an email address, an external account ID or the local operator.
          Each rubric score includes the criterion, weight, rating, reviewer rationale, who last updated it
          and the update time. For each review assignment, the file includes the assignee email, who assigned
          the review, its priority, due date and last update.
        </p>
        <BackupInterviewPicker revision={listRevision} />
        <small>Accounts, credentials, billing and delivery history stay in their original stores.</small>
        <Link className="text-action" href="/trash/">
          Open Trash
        </Link>
      </section>
      <section className="panel data-panel">
        <ArchiveRestore className="data-symbol" size={22} aria-hidden="true" />
        <h2>Restore from a backup</h2>
        <p>
          Preview the records before importing. Identical records are skipped. If an ID contains different
          data, the restore stops. Each newly restored answer starts its history at the revision saved in the file.
          When you restore a version 1 or 2 backup, new interviews start unassigned and existing assignments stay in place.
          Backups from versions 1 through 3 leave existing panel handoff notes in place.
          Backups from versions 1 through 4 leave existing rubric scorecards in place.
        </p>
        <label className="field">
          Workspace backup file
          <input
            type="file"
            ref={fileInput}
            accept=".json,application/json"
            data-hydrated={hydrated ? "true" : "false"}
            disabled={!!busy}
            onChange={(e) => selectFile(e.target.files?.[0])}
          />
        </label>
        <label className="field">
          Expected SHA-256 checksum (optional)
          <Input
            type="text"
            value={expectedSha256}
            disabled={!!busy}
            placeholder="64-character hex digest"
            spellCheck={false}
            autoComplete="off"
            onChange={(e) => {
              const next = e.target.value
              if (next.trim().toLowerCase() !== expectedSha256.trim().toLowerCase()) setPreview(undefined)
              setExpectedSha256(next)
              setError("")
            }}
          />
        </label>
        <Button variant="outline" disabled={!file || !!busy} onClick={() => submit("preview")}>
          <FileCheck2 aria-hidden="true" />
          {busy === "preview" ? "Checking file…" : "Preview restore"}
        </Button>
        {error && (
          <p className="error" role="alert">
            {error}
          </p>
        )}
        {success && (
          <p className="notice" role="status">
            {success}
          </p>
        )}
        {preview && (
          <div className="restore-plan">
            <h3>Restore preview</h3>
            <div className="field">
              <span>Backup SHA-256 fingerprint</span>
              <code className="code-block" data-testid="backup-sha256">
                {preview.fingerprint}
              </code>
            </div>
            <div className="table-wrap admin-table-wrap">
              <table className="admin-table">
                <caption className="sr-only">Backup record counts</caption>
                <thead>
                  <tr>
                    <th>Records</th>
                    <th>New</th>
                    <th>Identical</th>
                    <th>Conflicts</th>
                  </tr>
                </thead>
                <tbody>
                  {(["roles", "sessions"] as const).map((kind) => (
                    <tr key={kind}>
                      <th data-label="Records">{kind === "roles" ? "Roles" : "Interviews"}</th>
                      <td data-label="New">{preview[kind].new}</td>
                      <td data-label="Identical">{preview[kind].identical}</td>
                      <td data-label="Conflicts">{preview[kind].conflict}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <FileContents preview={preview} />
            {!!preview.conflicts.length && (
              <div className="error" role="alert">
                Restore blocked by conflicting records.
                {preview.roles.conflict + preview.sessions.conflict > preview.conflicts.length && <p>
                  Showing {preview.conflicts.length} of {preview.roles.conflict + preview.sessions.conflict} conflicting records.
                </p>}
                <ul>
                  {preview.conflicts.map((c) => (
                    <li key={c.kind + c.id} className="[overflow-wrap:anywhere]">
                      {conflictLabel(c.label, c.kind)} · {c.id}
                      {c.descriptions.length > 0 && <p className="text-sm">
                        <span className="sr-only">Conflict details. </span>{c.descriptions.join(" · ")}
                      </p>}
                    </li>
                  ))}
                </ul>
              </div>
            )}
            {applyAllowed ? (
              <Button disabled={!!busy} onClick={() => submit("restore")}>
                {busy === "restore" ? "Restoring…" : "Restore new records"}
              </Button>
            ) : (
              !preview.conflicts.length && <p role="status">{preview.roles.identical + preview.sessions.identical > 0
                ? "All records are already present." : "This backup contains no interviews or roles."}</p>
            )}
          </div>
        )}
      </section>
    </div>
  )
}
