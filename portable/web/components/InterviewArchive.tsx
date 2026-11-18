import { useEffect, useState } from "react"
import { useSearchParams } from "next/navigation"
import { ArrowUpRight, Archive, Plus, Search, X } from "lucide-react"
import { useResource } from "@/lib/workspace"
import WorkspaceError from "./WorkspaceError"
import { type InterviewPage, type SessionSort } from "@/lib/interview-list"
import ReportExport from "./ReportExport"
import SessionRow from "./SessionRow"
import { Button } from "./ui/button"

const states = new Set(["active", "finished", "archived"])
const reviewStates = new Set(["pending", "clear"])
const sorts = new Set(["newest", "oldest", "candidate", "pending"])
const filterKeys = ["q", "status", "review", "sort", "page"] as const
type Filter = (typeof filterKeys)[number]

function setFilter(key: Filter | null, value = "") {
  // Updating the current archive entry keeps the search when Back returns from
  // an interview without adding a browser history entry for every keystroke.
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

type Props = { onCreate: () => void }

export default function InterviewArchive({ onCreate }: Props) {
  const params = useSearchParams()
  const [query, setQuery] = useState(params.get("q") || "")
  // The App Router schedules updates to search params. Keystrokes need the
  // current value immediately, including when several arrive in one transition.
  useEffect(() => {
    setQuery(new URLSearchParams(window.location.search).get("q") || "")
  }, [params])
  const status = states.has(params.get("status") || "") ? params.get("status")! : ""
  const review = reviewStates.has(params.get("review") || "") ? params.get("review")! : ""
  const sort = sorts.has(params.get("sort") || "") ? (params.get("sort") as SessionSort) : "newest"
  const requestedPage = Number(params.get("page") || 1)
  const page =
    Number.isSafeInteger(requestedPage) && requestedPage > 0 && requestedPage <= 2147483647
      ? requestedPage
      : 1
  const [search, setSearch] = useState(query)
  useEffect(() => {
    const delay = window.setTimeout(() => setSearch(query), 140)
    return () => window.clearTimeout(delay)
  }, [query])
  const criteria = new URLSearchParams({ q: search.slice(0, 160), status, review, sort, page: String(page) })
  const resource = useResource<InterviewPage>("interviews/feed?" + criteria.toString())
  const data = search === query ? resource.data : null
  const changed = Boolean(query || status || review || sort !== "newest" || page !== 1)
  const first = data ? (data.page - 1) * data.page_size + 1 : 0
  const last = data ? first + data.items.length - 1 : 0
  const count = !data
    ? "Loading interviews…"
    : data.pages === 1
      ? `${data.filtered} of ${data.total} shown`
      : `${first} to ${last} of ${data.filtered} matching interviews`

  return (
    <div className="interview-archive">
      <div className="archive-heading">
        <div>
          <h1>Interviews</h1>
          <p>Find an interview by candidate, role, capture status or pending evidence.</p>
        </div>
        <div className="row">
          <Button asChild variant="ghost" size="sm">
            <a href="/trash/">Trash</a>
          </Button>
          <ReportExport />
          <Button onClick={onCreate}>
            <Plus />
            New interview
          </Button>
        </div>
      </div>
      <section className="panel queue-panel" aria-labelledby="archive-list-heading">
        <div className="queue-head">
          <h2 id="archive-list-heading">All interviews</h2>
          <span className="result-count" role="status" aria-live="polite">
            {count}
          </span>
        </div>
        <div className="archive-filters">
          <label className="field archive-search">
            Search interviews
            <span>
              <Search size={16} aria-hidden="true" />
              <input
                type="search"
                maxLength={160}
                placeholder="Candidate or role"
                value={query}
                onChange={(event) => {
                  setQuery(event.target.value)
                  setFilter("q", event.target.value)
                }}
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
            Sort interviews
            <select value={sort} onChange={(e) => setFilter("sort", e.target.value)}>
              <option value="newest">Newest first</option>
              <option value="oldest">Oldest first</option>
              <option value="candidate">Candidate name</option>
              <option value="pending">Most pending matches</option>
            </select>
          </label>
        </div>
        {changed && (
          <button
            className="clear-filters"
            type="button"
            onClick={() => {
              setQuery("")
              setFilter(null)
            }}
          >
            <X size={15} />
            Clear filters
          </button>
        )}
        {resource.error && <WorkspaceError text={resource.error} retry={resource.reload} />}
        {data && data.items.length > 0 && (
          <ul className="work-list">
            {data.items.map((session) => (
              <li key={session.id}>
                <SessionRow session={session} review={review === "pending"} />
              </li>
            ))}
          </ul>
        )}
        {data && data.pages > 1 && (
          <nav className="archive-pages" aria-label="Interview pages">
            <Button
              type="button"
              variant="outline"
              size="sm"
              disabled={data.page === 1}
              onClick={() => setFilter("page", String(data.page - 1))}
            >
              Previous page
            </Button>
            <span>
              Page {data.page} of {data.pages}
            </span>
            <Button
              type="button"
              variant="outline"
              size="sm"
              disabled={data.page === data.pages}
              onClick={() => setFilter("page", String(data.page + 1))}
            >
              Next page
            </Button>
          </nav>
        )}
        {data && !data.items.length && (
          <div className="archive-empty">
            <Archive size={24} aria-hidden="true" />
            <strong>{data.total ? "No matching interviews" : "Your session log is empty"}</strong>
            <p>
              {data.total
                ? "Change the search or filters to see more interviews."
                : "New interviews appear here once you start a session."}
            </p>
            {!data.total && (
              <Button variant="outline" size="sm" onClick={onCreate}>
                Create interview <ArrowUpRight />
              </Button>
            )}
          </div>
        )}
      </section>
    </div>
  )
}
