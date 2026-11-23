import { useCallback, useEffect, useRef, useState } from "react"
import { DRAFT_KEY_PREFIX, DRAFT_SWEEP_EVENT, draftEpoch, isDraftExpired } from "./localDraftSweep"
import {
  ambiguous, draftStorage, editorDraftKey, latestUnlinked, preserveUnlinked, readRecord, removeRecord,
  type DraftRecord, type LocalDraftPayload,
} from "./localDraftStorage"

export { editorDraftKey, reviewDraftKey, type LocalDraftPayload } from "./localDraftStorage"

export function formatDraftTimestamp(iso: string): string {
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString()
}

export function createDebouncedDraftWriter(key: string, delayMs = 400) {
  const sessionId = key.slice(DRAFT_KEY_PREFIX.length).split(":", 1)[0]
  const storage = draftStorage()
  const currentEpoch = (reserve = false) => {
    try { return storage ? draftEpoch(storage, sessionId, reserve) : null } catch { return null }
  }
  const epoch = currentEpoch(true)
  let invalid = epoch === null
  const valid = () => {
    if (epoch !== currentEpoch()) invalid = true
    return !invalid
  }
  let timer: ReturnType<typeof setTimeout> | undefined
  let pending: LocalDraftPayload | null = null
  let written: DraftRecord | null = null

  function cancel() {
    clearTimeout(timer)
    timer = undefined
    pending = null
    window.removeEventListener("pagehide", flush)
    window.removeEventListener("beforeunload", flush)
  }

  function flush() {
    const data = pending
    cancel()
    if (!data || !storage || !valid() || isDraftExpired(data.savedAt)) return
    if (key === editorDraftKey(sessionId) && ambiguous(preserveUnlinked(sessionId))) return
    try {
      const raw = JSON.stringify(data)
      storage.setItem(key, raw)
      written = { key, raw, data }
    } catch { /* restricted or full storage */ }
  }

  function schedule(data: LocalDraftPayload) {
    if (!valid()) return
    pending = data
    window.addEventListener("pagehide", flush)
    window.addEventListener("beforeunload", flush)
    clearTimeout(timer)
    timer = setTimeout(flush, delayMs)
  }

  function clear(observed: DraftRecord | null = null) {
    cancel()
    removeRecord(written ?? observed)
    written = null
  }

  const invalidate = () => { invalid = true; cancel() }
  return { schedule, flush, cancel, clear, valid, invalidate }
}

export function useLocalDraftRecovery(
  key: string,
  dirty: boolean,
  snapshot: string,
  buildPayload: () => Omit<LocalDraftPayload, "savedAt">,
  matchesServer: (buffered: LocalDraftPayload) => boolean,
) {
  const [recovered, setRecovered] = useState<DraftRecord | null>(null)
  const observed = useRef<DraftRecord | null>(null)
  const writerRef = useRef<ReturnType<typeof createDebouncedDraftWriter> | null>(null)
  const initialRef = useRef(snapshot)
  const edited = useRef(false)
  const restored = useRef(false)

  useEffect(() => {
    initialRef.current = snapshot
    edited.current = false
    restored.current = false
    const sessionId = key.slice(DRAFT_KEY_PREFIX.length).split(":", 1)[0]
    preserveUnlinked(sessionId)
    const writer = createDebouncedDraftWriter(key)
    writerRef.current = writer
    const record = readRecord(key)
    observed.current = ambiguous(record) ? null : record
    setRecovered(observed.current && !matchesServer(observed.current.data) ? observed.current : null)
    const onSweep = (event: Event) => {
      const ids: readonly string[] | null = event instanceof CustomEvent ? event.detail : null
      const swept = event.type === DRAFT_SWEEP_EVENT && (!ids || ids.includes(sessionId))
      if (!swept && writer.valid()) return
      writer.invalidate()
      observed.current = null
      setRecovered(null)
    }
    window.addEventListener(DRAFT_SWEEP_EVENT, onSweep)
    window.addEventListener("storage", onSweep)
    return () => {
      window.removeEventListener(DRAFT_SWEEP_EVENT, onSweep)
      window.removeEventListener("storage", onSweep)
      writer.cancel()
      writerRef.current = null
    }
  }, [key])

  useEffect(() => {
    if (!dirty || (!restored.current && snapshot === initialRef.current)) {
      if (edited.current) {
        writerRef.current?.clear(restored.current ? observed.current : null)
        edited.current = false
        restored.current = false
      }
      return
    }
    edited.current = true
    setRecovered(null)
    writerRef.current?.schedule({ ...buildPayload(), savedAt: new Date().toISOString() })
  }, [dirty, snapshot, key])

  const clear = useCallback(() => {
    writerRef.current?.clear(observed.current)
    edited.current = false
    restored.current = false
    observed.current = null
    setRecovered(null)
  }, [])
  const markRestored = useCallback(() => {
    const current = writerRef.current?.valid() ? readRecord(key) : null
    if (!current || current.raw !== observed.current?.raw) {
      observed.current = ambiguous(current) ? null : current
      setRecovered(observed.current && !matchesServer(observed.current.data) ? observed.current : null)
      return false
    }
    restored.current = true
    setRecovered(null)
    return true
  }, [key, matchesServer])

  return { recovered: recovered?.key === key ? recovered.data : null, clear, markRestored }
}

export function useUnlinkedEditorDraft(sessionId: string) {
  const [record, setRecord] = useState<DraftRecord | null>(null)
  useEffect(() => {
    const load = () => {
      const next = latestUnlinked(sessionId)
      setRecord(previous => previous?.key === next?.key && previous?.raw === next?.raw ? previous : next)
    }
    load()
    window.addEventListener("storage", load)
    window.addEventListener(DRAFT_SWEEP_EVENT, load)
    return () => {
      window.removeEventListener("storage", load)
      window.removeEventListener(DRAFT_SWEEP_EVENT, load)
    }
  }, [sessionId])
  const discardUnlinked = () => {
    removeRecord(record)
    setRecord(latestUnlinked(sessionId))
  }
  return { unlinked: record?.key.startsWith(DRAFT_KEY_PREFIX + sessionId + ":") ? record.data : null, discardUnlinked }
}
