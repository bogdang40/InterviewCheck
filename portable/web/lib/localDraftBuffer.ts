import { useCallback, useEffect, useRef, useState } from "react"
import type { Disposition, QuestionOrigin, Source } from "./api"
import { DRAFT_KEY_PREFIX, isDraftExpired } from "./localDraftSweep"

export type LocalDraftPayload = {
  text: string
  disposition?: Disposition
  note?: string
  savedAt: string
  baseRevision?: number
  question?: string
  sources?: Source[]
  origin?: QuestionOrigin
  answerId?: string
}

export const editorDraftKey = (sessionId: string, answerId?: string) => `${DRAFT_KEY_PREFIX}${sessionId}:editor:${answerId ?? "new"}`
export const reviewDraftKey = (sessionId: string, answerId: string) => `${DRAFT_KEY_PREFIX}${sessionId}:review:${answerId}`

function getStorage(): Storage | null {
  if (typeof window === "undefined") return null
  try { return window.localStorage } catch { return null }
}

export function readLocalDraft(key: string): LocalDraftPayload | null {
  const storage = getStorage()
  if (!storage) return null
  try {
    const raw = storage.getItem(key)
    if (!raw) return null
    const data = JSON.parse(raw) as Record<string, unknown> | null
    if (!data || typeof data !== "object" || typeof data.text !== "string" || typeof data.savedAt !== "string") return null
    if (isDraftExpired(data.savedAt)) { storage.removeItem(key); return null }
    return data as unknown as LocalDraftPayload
  } catch { return null }
}

export function writeLocalDraft(key: string, payload: LocalDraftPayload): boolean {
  const storage = getStorage()
  if (!storage) return false
  try { storage.setItem(key, JSON.stringify(payload)); return true } catch { return false }
}

export function clearLocalDraft(key: string): void {
  const storage = getStorage()
  if (!storage) return
  try { storage.removeItem(key) } catch { /* restricted storage */ }
}

export function formatDraftTimestamp(iso: string): string {
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString()
}

export function createDebouncedDraftWriter(key: string, delayMs = 400) {
  let timer: ReturnType<typeof setTimeout> | null = null
  let pending: LocalDraftPayload | null = null
  let bound = false
  const unbind = () => {
    if (!bound || typeof window === "undefined") return
    window.removeEventListener("pagehide", flush)
    window.removeEventListener("beforeunload", flush)
    bound = false
  }
  const flush = () => {
    if (timer !== null) { clearTimeout(timer); timer = null }
    unbind()
    if (pending) { const next = pending; pending = null; writeLocalDraft(key, next) }
  }
  const cancel = () => {
    if (timer !== null) { clearTimeout(timer); timer = null }
    pending = null; unbind()
  }
  const schedule = (payload: LocalDraftPayload) => {
    pending = payload
    if (!bound && typeof window !== "undefined") {
      window.addEventListener("pagehide", flush); window.addEventListener("beforeunload", flush); bound = true
    }
    if (timer !== null) clearTimeout(timer)
    timer = setTimeout(() => { timer = null; flush() }, delayMs)
  }
  return { schedule, flush, cancel }
}

export function useLocalDraftRecovery(
  key: string,
  dirty: boolean,
  snapshot: string,
  buildPayload: () => Omit<LocalDraftPayload, "savedAt">,
  matchesServer: (buffered: LocalDraftPayload) => boolean,
) {
  const [recovered, setRecovered] = useState<LocalDraftPayload | null>(null)
  const writerRef = useRef<ReturnType<typeof createDebouncedDraftWriter> | null>(null)
  const initialRef = useRef(snapshot)
  const wasDirtyRef = useRef(false)
  const restoredRef = useRef(false)

  useEffect(() => {
    initialRef.current = snapshot; wasDirtyRef.current = false; restoredRef.current = false
    const writer = createDebouncedDraftWriter(key, 400)
    writerRef.current = writer
    const buffered = readLocalDraft(key)
    setRecovered(buffered && !matchesServer(buffered) ? buffered : null)
    return () => { writer.cancel(); writerRef.current = null }
  }, [key])

  useEffect(() => {
    if (!restoredRef.current && snapshot === initialRef.current) return
    if (dirty) {
      wasDirtyRef.current = true
      setRecovered(null)
      writerRef.current?.schedule({ ...buildPayload(), savedAt: new Date().toISOString() })
    } else if (wasDirtyRef.current) {
      wasDirtyRef.current = false; restoredRef.current = false
      writerRef.current?.cancel(); clearLocalDraft(key)
    }
  }, [dirty, snapshot, key])

  const clear = useCallback(() => {
    wasDirtyRef.current = false; restoredRef.current = false
    writerRef.current?.cancel(); clearLocalDraft(key); setRecovered(null)
  }, [key])
  const markRestored = useCallback(() => { restoredRef.current = true; setRecovered(null) }, [])

  return { recovered, clear, markRestored }
}
