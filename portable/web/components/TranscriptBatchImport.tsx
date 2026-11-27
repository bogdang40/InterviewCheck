"use client"

import { useRef, useState } from "react"
import { api, message } from "@/lib/api"
import { readCues, transcriptSelection, type Cue } from "@/lib/transcript"
import { useIsomorphicLayoutEffect } from "@/lib/useIsomorphicLayoutEffect"
import { Button } from "./ui/button"
import { TranscriptBatchSelection } from "./TranscriptBatchSelection"
import styles from "./TranscriptBatchImport.module.css"

type Upload = { name: string; fingerprint: string; cues: Cue[]; speakers: string[] }
type ImportResult = { saved: number; skipped: number; answer_ids: string[]; replayed: boolean }
type Preview = ReturnType<typeof transcriptSelection>

export default function TranscriptBatchImport({
  sessionId,
  disabled = false,
  onDirty,
  captureSelection,
  onImported,
}: {
  sessionId: string
  disabled?: boolean
  onDirty: (id: string, value: boolean) => void
  captureSelection: () => () => boolean
  onImported: (summary: ImportResult, maySelect: () => boolean) => void
}) {
  const [file, setFile] = useState<Upload>()
  const [candidate, setCandidate] = useState("")
  const [hosts, setHosts] = useState<string[]>([])
  const [preview, setPreview] = useState<Preview>()
  const [selected, setSelected] = useState<Set<number>>(new Set())
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const [success, setSuccess] = useState("")
  const request = useRef<{ selection: string; id: string } | null>(null)
  const dirty = !!file || busy
  useIsomorphicLayoutEffect(() => {
    onDirty("transcript-import", dirty)
    return () => onDirty("transcript-import", false)
  }, [onDirty, dirty])
  function clear() {
    setFile(undefined)
    setCandidate("")
    setHosts([])
    setPreview(undefined)
    setSelected(new Set())
    setError("")
    request.current = null
  }
  async function read(input?: File) {
    if (!input) return
    setError("")
    setSuccess("")
    setBusy(true)
    try {
      if (input.size > 2_000_000) throw new Error("Select a transcript under 2 MB.")
      const decoder = new TextDecoder("utf-8", { fatal: true })
      let decoded: string
      try {
        decoded = decoder.decode(await input.arrayBuffer())
      } catch {
        throw new Error("Select a WebVTT transcript encoded as UTF-8.")
      }
      const text = decoded.replace(/^\uFEFF/, "").replace(/\r\n?/g, "\n")
      const cues = readCues(text, true)
      const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))
      const fingerprint = Array.from(new Uint8Array(bytes), (byte) =>
        byte.toString(16).padStart(2, "0"),
      ).join("")
      const speakers = [...new Set(cues.map((cue) => cue.speaker))]
      setFile({ name: input.name, fingerprint, cues, speakers })
    } catch (e) {
      setError(message(e))
    } finally {
      setBusy(false)
    }
  }
  function inspect() {
    if (!file || !candidate || !hosts.length) return
    const plan = transcriptSelection(file.cues, candidate, hosts)
    setPreview(plan)
    setError("")
    setSelected(new Set(plan.rows.length <= 100 ? plan.rows.map((row) => row.ordinal) : []))
  }
  function toggle(ordinal: number | null, check: boolean) {
    setSelected((old) => {
      if (ordinal === null) return new Set(check ? preview?.rows.map((row) => row.ordinal) : [])
      const next = new Set(old)
      if (check) next.add(ordinal)
      else next.delete(ordinal)
      return next
    })
  }
  function edit(ordinal: number, key: "question" | "answer", value: string) {
    setPreview(
      (old) =>
        old && {
          ...old,
          rows: old.rows.map((row) => (row.ordinal === ordinal ? { ...row, [key]: value } : row)),
        },
    )
  }
  const rows = preview?.rows.filter((row) => selected.has(row.ordinal)) || []
  const invalid = rows.find(
    (row) =>
      !row.question.trim() || !row.answer.trim() || row.question.length > 4000 || row.answer.length > 24000,
  )
  const exceedsTotal = rows.reduce((n, row) => n + row.question.length + row.answer.length, 0) > 500000
  async function save() {
    if (!file || !preview || busy || disabled || !rows.length || invalid || exceedsTotal) return
    const maySelect = captureSelection()
    setBusy(true)
    setError("")
    try {
      const payload = {
        transcript_sha256: file.fingerprint,
        candidate_speaker: candidate,
        interviewer_speakers: [...hosts].sort(),
        exchanges: rows,
      }
      const selection = JSON.stringify(payload)
      if (request.current?.selection !== selection) request.current = { selection, id: crypto.randomUUID() }
      const result = await api<ImportResult>(`sessions/${sessionId}/imports/webvtt`, "POST", {
        ...payload,
        request_id: request.current.id,
      })
      const omitted = preview.rows.length - selected.size
      setSuccess(`Saved ${result.saved}. Already imported ${result.skipped}. Not selected ${omitted}.`)
      clear()
      onImported(result, maySelect)
    } catch (e) {
      setError(message(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <details className={`panel ${styles.panel}`}>
      <summary>Import transcript exchanges</summary>
      <div className="stack">
        {disabled && <p className="notice">Finish or discard the other draft before importing.</p>}
        {!file ? (
          <label className="field">
            Conversation WebVTT file
            <input
              type="file"
              accept=".vtt,text/vtt"
              disabled={busy || disabled}
              onChange={(e) => {
                const chosen = e.target.files?.[0]
                e.target.value = ""
                void read(chosen)
              }}
            />
          </label>
        ) : (
          <>
            <p className={styles.file}>
              {file.name} · {file.cues.length} cues · {file.speakers.length} speakers
            </p>
            {!preview ? (
              <>
                <label className="field">
                  Candidate in transcript
                  <select
                    value={candidate}
                    disabled={disabled || busy}
                    onChange={(e) => {
                      const name = e.target.value
                      setCandidate(name)
                      setHosts(
                        name && file.speakers.length === 2 ? file.speakers.filter((s) => s !== name) : [],
                      )
                    }}
                  >
                    <option value="">Choose the candidate</option>
                    {file.speakers.map((s) => (
                      <option key={s}>{s}</option>
                    ))}
                  </select>
                </label>
                {candidate && (
                  <fieldset className={styles.speakers} disabled={busy || disabled}>
                    <legend>Interviewers in transcript</legend>
                    {file.speakers
                      .filter((s) => s !== candidate)
                      .map((s) => (
                        <label key={s}>
                          <input
                            type="checkbox"
                            checked={hosts.includes(s)}
                            onChange={(e) => {
                              const checked = e.target.checked
                              setHosts((old) => (checked ? [...old, s] : old.filter((name) => name !== s)))
                            }}
                          />
                          {s}
                        </label>
                      ))}
                  </fieldset>
                )}
                {hosts.length > 24 && (
                  <p role="alert" className="error">
                    Choose at most 24 interviewers.
                  </p>
                )}
                <div>
                  <Button
                    type="button"
                    variant="outline"
                    disabled={disabled || busy || !candidate || !hosts.length || hosts.length > 24}
                    onClick={inspect}
                  >
                    Preview exchanges
                  </Button>
                </div>
              </>
            ) : (
              <>
                <p>
                  <strong>Candidate</strong> {candidate} · <strong>Interviewers</strong> {hosts.join(", ")}
                </p>
                <p className={styles.counts}>
                  {preview.rows.length} paired exchanges. {preview.unprompted} candidate turns without a
                  prompt. {preview.unanswered} prompts without an answer. {preview.excluded} cues from other
                  speakers.
                </p>
                <TranscriptBatchSelection
                  rows={preview.rows}
                  selected={selected}
                  toggle={toggle}
                  edit={edit}
                  busy={busy || disabled}
                />
                <p className={styles.counts}>{selected.size} selected. Import up to 100 exchanges at once.</p>
                {invalid && (
                  <p role="alert" className="error">
                    Check exchange {invalid.ordinal}. Each selected row needs a question of up to 4,000
                    characters and an answer of up to 24,000.
                  </p>
                )}
                {exceedsTotal && (
                  <p role="alert" className="error">
                    Select fewer exchanges. One import can contain up to 500,000 characters.
                  </p>
                )}
                <div className="row">
                  <Button
                    type="button"
                    onClick={save}
                    disabled={disabled || busy || !selected.size || !!invalid || exceedsTotal}
                  >
                    {busy ? "Saving exchanges…" : "Import selected exchanges"}
                  </Button>
                  <Button
                    type="button"
                    variant="ghost"
                    disabled={busy}
                    onClick={() => {
                      setPreview(undefined)
                      setError("")
                    }}
                  >
                    Discard preview and change speakers
                  </Button>
                </div>
              </>
            )}
            <div>
              <Button type="button" variant="ghost" disabled={busy} onClick={clear}>
                Discard import
              </Button>
            </div>
          </>
        )}
        {success && (
          <p role="status" className="notice">
            {success}
          </p>
        )}
        {error && (
          <p role="alert" className="error">
            {error}
          </p>
        )}
      </div>
    </details>
  )
}
