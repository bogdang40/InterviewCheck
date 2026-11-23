"use client"

import Link from "next/link"
import { useEffect, useState } from "react"
import { Download, FileCheck2 } from "lucide-react"
import { api, message } from "@/lib/api"
import { interviewURL } from "@/lib/workspace"
import { Button } from "./ui/button"
import WorkspaceError from "./WorkspaceError"
import "./ReviewBrief.css"

type Exchange = { id: string; ordinal: number; has_answer: boolean; has_note: boolean }
type Block = { kind: "title" | "heading" | "subheading" | "paragraph" | "literal"; text: string }
type Preview = { markdown: string; blocks: Block[]; preview_sha256: string; exchanges: Exchange[] }
type Selection = { excerpt_ids: string[]; note_ids: string[] }
const empty: Selection = { excerpt_ids: [], note_ids: [] }

export default function ReviewBrief({ sessionId }: { sessionId: string }) {
  const [selection, setSelection] = useState<Selection>(empty)
  const [result, setResult] = useState<{ key: string; data: Preview }>()
  const [refresh, setRefresh] = useState(0)
  const [error, setError] = useState("")
  const [statusNote, setStatusNote] = useState("")
  const [downloading, setDownloading] = useState(false)
  const endpoint = "sessions/" + encodeURIComponent(sessionId) + "/brief"
  const key = JSON.stringify(selection) + "/" + refresh
  const current = result?.key === key ? result.data : undefined
  useEffect(() => {
    const controller = new AbortController()
    setError("")
    api<Preview>(endpoint, "POST", selection, controller.signal)
      .then((data) => {
        if (!controller.signal.aborted) {
          setResult({ key, data })
          const ec = selection.excerpt_ids.length
          const nc = selection.note_ids.length
          setStatusNote(
            `Preview updated: ${ec} ${ec === 1 ? "excerpt" : "excerpts"} and ${nc} ${nc === 1 ? "note" : "notes"} included.`
          )
        }
      })
      .catch((error) => {
        if (!controller.signal.aborted) {
          setError(message(error))
          setStatusNote("")
        }
      })
    return () => controller.abort()
  }, [endpoint, key, selection])

  function toggle(field: keyof Selection, id: string) {
    setSelection((last) => ({
      ...last,
      [field]: last[field].includes(id) ? last[field].filter((item) => item !== id) : [...last[field], id],
    }))
  }

  function toggleAll(field: keyof Selection, ids: string[], selected: boolean) {
    setSelection((last) => ({ ...last, [field]: selected ? [] : ids }))
  }

  async function download() {
    if (!current || downloading) return
    setDownloading(true)
    setError("")
    try {
      const response = await fetch("/api/" + endpoint + "/download", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-InterviewCheck": "1" },
        body: JSON.stringify({ ...selection, preview_sha256: current.preview_sha256 }),
      })
      if (!response.ok) {
        const data = await response.json().catch(() => ({}))
        throw new Error(typeof data.detail === "string" ? data.detail : "The download could not be prepared.")
      }
      const url = URL.createObjectURL(await response.blob())
      const link = document.createElement("a")
      link.href = url
      link.download = "review-brief-" + sessionId + ".md"
      document.body.appendChild(link)
      link.click()
      link.remove()
      window.setTimeout(() => URL.revokeObjectURL(url), 1000)
      setStatusNote("Brief downloaded as review-brief-" + sessionId + ".md.")
    } catch (error) {
      setError(message(error))
      setStatusNote("")
    } finally {
      setDownloading(false)
    }
  }

  const choices = result?.data.exchanges || []
  const eligibleExcerpts = choices.filter((row) => row.has_answer).slice(0, 100).map((row) => row.id)
  const eligibleNotes = choices.filter((row) => row.has_note).slice(0, 100).map((row) => row.id)
  const allExcerptsSelected =
    eligibleExcerpts.length > 0 && eligibleExcerpts.every((id) => selection.excerpt_ids.includes(id))
  const allNotesSelected =
    eligibleNotes.length > 0 && eligibleNotes.every((id) => selection.note_ids.includes(id))

  return (
    <div className="brief-layout">
      <header className="brief-heading">
        <div className="page-title">
          <span className="eyebrow">BRIEF</span>
          <h1>Review brief</h1>
          <p>Prepare a summary of passage comparisons and interviewer outcomes.</p>
        </div>
        <Button asChild variant="outline" size="sm">
          <Link href={interviewURL(sessionId)}>Open interview</Link>
        </Button>
      </header>
      <div className="brief-body">
        <aside className="panel brief-options">
          <h2>Included details</h2>
          <p>
            The default brief identifies the session by ID and lists exchange numbers. Names, role, transcript
            and notes are omitted.
          </p>
          <div className="brief-bulk-actions" role="group" aria-label="Quick selection toggles">
            <Button
              type="button"
              size="sm"
              variant={allExcerptsSelected ? "secondary" : "outline"}
              aria-pressed={allExcerptsSelected}
              disabled={downloading || eligibleExcerpts.length === 0}
              onClick={() => toggleAll("excerpt_ids", eligibleExcerpts, allExcerptsSelected)}
            >
              Select all excerpts
            </Button>
            <Button
              type="button"
              size="sm"
              variant={allNotesSelected ? "secondary" : "outline"}
              aria-pressed={allNotesSelected}
              disabled={downloading || eligibleNotes.length === 0}
              onClick={() => toggleAll("note_ids", eligibleNotes, allNotesSelected)}
            >
              Select all notes
            </Button>
          </div>
          <details>
            <summary>Choose excerpts and notes</summary>
            <p>
              Include up to 240 characters of an answer or its full interviewer note. Inspect the preview
              before downloading.
            </p>
            {choices.length ? (
              <div className="brief-choices">
                {choices.map((row) => (
                  <fieldset key={row.id}>
                    <legend>Exchange {row.ordinal}</legend>
                    {(["excerpt_ids", "note_ids"] as const).map((field) => {
                      const checked = selection[field].includes(row.id)
                      const hasText = field === "excerpt_ids" ? row.has_answer : row.has_note
                      return (
                        <label className="check" key={field}>
                          <input
                            type="checkbox"
                            checked={checked}
                            aria-label={`${field === "excerpt_ids" ? "Answer excerpt" : "Interviewer note"} for exchange ${row.ordinal}`}
                            disabled={
                              downloading || (!checked && (!hasText || selection[field].length >= 100))
                            }
                            onChange={() => toggle(field, row.id)}
                          />
                          {field === "excerpt_ids" ? "Answer excerpt" : "Interviewer note"}
                        </label>
                      )
                    })}
                  </fieldset>
                ))}
              </div>
            ) : (
              <p>{result ? "No exchanges recorded." : "Loading exchanges..."}</p>
            )}
            {(selection.excerpt_ids.length > 0 || selection.note_ids.length > 0) && (
              <Button
                type="button"
                className="brief-clear-btn"
                disabled={downloading}
                size="sm"
                variant="ghost"
                onClick={() => setSelection(empty)}
              >
                Clear optional details
              </Button>
            )}
          </details>
          <Button type="button" disabled={!current || downloading || !!error} onClick={download}>
            <Download aria-hidden="true" />
            Download brief
          </Button>
          {error && (
            <WorkspaceError
              text={error}
              retry={() => setRefresh((n) => n + 1)}
              retryLabel="Refresh preview"
            />
          )}
          <p className={statusNote ? "notice brief-status" : "sr-only"} role="status" aria-live="polite">
            {statusNote}
          </p>
        </aside>
        <section className="panel brief-preview" aria-label="Brief preview" aria-busy={!current && !error}>
          <div className="brief-preview-label">
            <FileCheck2 size={16} aria-hidden="true" />
            Preview
          </div>
          {!current && <p role="status">{error ? "Preview unavailable." : "Preparing preview..."}</p>}
          {current?.blocks.map((block, i) => {
            if (block.kind === "title") return <h2 key={i}>{block.text}</h2>
            if (block.kind === "heading") return <h3 key={i}>{block.text}</h3>
            if (block.kind === "subheading") return <h4 key={i}>{block.text}</h4>
            if (block.kind === "literal") return <pre key={i}>{block.text}</pre>
            return <p key={i}>{block.text}</p>
          })}
        </section>
      </div>
    </div>
  )
}
