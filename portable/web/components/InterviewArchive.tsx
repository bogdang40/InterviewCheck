import Link from "next/link"
import { useEffect, useMemo, useState } from "react"
import { useSearchParams } from "next/navigation"
import { ArrowUpRight, Archive, Columns2, Plus, Search, X } from "lucide-react"
import { message } from "@/lib/api"
import {
  bulkArchive, bulkExport, bulkTag, fetchWorkspaceTags, mergeWorkspaceTags, pruneSelection, toggleSelection,
  type BulkExportFormat, type FeedPage, type WorkspaceTag,
} from "@/lib/bulkArchive"
import { buildComparePageUrl } from "@/lib/compareInterviews"
import type { SessionSort } from "@/lib/interview-list"
import { useResource } from "@/lib/workspace"
import BulkArchiveToolbar from "./BulkArchiveToolbar"
import styles from "./BulkArchiveToolbar.module.css"
import ReportExport from "./ReportExport"
import SessionRow from "./SessionRow"
import WorkspaceError from "./WorkspaceError"
import { Button } from "./ui/button"
import { Input } from "./ui/input"

const states = new Set(["active", "finished", "archived"])
const reviewStates = new Set(["pending", "clear"])
const sorts = new Set(["newest", "oldest", "candidate", "pending"])
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const filterKeys = ["q", "status", "review", "role_id", "tag", "sort", "page"] as const
type Filter = (typeof filterKeys)[number]

function setFilter(key: Filter | null, value = "") {
  const url = new URL(window.location.href)
  if (key !== "page") url.searchParams.delete("page")
  if (key === null) filterKeys.forEach((name) => url.searchParams.delete(name))
  else if (value && !(key === "sort" && value === "newest") && !(key === "page" && value === "1"))
    url.searchParams.set(key, value)
  else url.searchParams.delete(key)
  const destination = url.pathname + url.search + url.hash
  if (key === "page") window.history.pushState(null, "", destination)
  else window.history.replaceState(null, "", destination)
}

export default function InterviewArchive({
  onCreate,
  onReady,
}: {
  onCreate: () => void
  onReady?: () => void
}) {
  const params = useSearchParams()
  const [query, setQuery] = useState(params.get("q") || "")
  const [tagInput, setTagInput] = useState(params.get("tag") || "")
  useEffect(() => {
    const sp = new URLSearchParams(window.location.search)
    setQuery(sp.get("q") || "")
    setTagInput(sp.get("tag") || "")
  }, [params])
  const status = states.has(params.get("status") || "") ? params.get("status")! : ""
  const review = reviewStates.has(params.get("review") || "") ? params.get("review")! : ""
  const rawRoleId = params.get("role_id") || ""
  const roleId = UUID_RE.test(rawRoleId) ? rawRoleId : ""
  const sort = sorts.has(params.get("sort") || "") ? (params.get("sort") as SessionSort) : "newest"
  const requestedPage = Number(params.get("page") || 1)
  const page = Number.isSafeInteger(requestedPage) && requestedPage > 0 && requestedPage <= 2147483647 ? requestedPage : 1
  const [search, setSearch] = useState(query)
  const [tagSearch, setTagSearch] = useState(tagInput)
  useEffect(() => {
    const t = window.setTimeout(() => { setSearch(query); setTagSearch(tagInput) }, 140)
    return () => window.clearTimeout(t)
  }, [query, tagInput])

  const trimmedTag = tagSearch.trim().slice(0, 32)
  const criteria = new URLSearchParams({
    q: search.slice(0, 160), status, review, sort, page: String(page),
    ...(roleId ? { role_id: roleId } : {}),
    ...(trimmedTag ? { tag: trimmedTag } : {}),
  })
  const resource = useResource<FeedPage>("interviews/feed?" + criteria.toString())
  const rolesResource = useResource<Array<{ id: string; name: string }>>("roles")
  const data = search === query && tagSearch === tagInput ? resource.data : null
  useEffect(() => {
    if (resource.data !== null || resource.error !== "") onReady?.()
  }, [resource.data, resource.error, onReady])
  const [workspaceTags, setWorkspaceTags] = useState<WorkspaceTag[] | null>(null)
  const [tagsRefresh, setTagsRefresh] = useState(0)
  useEffect(() => {
    const controller = new AbortController()
    fetchWorkspaceTags(controller.signal)
      .then(setWorkspaceTags)
      .catch((err) => { if (!(err instanceof DOMException && err.name === "AbortError")) setWorkspaceTags(null) })
    return () => controller.abort()
  }, [tagsRefresh])

  const [selectedIds, setSelectedIds] = useState<string[]>([])
  const [bulkBusy, setBulkBusy] = useState(false)
  const [bulkError, setBulkError] = useState("")
  const [bulkNotice, setBulkNotice] = useState("")
  const [archivedCount, setArchivedCount] = useState(0)

  const visibleIds = useMemo(() => (data?.items ?? []).map((item) => item.id), [data])
  const selectedSet = useMemo(() => new Set(selectedIds), [selectedIds])
  const availableTags = useMemo(
    () => mergeWorkspaceTags(workspaceTags, data?.items ?? [], trimmedTag),
    [workspaceTags, data, trimmedTag],
  )
  useEffect(() => setSelectedIds((prev) => pruneSelection(prev, visibleIds)), [visibleIds])

  const changed = Boolean(query || status || review || roleId || tagInput.trim() || sort !== "newest" || page !== 1)
  const first = data ? (data.page - 1) * data.page_size + 1 : 0
  const last = data ? first + data.items.length - 1 : 0
  const count = !data
    ? "Loading interviews…"
    : data.pages === 1
      ? `${data.filtered} of ${data.total} shown`
      : `${first} to ${last} of ${data.filtered} matching interviews`

  async function runBulk(fn: () => Promise<void>, rethrow = false) {
    setBulkBusy(true)
    setBulkError("")
    setBulkNotice("")
    setArchivedCount(0)
    try {
      await fn()
    } catch (e) {
      setBulkError(message(e))
      if (rethrow) throw e
    } finally {
      setBulkBusy(false)
    }
  }

  const handleBulkTag = (add: string[], remove: string[]) =>
    runBulk(async () => {
      const res = await bulkTag(selectedIds, add, remove)
      resource.update((prev) => ({
        ...prev,
        items: prev.items.map((item) =>
          res.tags_by_session[item.id] ? { ...item, tags: res.tags_by_session[item.id] } : item,
        ),
      }))
      setBulkNotice(`Updated tags on ${res.updated} ${res.updated === 1 ? "interview" : "interviews"}.`)
      setTagsRefresh((n) => n + 1)
      resource.reload()
    }, true)

  const handleBulkExport = (format: BulkExportFormat) =>
    runBulk(async () => {
      const filename = await bulkExport(selectedIds, format)
      setBulkNotice(`Exported ${selectedIds.length} ${selectedIds.length === 1 ? "interview" : "interviews"} to ${filename}.`)
    })

  const handleBulkArchive = (confirmCount: number) =>
    runBulk(async () => {
      const res = await bulkArchive(selectedIds, confirmCount)
      setSelectedIds([])
      setArchivedCount(res.archived)
      setBulkNotice(`Moved ${res.archived} ${res.archived === 1 ? "interview" : "interviews"} to Trash.`)
      setTagsRefresh((n) => n + 1)
      resource.reload()
    }, true)

  const compareHref = selectedIds.length >= 2 ? buildComparePageUrl(selectedIds) : "/interviews/compare/"

  return (
    <div className="interview-archive">
      <div className="archive-heading">
        <div>
          <h1>Interviews</h1>
          <p>Find an interview by candidate, role, capture status or pending evidence.</p>
        </div>
        <div className="row">
          <Button asChild variant="ghost" size="sm"><a href="/trash/">Trash</a></Button>
          <Button asChild variant="outline" size="sm">
            <Link href={compareHref}><Columns2 aria-hidden="true" />Compare</Link>
          </Button>
          <ReportExport />
          <Button onClick={onCreate}><Plus />New interview</Button>
        </div>
      </div>
      <section className="panel queue-panel" aria-labelledby="archive-list-heading">
        <div className="queue-head">
          <h2 id="archive-list-heading">All interviews</h2>
          <span className="result-count" role="status" aria-live="polite">{count}</span>
        </div>
        <div className="archive-filters">
          <label className="field archive-search">
            Search interviews
            <span>
              <Search size={16} aria-hidden="true" />
              <input
                type="search" maxLength={160} placeholder="Candidate or role" value={query}
                onChange={(e) => { setQuery(e.target.value); setFilter("q", e.target.value) }}
              />
            </span>
          </label>
          <label className="field">
            Capture status
            <select value={status} onChange={(e) => setFilter("status", e.target.value)}>
              <option value="">All statuses</option>
              <option value="active">In progress</option>
              <option value="finished">Finished</option>
              <option value="archived">Archive only</option>
            </select>
          </label>
          <label className="field">
            Evidence review
            <select value={review} onChange={(e) => setFilter("review", e.target.value)}>
              <option value="">All reviews</option>
              <option value="pending">Has pending matches</option>
              <option value="clear">No pending matches</option>
            </select>
          </label>
          <label className="field">
            Role
            <select aria-label="Filter by role" value={roleId} onChange={(e) => setFilter("role_id", e.target.value)}>
              <option value="">All roles</option>
              {roleId && !(rolesResource.data ?? []).some((r) => r.id === roleId) && (
                <option value={roleId}>Selected role</option>
              )}
              {(rolesResource.data ?? []).map((role) => (
                <option key={role.id} value={role.id}>{role.name}</option>
              ))}
            </select>
          </label>
          <label className="field">
            Sort interviews
            <select value={sort} onChange={(e) => setFilter("sort", e.target.value)}>
              <option value="newest">Newest first</option>
              <option value="oldest">Oldest first</option>
              <option value="candidate">Candidate name</option>
              <option value="pending">Most pending matches</option>
            </select>
          </label>
        </div>
        <div className={styles.filterBar}>
          <label className={`field ${styles.filterInputWrap}`}>
            Filter by tag
            <Input
              type="search" maxLength={32} placeholder="Exact tag name" value={tagInput}
              onChange={(e) => { setTagInput(e.target.value); setFilter("tag", e.target.value.trim()) }}
            />
          </label>
          {availableTags.length > 0 && (
            <div className={styles.chipList} role="group" aria-label="Tag filters">
              {availableTags.map((entry) => {
                const active = tagInput.trim() === entry.tag
                const next = active ? "" : entry.tag
                return (
                  <button
                    key={entry.tag} type="button" aria-pressed={active}
                    className={active ? `${styles.chip} ${styles.chipActive}` : styles.chip}
                    onClick={() => { setTagInput(next); setTagSearch(next); setFilter("tag", next) }}
                  >
                    <span>{entry.tag}</span>
                    {entry.count > 0 && <span className="ml-1 opacity-75">({entry.count})</span>}
                  </button>
                )
              })}
            </div>
          )}
        </div>
        {changed && (
          <button
            className="clear-filters" type="button"
            onClick={() => { setQuery(""); setTagInput(""); setTagSearch(""); setFilter(null) }}
          >
            <X size={15} />Clear filters
          </button>
        )}
        {bulkError && <p className="error" role="alert">{bulkError}</p>}
        {bulkNotice && (
          <p className="notice" role="status">
            {bulkNotice} {archivedCount > 0 && <Link href="/trash/">Open Trash</Link>}
          </p>
        )}
        {resource.error && <WorkspaceError text={resource.error} retry={resource.reload} />}
        {!data && !resource.error && <div className="archive-empty"><p className="muted">Loading interviews…</p></div>}
        {data && data.items.length > 0 && (
          <>
            <BulkArchiveToolbar
              mode="archive"
              selectedCount={selectedIds.length}
              visibleCount={visibleIds.length}
              allVisibleSelected={visibleIds.length > 0 && visibleIds.every((id) => selectedSet.has(id))}
              busy={bulkBusy}
              onSelectAll={() => setSelectedIds(visibleIds.slice(0, 100))}
              onClear={() => setSelectedIds([])}
              onBulkTag={handleBulkTag}
              onBulkExport={handleBulkExport}
              onBulkArchive={handleBulkArchive}
            />
            <ul className="work-list">
              {data.items.map((session) => (
                <li key={session.id}>
                  <SessionRow
                    session={session}
                    review={review === "pending"}
                    selected={selectedSet.has(session.id)}
                    selectionDisabled={bulkBusy}
                    onToggleSelect={(id, checked) => setSelectedIds((prev) => toggleSelection(prev, id, checked))}
                  />
                </li>
              ))}
            </ul>
          </>
        )}
        {data && data.pages > 1 && (
          <nav className="archive-pages" aria-label="Interview pages">
            <Button type="button" variant="outline" size="sm" disabled={data.page === 1} onClick={() => setFilter("page", String(data.page - 1))}>
              Previous page
            </Button>
            <span>Page {data.page} of {data.pages}</span>
            <Button type="button" variant="outline" size="sm" disabled={data.page === data.pages} onClick={() => setFilter("page", String(data.page + 1))}>
              Next page
            </Button>
          </nav>
        )}
        {data && !data.items.length && (
          <div className="archive-empty">
            <Archive size={24} aria-hidden="true" />
            <strong>{data.total ? "No matching interviews" : "Your session log is empty"}</strong>
            <p>{data.total ? "Change the search or filters to see more interviews." : "New interviews appear here once you start a session."}</p>
            {!data.total && <Button variant="outline" size="sm" onClick={onCreate}>Create interview <ArrowUpRight /></Button>}
          </div>
        )}
      </section>
    </div>
  )
}
