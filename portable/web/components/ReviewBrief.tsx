"use client"

import Link from "next/link"
import { useEffect, useState } from "react"
import { Download, FileCheck2, RotateCcw } from "lucide-react"
import { api, message } from "@/lib/api"
import { interviewURL } from "@/lib/workspace"
import { Button } from "./ui/button"
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
  const [downloading, setDownloading] = useState(false)
  const endpoint = "sessions/" + encodeURIComponent(sessionId) + "/brief"
  const key = JSON.stringify(selection) + "/" + refresh
  const current = result?.key === key ? result.data : undefined
  useEffect(() => {
    const controller = new AbortController()
    setError("")
    api<Preview>(endpoint, "POST", selection, controller.signal)
      .then((data) => {
        if (!controller.signal.aborted) setResult({ key, data })
      })
      .catch((error) => {
        if (!controller.signal.aborted) setError(message(error))
      })
    return () => controller.abort()
  }, [endpoint, key, selection])

  function toggle(field: keyof Selection, id: string) {
    setSelection((last) => ({
      ...last,
      [field]: last[field].includes(id) ? last[field].filter((item) => item !== id) : [...last[field], id],
    }))
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
        const data = await response.json()
        throw new Error(data.detail || "The download could not be prepared.")
      }
      const url = URL.createObjectURL(await response.blob())
      const link = document.createElement("a")
      link.href = url
      link.download = "review-brief-" + sessionId + ".md"
      document.body.appendChild(link)
      link.click()
      link.remove()
      window.setTimeout(() => URL.revokeObjectURL(url), 1000)
    } catch (error) {
      setError(message(error))
    } finally {
      setDownloading(false)
    }
  }

  const choices = result?.data.exchanges || []
  return (
    <div className="brief-layout">
      <header className="brief-heading">
        <div>
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
              <p>{result ? "No exchanges recorded." : "Loading exchanges…"}</p>
            )}
            {(selection.excerpt_ids.length > 0 || selection.note_ids.length > 0) && (
              <Button disabled={downloading} size="sm" variant="ghost" onClick={() => setSelection(empty)}>
                Clear optional details
              </Button>
            )}
          </details>
          <Button disabled={!current || downloading || !!error} onClick={download}>
            <Download />
            Download brief
          </Button>
          {error && (
            <div className="error" role="alert">
              <p>{error}</p>
              <Button variant="outline" size="sm" onClick={() => setRefresh((n) => n + 1)}>
                <RotateCcw />
                Refresh preview
              </Button>
            </div>
          )}
        </aside>
        <section className="panel brief-preview" aria-label="Brief preview" aria-busy={!current && !error}>
          <div className="brief-preview-label">
            <FileCheck2 size={16} />
            Preview
          </div>
          {!current && <p role="status">{error ? "Preview unavailable." : "Preparing preview…"}</p>}
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
