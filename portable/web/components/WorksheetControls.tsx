"use client"

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react"
import { message, WorksheetUnavailable } from "@/lib/api"
import { saveBlob } from "@/lib/download"
import {
  currentWorksheet, type Disclosure, readWorksheetFile, verifyWorksheet, type Worksheet, type WorksheetState, worksheetText,
} from "@/lib/reviewWorksheet"
import { watchWorksheetAccess } from "@/lib/worksheetPrivacy"
import { Button } from "./ui/button"

import type { WorksheetProps } from "./ReviewWorksheet"

type Imported = { file: Worksheet; state: WorksheetState }

export default function WorksheetControls({ item, ordinal, session, editorBusy, stage, onDenied, open }: WorksheetProps & { open: boolean }) {
  const [fields, setFields] = useState<Disclosure>({ question: false, excerpt: false })
  const [exportText, setExportText] = useState("")
  const [imported, setImported] = useState<Imported | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const [notice, setNotice] = useState("")
  const active = useRef<AbortController | null>(null)
  const busyEditor = useRef(editorBusy)
  busyEditor.current = editorBusy

  const clear = useCallback(() => {
    active.current?.abort()
    active.current = null
    setBusy(false); setError(""); setNotice(""); setExportText(""); setImported(null)
  }, [])
  useLayoutEffect(() => { if (!open) clear() }, [open, clear])
  useEffect(() => {
    const stop = watchWorksheetAccess(session.id, () => { clear(); setFields({ question: false, excerpt: false }) })
    return () => { stop(); active.current?.abort() }
  }, [session.id, clear])

  async function action(fn: (signal: AbortSignal) => Promise<void>) {
    active.current?.abort()
    const controller = new AbortController()
    active.current = controller
    setBusy(true); setNotice(""); setError("")
    try { await fn(controller.signal) }
    catch (e) {
      if (!controller.signal.aborted) {
        setExportText(""); setImported(null); setError(message(e))
        if (e instanceof WorksheetUnavailable) onDenied()
      }
    } finally {
      if (!controller.signal.aborted) setBusy(false)
    }
  }

  function prepare(target: "preview" | "file" | "copy") {
    void action(async signal => {
      const current = await currentWorksheet(session, item, ordinal, signal)
      signal.throwIfAborted()
      const text = worksheetText(current, fields)
      if (target === "preview" || text !== exportText) {
        setImported(null); setExportText(text)
        if (target !== "preview") setNotice("The saved review changed. Check the new preview before transferring it.")
        return
      }
      if (target === "copy") {
        if (!navigator.clipboard?.writeText) throw new Error("Clipboard access is unavailable. Download the text file.")
        await navigator.clipboard.writeText(text)
      } else saveBlob(new Blob([text], { type: "text/plain;charset=utf-8" }), `exchange-${ordinal}-worksheet.txt`)
      if (!signal.aborted) setNotice(target === "copy" ? "Worksheet copied." : "Worksheet downloaded.")
    })
  }

  function inspect(file: File) {
    clear()
    void action(async signal => {
      const doc = await readWorksheetFile(file)
      signal.throwIfAborted()
      if (doc.sessionId !== session.id || doc.answerId !== item.id || doc.ordinal !== ordinal) {
        throw new Error("Open the exchange named by this worksheet before importing it.")
      }
      const current = await currentWorksheet(session, item, ordinal, signal)
      signal.throwIfAborted()
      verifyWorksheet(doc, current)
      setImported({ file: doc, state: current })
    })
  }

  function stageNote() {
    if (!imported || busyEditor.current) return
    void action(async signal => {
      const { file, state } = imported
      const current = await currentWorksheet(session, item, ordinal, signal)
      signal.throwIfAborted()
      verifyWorksheet(file, current)
      if (current.review !== state.review) {
        setImported({ file, state: current })
        setNotice("The saved review changed again. Compare the current note before staging yours.")
        return
      }
      if (busyEditor.current) {
        setNotice("Finish the open editor change before staging a worksheet.")
        return
      }
      if (file.note === current.answer.note) {
        setNotice("This note is already saved.")
        return
      }
      setImported(null); setExportText("")
      stage(current, file.note)
    })
  }

  return <>
    <p className="muted">Take one exchange to a text editor. The default file contains return metadata.
      Copies outside InterviewCheck remain there after signout, Trash or retention.</p>
    <label className="check"><input type="checkbox" checked={fields.question} onChange={e => { clear(); setFields({ ...fields, question: e.target.checked }) }} /><span>Include the question</span></label>
    <label className="check"><input type="checkbox" checked={fields.excerpt} onChange={e => { clear(); setFields({ ...fields, excerpt: e.target.checked }) }} /><span>Include the first 240 characters of the answer</span></label>
    <div className="row"><Button type="button" variant="outline" disabled={busy} onClick={() => prepare("preview")}>Preview worksheet</Button></div>
    {exportText && <>
      <label className="field">Exact worksheet contents
        <textarea readOnly rows={8} value={exportText} spellCheck={false} />
      </label>
      <div className="row">
        <Button type="button" variant="outline" disabled={busy} onClick={() => prepare("file")}>Download text file</Button>
        <Button type="button" variant="outline" disabled={busy} onClick={() => prepare("copy")}>Copy worksheet</Button>
      </div>
    </>}
    <label className="field">Import completed worksheet
      <input type="file" accept=".txt,text/plain" onChange={event => {
        const file = event.target.files?.[0]; event.target.value = ""
        if (file) inspect(file)
      }} />
    </label>
    {imported && <section className="stack" aria-label="Worksheet note comparison">
      {(imported.file.review !== imported.state.review || imported.file.revision !== imported.state.answer.revision)
        && <p className="notice">The saved review differs from the exported version.</p>}
      <div><strong>Currently saved note</strong><p className="transcript-text">{imported.state.answer.note || "No saved note."}</p></div>
      <div><strong>Proposed note</strong><p className="transcript-text">{imported.file.note}</p></div>
      <p className="muted">Staging opens the note in the review editor. Save review applies it.</p>
      {editorBusy && <p role="status">Save or discard the current edit before staging a note.</p>}
      {imported.file.note === imported.state.answer.note ? <p role="status">This note is already saved.</p>
        : <Button type="button" variant="outline" disabled={busy || editorBusy} onClick={stageNote}>Stage proposed note</Button>}
    </section>}
    {busy && <p role="status">Checking the saved exchange...</p>}
    {error && <p role="alert" className="error">{error}</p>}
    {notice && <p role="status">{notice}</p>}
  </>
}
