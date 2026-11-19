import { useEffect, useState } from "react"
import { api, message } from "./api"
import { interviewURL } from "./workspace"

export type SearchKind = "role" | "session" | "answer"
export type SearchHit = {
  kind: SearchKind
  id: string
  session_id: string | null
  label: string
  field: string
  snippet: string
}
type Results = { items: SearchHit[]; has_more: boolean }

export function resultURL(item: SearchHit) {
  if (item.kind === "role") return "/roles/?role=" + encodeURIComponent(item.id)
  return interviewURL(item.session_id || item.id, item.kind === "answer" ? item.id : undefined)
}

export function useWorkspaceSearch(query: string, enabled: boolean, kind?: SearchKind) {
  const [result, setResult] = useState<Results | null>(null),
    [error, setError] = useState("")
  const term = query.trim()
  useEffect(() => {
    setResult(null)
    setError("")
    if (!enabled || term.length < 2) return
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      api<Results>(
        "search",
        "POST",
        { query: term, limit: 20, ...(kind ? { kinds: [kind] } : {}) },
        controller.signal,
      )
        .then((r) => {
          if (!controller.signal.aborted) setResult(r)
        })
        .catch((e) => {
          if (!controller.signal.aborted) setError(message(e))
        })
    }, 180)
    return () => {
      window.clearTimeout(timer)
      controller.abort()
    }
  }, [term, enabled, kind])
  return { result, error, pending: enabled && term.length >= 2 && !result && !error }
}
