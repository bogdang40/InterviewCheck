"use client"

import { useCallback, useEffect, useRef, useState } from "react"
import { ArchiveRestore, Download, FileCheck2 } from "lucide-react"
import Link from "next/link"
import { useWorkspaceSearch } from "@/lib/search"
import { useResource } from "@/lib/workspace"
import { dateLabel, message, type Session } from "@/lib/api"
import { extractApiError } from "@/lib/adminModels"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import WorkspaceError from "./WorkspaceError"

type Counts = { new: number; identical: number; conflict: number }
type Preview = {
  roles: Counts
  sessions: Counts
  answers: number
  drafts: number
  assignments: number
  handoff_notes: number
  scorecard_items: number
  trashed: number
  fingerprint: string
  sha256?: string
  conflicts: { kind: string; id: string; label: string }[]
}

async function submitFile(
  action: "preview" | "restore",
  file: File,
  token?: string,
  expectedSha256?: string,
): Promise<Preview> {
  const headers: Record<string, string> = { "Content-Type": "application/json", "X-InterviewCheck": "1" }
  if (token) headers["X-Backup-Preview"] = token
  const checksum = expectedSha256?.trim()
  if (checksum) headers["X-Backup-SHA256"] = checksum
  const response = await fetch("/api/backups/" + action, {
    method: "POST",
    headers,
    body: file,
    cache: "no-store",
  })
  const result = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(extractApiError(result, response.status))
  const headerDigest = response.headers.get("X-Backup-SHA256")?.trim()
  return { ...(result as Preview), sha256: headerDigest || (result as Preview).fingerprint }
}

export default function WorkspaceBackup() {
  const sessions = useResource<{ items: Session[]; total: number }>("interviews/feed?page_size=20")
  const [term, setTerm] = useState("")
  const [chosenLabel, setChosenLabel] = useState("")
  const search = useWorkspaceSearch(term, true, "session")
  const options =
    term.trim().length >= 2
      ? (search.result?.items ?? []).map((r) => ({ id: r.id, label: r.label + " · " + r.snippet }))
      : (sessions.data?.items ?? []).map((s) => ({
          id: s.id,
          label: s.candidate + " · " + s.role + " · " + dateLabel(s.created_at),
        }))
  const [scope, setScope] = useState("")
  const fileInput = useRef<HTMLInputElement>(null)
  const [hydrated, setHydrated] = useState(false)
  const [file, setFile] = useState<File>()
  const [expectedSha256, setExpectedSha256] = useState("")
  const [preview, setPreview] = useState<Preview>()
  const [busy, setBusy] = useState<"preview" | "restore" | null>(null)
  const [error, setError] = useState("")
  const [success, setSuccess] = useState("")
  const selectFile = useCallback((f?: File) => {
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
  }, [selectFile])
  if (sessions.error) return <WorkspaceError text={sessions.error} retry={sessions.reload} />
  const applyAllowed = preview && !preview.conflicts.length && preview.roles.new + preview.sessions.new > 0
  async function submit(action: "preview" | "restore") {
    if (busy || !file || (action === "restore" && !applyAllowed)) return
    setBusy(action)
    setError("")
    setSuccess("")
    try {
      const result = await submitFile(action, file, preview?.fingerprint, expectedSha256)
      if (action === "preview") setPreview(result)
      else {
        setSuccess(
          `Restored ${result.sessions.new} interviews and ${result.roles.new} roles. Skipped ${result.sessions.identical + result.roles.identical} identical records.`,
        )
        setPreview(undefined)
        setFile(undefined)
        setExpectedSha256("")
        if (fileInput.current) fileInput.current.value = ""
        sessions.reload()
      }
    } catch (e) {
      setError(message(e))
      setPreview(undefined)
    } finally {
      setBusy(null)
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
        {(sessions.data?.total ?? 0) > 20 && (
          <label className="field">
            Find an interview
            <Input
              type="search"
              value={term}
              onChange={(e) => setTerm(e.target.value)}
              placeholder="Enter a candidate or role"
            />
          </label>
        )}
        {search.error && (
          <p className="error" role="alert">
            {search.error}
          </p>
        )}
        <label className="field">
          Backup contents
          <select
            value={scope}
            onChange={(e) => {
              setScope(e.target.value)
              setChosenLabel(e.target.selectedOptions[0].text)
            }}
          >
            <option value="">Entire workspace</option>
            {scope && !options.some((o) => o.id === scope) && <option value={scope}>{chosenLabel}</option>}
            {options.map((s) => (
              <option key={s.id} value={s.id}>
                {s.label}
              </option>
            ))}
          </select>
        </label>
        <Button asChild>
          <a
            href={"/api/backups/workspace" + (scope ? "?session_id=" + encodeURIComponent(scope) : "")}
            download
          >
            <Download aria-hidden="true" />
            Download backup
          </a>
        </Button>
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
              setExpectedSha256(e.target.value)
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
                {preview.sha256 || preview.fingerprint}
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
            <p>
              This file contains {preview.answers} captured {preview.answers === 1 ? "exchange" : "exchanges"},{" "}
              {preview.drafts} saved {preview.drafts === 1 ? "draft" : "drafts"},{" "}
              {preview.assignments} review {preview.assignments === 1 ? "assignment" : "assignments"},{" "}
              {preview.handoff_notes} panel handoff {preview.handoff_notes === 1 ? "note" : "notes"} and{" "}
              {preview.scorecard_items} rubric {preview.scorecard_items === 1 ? "score" : "scores"}.{" "}
              {preview.trashed} interviews will remain in Trash.
            </p>
            {!!preview.conflicts.length && (
              <div className="error" role="alert">
                Restore blocked by conflicting records.
                <ul>
                  {preview.conflicts.map((c) => (
                    <li key={c.kind + c.id}>
                      {c.label} · {c.id.slice(0, 8)}
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
              !preview.conflicts.length && <p role="status">All records are already present.</p>
            )}
          </div>
        )}
      </section>
    </div>
  )
}
