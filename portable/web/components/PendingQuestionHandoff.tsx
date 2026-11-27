"use client"

import { useCallback, useEffect, useRef, useState } from "react"
import type { Interview } from "@/lib/api"
import { sameSavedMaterial, sameWorksheetContext } from "@/lib/reviewWorksheet"
import { accessLost, type DeferredPage, type DeferredQuestion } from "@/lib/deferredQuestions"
import { saveBlob } from "@/lib/download"
import { ApiError } from "@/lib/http"
import { fetchHandoff, HANDOFF_FILENAME, MAX_HANDOFF_ITEMS, UnsupportedHandoff, UnverifiedHandoff,
  type HandoffChoice, type HandoffPreview } from "@/lib/pendingHandoff"
import { useIsomorphicLayoutEffect } from "@/lib/useIsomorphicLayoutEffect"
import { watchWorksheetAccess } from "@/lib/worksheetPrivacy"
import { Button } from "./ui/button"

type Target = "preview" | "copy" | "download"

export function usePendingQuestionHandoff(session: Interview, enabled: boolean, locked: boolean, report: DeferredPage | null,
                                          onUnavailable: () => void, reload: () => void) {
  const sid = session.id
  const seenSession = useRef(session)
  const [selected, setSelected] = useState<HandoffChoice[]>([])
  const [preview, setPreview] = useState<HandoffPreview | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const [notice, setNotice] = useState("")
  const active = useRef<AbortController | null>(null)
  const area = useRef<HTMLElement>(null)
  const field = useRef<HTMLTextAreaElement>(null)

  const cancelRequest = useCallback(() => {
    active.current?.abort()
    active.current = null
    setBusy(false)
  }, [])
  const invalidate = useCallback((clearSelection = false) => {
    cancelRequest()
    setPreview(null); setError(""); setNotice("")
    if (clearSelection) setSelected([])
  }, [cancelRequest])
  useIsomorphicLayoutEffect(() => {
    invalidate(true)
    return () => active.current?.abort()
  }, [sid, enabled, invalidate])
  useIsomorphicLayoutEffect(() => { if (locked) cancelRequest() }, [locked, cancelRequest])
  useIsomorphicLayoutEffect(() => {
    const previous = seenSession.current
    seenSession.current = session
    if (!selected.length) return
    const changedSource = previous !== session && (!sameWorksheetContext(previous, session) ||
      [...new Set(selected.map(item => item.parent_answer_id))].some(id => {
        const before = previous.answers.find(a => a.id === id), after = session.answers.find(a => a.id === id)
        return !before || !after || !sameSavedMaterial(before, after)
      }))
    const stale = changedSource || selected.some(chosen => {
      const row = report?.items.find(r => r.id === chosen.id)
      return row && (row.status !== "pending" || row.needs_reconfirmation || row.version !== chosen.version ||
        row.question !== chosen.question || row.parent_answer_id !== chosen.parent_answer_id || row.created_at !== chosen.created_at)
    })
    if (stale) {
      invalidate(true)
      setError("A selected question or source changed. Review the queue and select the current questions.")
    }
  }, [session, report, selected, invalidate])
  useEffect(() => {
    const clear = () => invalidate(true)
    const disconnect = () => { invalidate(); setError("Reconnect to preview or transfer a handoff.") }
    const stop = watchWorksheetAccess(sid, clear)
    window.addEventListener("pagehide", clear)
    window.addEventListener("offline", disconnect)
    return () => {
      stop()
      window.removeEventListener("pagehide", clear)
      window.removeEventListener("offline", disconnect)
    }
  }, [sid, invalidate])

  function choose(item: DeferredQuestion, checked: boolean) {
    if (!enabled || locked || item.session_id !== sid || item.status !== "pending" || item.needs_reconfirmation) return
    if (!session.answers.some(a => a.id === item.parent_answer_id)) return
    invalidate()
    setSelected(prior => {
      const remaining = prior.filter(r => r.id !== item.id)
      if (!checked || remaining.length >= MAX_HANDOFF_ITEMS) return remaining
      return [...remaining, { id: item.id, version: item.version, question: item.question,
        created_at: item.created_at, parent_answer_id: item.parent_answer_id }]
    })
  }

  async function act(target: Target) {
    if (active.current || !enabled || locked || !selected.length || (target !== "preview" && !preview)) return
    const shown = target === "preview" ? null : preview
    const controller = new AbortController()
    active.current = controller
    const inView = () => active.current === controller && !controller.signal.aborted &&
      area.current?.isConnected && area.current.closest("details")?.open === true
    setBusy(true); setNotice(""); setError("")
    if (!shown) setPreview(null)
    try {
      if (!navigator.onLine) throw new Error("Reconnect to preview or transfer a handoff.")
      const result = await fetchHandoff(sid, selected, shown, controller.signal)
      if (!inView()) return
      if (!navigator.onLine) throw new Error("Reconnect to preview or transfer a handoff.")
      if (target === "preview") {
        setPreview(result)
        setNotice("Handoff preview ready.")
        return
      }
      if (!shown || !field.current?.isConnected || field.current.value !== result.text) {
        throw new UnverifiedHandoff("The displayed handoff changed. Preview the questions again.")
      }
      if (target === "copy") {
        try {
          if (!navigator.clipboard?.writeText) throw new Error()
          await navigator.clipboard.writeText(result.text)
        } catch {
          if (inView()) setError("Clipboard access failed. Use Download text file to save the verified handoff.")
          return
        }
      } else {
        try {
          saveBlob(new Blob([result.text], { type: "text/plain;charset=utf-8" }), HANDOFF_FILENAME)
        } catch {
          setError("The browser could not download the verified file. You can try Copy text.")
          return
        }
      }
      if (inView()) setNotice(target === "copy" ? "Handoff copied." : "Handoff downloaded.")
    } catch (err) {
      if (!inView()) return
      setPreview(null)
      if (accessLost(err) || (err instanceof ApiError && err.code === "interview-privacy")) {
        invalidate(true); onUnavailable(); return
      }
      if (err instanceof ApiError && err.status === 409) {
        invalidate(true)
        setError("A selected question or source changed. Review the queue and select the current questions.")
        reload()
      } else if (err instanceof UnsupportedHandoff || err instanceof UnverifiedHandoff) setError(err.message)
      else setError(navigator.onLine ? "The handoff could not be verified. Check the connection and preview again."
        : "Reconnect to preview or transfer a handoff.")
    } finally {
      if (active.current === controller) { active.current = null; setBusy(false) }
    }
  }

  return { area, field, selected, preview, busy, error, notice, choose, act, invalidate }
}

export function PendingHandoffControls({ handoff, locked }: { handoff: ReturnType<typeof usePendingQuestionHandoff>; locked: boolean }) {
  return <section ref={handoff.area} aria-label="Pending question handoff" className="panel inset stack">
    <h4>Pending question handoff</h4>
    <p role="status">{handoff.selected.length} of {MAX_HANDOFF_ITEMS} questions selected</p>
    <div className="row flex-wrap">
      <Button type="button" size="sm" variant="outline" disabled={locked || handoff.busy || !handoff.selected.length}
        onClick={() => void handoff.act("preview")}>Preview selected questions</Button>
      {handoff.selected.length > 0 && <Button type="button" size="sm" variant="ghost" onClick={() => handoff.invalidate(true)}>
        Clear selection
      </Button>}
    </div>
    {handoff.preview && <>
      <label className="field">Exact handoff text
        <textarea ref={handoff.field} spellCheck={false} wrap="off" readOnly rows={6} value={handoff.preview.text} />
      </label>
      <div className="row flex-wrap">
        <Button type="button" size="sm" variant="outline" disabled={locked || handoff.busy} onClick={() => void handoff.act("copy")}>Copy text</Button>
        <Button type="button" size="sm" variant="outline" disabled={locked || handoff.busy} onClick={() => void handoff.act("download")}>Download text file</Button>
      </div>
    </>}
    {handoff.error && <p role="alert" className="error">{handoff.error}</p>}
    {handoff.notice && <p role="status">{handoff.notice}</p>}
  </section>
}
