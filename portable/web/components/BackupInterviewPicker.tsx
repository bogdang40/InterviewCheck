import { useEffect, useRef, useState } from "react"
import { api, message } from "@/lib/api"
import type { FeedPage } from "@/lib/bulkArchive"
import { cursorPageStatus, searchIdentity, SEARCH_PAGE_SIZE, useWorkspaceSearch } from "@/lib/search"
import { useDeferredFocus } from "@/lib/useDeferredFocus"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import BackupDownloadLink from "./BackupDownloadLink"
import SearchPageControls from "./SearchPageControls"

type Choice = { id: string; candidate: string; role?: string; created_at?: string }
type BrowsePage = { page: number }
type BrowseReply = { request: BrowsePage; revision: number; data?: FeedPage; error?: string }

function label(choice: Choice, ids?: string[]) {
  return `${choice.candidate || "Unnamed candidate"} · ${searchIdentity({ ...choice, kind: "session" }, ids)}`
}

export default function BackupInterviewPicker({ revision }: { revision: number }) {
  const search = useWorkspaceSearch(true, "session", revision)
  const searching = search.query.trim().length >= 2
  const [request, setRequest] = useState<BrowsePage>({ page: 1 })
  const [reply, setReply] = useState<BrowseReply | null>(null)
  const [choice, setChoice] = useState<Choice | null>(null)
  const select = useRef<HTMLSelectElement>(null)
  const retryButton = useRef<HTMLButtonElement>(null)
  const { requestFocus, completeFocus, cancelFocus } = useDeferredFocus<"contents">()
  const browse = !searching && reply?.request === request && reply.revision === revision ? reply : null
  const page = searching ? search.pageNumber : browse?.data?.page ?? request.page
  const hasNext = searching ? search.hasNext : !!browse?.data && page < browse.data.pages
  const first = browse?.data ? (browse.data.page - 1) * browse.data.page_size + 1 : 0
  const pending = searching ? search.pending : !browse
  const error = searching ? search.error : browse?.error
  const rows: Choice[] = searching
    ? (search.result?.items ?? []).filter(item => item.kind === "session").map(item => ({
        id: item.id, candidate: item.label, role: item.role, created_at: item.created_at,
      }))
    : browse?.data?.items ?? []
  const ids = rows.map(row => row.id)
  if (choice && !ids.includes(choice.id)) ids.push(choice.id)

  useEffect(() => {
    if (searching) return
    const controller = new AbortController()
    api<FeedPage>(`interviews/feed?page_size=${SEARCH_PAGE_SIZE}&page=${request.page}`, "GET", undefined, controller.signal)
      .then(data => { if (!controller.signal.aborted) setReply({ request, revision, data }) })
      .catch(err => { if (!controller.signal.aborted) setReply({ request, revision, error: message(err) }) })
    return () => controller.abort()
  }, [request, revision, searching])

  useEffect(() => {
    if (!pending) completeFocus(() => error ? retryButton.current : select.current)
  }, [pending, error, completeFocus])

  function navigate(next: boolean) {
    requestFocus("contents")
    if (!searching) setRequest({ page: page + (next ? 1 : -1) })
    else if (next) search.next()
    else search.previous()
  }

  return <>
    {((reply?.data?.total ?? 0) > SEARCH_PAGE_SIZE || search.query || error) && <label className="field">
      Find an interview
      <Input type="search" maxLength={160} value={search.query} placeholder="Enter a candidate or role"
        onChange={e => {
          cancelFocus()
          search.setQuery(e.target.value)
          setRequest({ page: 1 })
        }} />
    </label>}
    {error && <div className="stack">
      <p className="error" role="alert">{error}</p>
      <Button type="button" ref={retryButton} size="sm" variant="outline" onClick={() => {
        requestFocus("contents")
        if (searching) search.retry()
        else setRequest({ page })
      }}>Retry interview list</Button>
    </div>}
    <label className="field">
      Backup contents
      <select ref={select} aria-label="Backup contents" aria-busy={pending} value={choice?.id ?? ""}
        onChange={e => {
          if (!e.target.value) setChoice(null)
          else {
            const selected = rows.find(row => row.id === e.target.value)
            if (selected) setChoice(selected)
          }
        }}>
        <option value="">Entire workspace</option>
        {choice && !rows.some(row => row.id === choice.id) && <option value={choice.id}>{label(choice, ids)}</option>}
        {rows.map(row => <option key={row.id} value={row.id} title={label(row)}>{label(row, ids)}</option>)}
      </select>
    </label>
    {choice && <small className="backup-choice-id">Selected interview ID <code>{choice.id}</code></small>}
    {pending ? <p role="status">Loading interviews…</p> : !error && (page > 1 || hasNext || searching) && <p role="status">
      {searching ? cursorPageStatus(page, rows.length, "interview") :
        rows.length ? `Page ${page}. Interviews ${first} to ${first + rows.length - 1}.`
        : "No interviews match on this page."}
    </p>}
    <SearchPageControls label="Backup interview pages" page={page} hasNext={hasNext}
      previous={() => navigate(false)} next={() => navigate(true)} />
    <BackupDownloadLink key={choice?.id ?? "workspace"} sessionId={choice?.id ?? null} />
  </>
}
