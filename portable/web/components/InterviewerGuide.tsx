"use client"

import { useId, useLayoutEffect, useMemo, useRef, useState } from "react"
import { Download } from "lucide-react"
import { saveBlob } from "@/lib/download"
import { guideDocument, guideStyles, type GuideRole } from "@/lib/interviewerGuide"
import { Button } from "./ui/button"

export function GuideButton({ role, disabled = false, historical = false }: {
  role: GuideRole; disabled?: boolean; historical?: boolean
}) {
  const [selection, setSelection] = useState<GuideRole | null>(null)
  return <>
    <Button type="button" size="sm" variant="outline" disabled={disabled} onClick={() => setSelection(role)}
      aria-label={historical ? `Preview interviewer guide for revision ${role.version_number}` : undefined}>
      {historical ? "Preview guide" : "Preview interviewer guide"}
    </Button>
    {selection && <InterviewerGuide role={selection} close={() => setSelection(null)} />}
  </>
}

function InterviewerGuide({ role, close }: { role: GuideRole; close: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null)
  const preview = useRef<HTMLDivElement>(null)
  const heading = useId()
  const [rubric, setRubric] = useState(false)
  const [materials, setMaterials] = useState(false)
  const doc = useMemo(() => guideDocument(role, { rubric, materials }), [role, rubric, materials])

  useLayoutEffect(() => {
    const el = dialog.current
    if (!el) return
    const trigger = document.activeElement
    el.showModal()
    return () => {
      el.close()
      if (trigger instanceof HTMLElement && trigger.isConnected) trigger.focus()
    }
  }, [])

  useLayoutEffect(() => {
    const content = doc.body.firstElementChild
    if (content) preview.current?.replaceChildren(...Array.from(content.children, child => child.cloneNode(true)))
  }, [doc])

  function download() {
    const file = new Blob(["<!doctype html>\n", doc.documentElement.outerHTML], { type: "text/html;charset=utf-8" })
    saveBlob(file, `interviewer-guide-v${role.version_number ?? 1}.html`)
  }

  return (
    <dialog ref={dialog} aria-labelledby={heading} onCancel={(event) => { event.preventDefault(); close() }}
      className="m-auto max-h-[90dvh] w-[min(48rem,95vw)] overflow-auto rounded-lg border border-[var(--line)] bg-[var(--surface)] p-4 text-[var(--ink)] backdrop:bg-black/50">
      <div className="stack">
        <div className="spread flex-wrap gap-2">
          <h2 id={heading}>Offline interviewer guide</h2>
          <Button type="button" variant="outline" size="sm" onClick={close}>Close guide</Button>
        </div>
        <p className="muted">The downloaded HTML contains the preview below. Open it offline or print it from your browser.</p>
        <fieldset className="stack">
          <legend>Include in the guide</legend>
          <label className="row">
            <input type="checkbox" checked={rubric} disabled={!role.rubric?.length} onChange={e => setRubric(e.target.checked)} />
            Grading rubric ({role.rubric?.length ?? 0})
          </label>
          <label className="row">
            <input type="checkbox" checked={materials} disabled={!role.permitted_sources.length} onChange={e => setMaterials(e.target.checked)} />
            Permitted materials ({role.permitted_sources.length})
          </label>
        </fieldset>
        <div><Button type="button" onClick={download}><Download size={16} aria-hidden="true" />Download guide</Button></div>
        <style>{guideStyles}</style>
        <div role="region" aria-label="Guide preview" className="interviewer-guide" ref={preview} />
      </div>
    </dialog>
  )
}
