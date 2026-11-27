import { useId, useRef, useState } from "react"
import { saveBlob } from "@/lib/download"
import { formatDraftTimestamp, useUnlinkedEditorDraft, type LocalDraftPayload } from "@/lib/localDraftBuffer"
import { Button } from "./ui/button"
import { Textarea } from "./ui/textarea"

export default function UnlinkedDraftCopy({ sessionId, legacySavedId, afterDiscard }: {
  sessionId: string
  legacySavedId?: string
  afterDiscard: () => void
}) {
  const { unlinked, discardUnlinked } = useUnlinkedEditorDraft(sessionId, legacySavedId)
  const [inspected, setInspected] = useState<LocalDraftPayload | null>(null)
  const [status, setStatus] = useState("")
  const field = useRef<HTMLTextAreaElement>(null)
  const detailsId = useId()
  if (!unlinked) return null
  const open = inspected === unlinked
  const contents = open ? JSON.stringify(unlinked, null, 2) : ""

  async function copy() {
    try {
      await navigator.clipboard.writeText(contents)
      setStatus("Draft copied.")
    } catch {
      field.current?.focus()
      field.current?.select()
      setStatus("Draft text selected. Use your device’s Copy command.")
    }
  }

  return (
    <section className="notice stack" aria-label="Unlinked local draft">
      <strong>Unlinked local draft</strong>
      <p>This browser saved a copy on <time dateTime={unlinked.savedAt}>{formatDraftTimestamp(unlinked.savedAt)}</time>.
        {" "}The original draft lifetime cannot be verified. Inspect the copy separately.</p>
      <div className="row">
        <Button type="button" variant="outline" size="sm" aria-expanded={open} aria-controls={detailsId}
          onClick={() => { setInspected(open ? null : unlinked); setStatus("") }}>
          {open ? "Hide local copy" : "Inspect local copy"}
        </Button>
      </div>
      <div id={detailsId} hidden={!open}>
        {open && <div className="stack">
          <label className="field">
            Complete local draft (JSON)
            <Textarea ref={field} className="h-44 font-mono text-sm" readOnly value={contents} spellCheck={false} />
          </label>
          <div className="row">
            <Button type="button" size="sm" variant="outline" onClick={copy}>Copy draft</Button>
            <Button type="button" size="sm" variant="outline" onClick={() => {
              saveBlob(new Blob([contents], { type: "application/json" }), "unlinked-interview-draft.json")
            }}>Download JSON</Button>
            <Button type="button" size="sm" variant="ghost" onClick={() => {
              discardUnlinked()
              setInspected(null)
              afterDiscard()
            }}>Discard unlinked copy</Button>
          </div>
          {status && <p role="status">{status}</p>}
        </div>}
      </div>
    </section>
  )
}
