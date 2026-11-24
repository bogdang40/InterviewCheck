import { useEffect, useState } from "react"
import { api, dateLabel, message } from "./api"
import { interviewURL } from "./workspace"

export type SearchKind = "role" | "session" | "answer"
export type SearchHit = {
  kind: SearchKind
  id: string
  session_id: string | null
  label: string
  field: string
  snippet: string
  role?: string
  created_at?: string
}
export const SEARCH_PAGE_SIZE = 20
export function cursorPageStatus(page: number, count: number, label: "record" | "interview") {
  return `Page ${page}. ${count} ${label}${count === 1 ? "" : "s"} shown.`
}
type Results = { items: SearchHit[]; has_more: boolean; next_cursor: string | null }
type SearchPage = { query: string; cursors: string[] }
type Reply = { page: SearchPage; revision: number; result?: Results; error?: string }

export function resultURL(item: SearchHit) {
  if (item.kind === "role") return "/roles/?role=" + encodeURIComponent(item.id)
  return interviewURL(item.session_id || item.id, item.kind === "answer" ? item.id : undefined)
}

/** Date, role and ID distinguish equal display names. Exchange IDs also distinguish repeated prompts. */
export function searchIdentity(hit: Pick<SearchHit, "kind" | "id" | "role" | "created_at">, peers?: readonly string[]) {
  const when = hit.created_at && Number.isFinite(Date.parse(hit.created_at)) ? dateLabel(hit.created_at) : ""
  const label = hit.kind === "answer" ? "Exchange" : hit.kind === "role" ? "Role" : "Interview"
  const compact = (id: string) => `${id.slice(0, 8)}…${id.slice(-4)}`
  const unique = peers && !peers.some(id => id !== hit.id && compact(id) === compact(hit.id))
  return [hit.role, when, `${label} ${unique ? compact(hit.id) : hit.id}`].filter(Boolean).join(" · ")
}

export function useWorkspaceSearch(enabled: boolean, kind?: SearchKind, revision = 0) {
  const [page, setPage] = useState<SearchPage>({ query: "", cursors: [""] })
  const [reply, setReply] = useState<Reply | null>(null)
  const term = page.query.trim()
  const current = enabled && reply?.page === page && reply.revision === revision ? reply : null
  const result = current?.result
  const error = current?.error
  useEffect(() => {
    if (!enabled || term.length < 2) return
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      api<Results>(
        "search",
        "POST",
        { query: term, limit: SEARCH_PAGE_SIZE, cursor: page.cursors[page.cursors.length - 1], ...(kind ? { kinds: [kind] } : {}) },
        controller.signal,
      )
        .then((r) => {
          if (controller.signal.aborted) return
          if (!Array.isArray(r?.items) || (r.has_more && (!r.next_cursor || page.cursors.includes(r.next_cursor)))) {
            throw new Error("The search service returned an invalid page.")
          }
          setReply({ page, revision, result: r })
        })
        .catch((e) => {
          if (!controller.signal.aborted) setReply({ page, revision, error: message(e) })
        })
    }, page.cursors.length === 1 ? 180 : 0)
    return () => {
      window.clearTimeout(timer)
      controller.abort()
    }
  }, [term, page, enabled, kind, revision])
  function setQuery(query: string) {
    setPage({ query, cursors: [""] })
  }
  function next() {
    const cursor = result?.next_cursor
    if (result?.has_more && cursor) setPage({ query: page.query, cursors: [...page.cursors, cursor] })
  }
  function previous() {
    if (page.cursors.length > 1) setPage({ query: page.query, cursors: page.cursors.slice(0, -1) })
  }
  return {
    query: page.query, setQuery, result, error, pending: enabled && term.length >= 2 && !current,
    pageNumber: page.cursors.length, hasNext: Boolean(result?.has_more && result.next_cursor), next, previous,
    retry: () => setPage({ ...page }),
  }
}
