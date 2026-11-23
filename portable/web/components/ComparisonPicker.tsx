import Link from "next/link"
import { useEffect, useRef, useState } from "react"
import { dateLabel, message } from "@/lib/api"
import type { FeedPage } from "@/lib/bulkArchive"
import { request } from "@/lib/http"
import { useDeferredFocus } from "@/lib/useDeferredFocus"
import { candidateName, lifecycle, lifecycleText } from "@/lib/interview-list"
import WorkspaceError from "./WorkspaceError"
import { Badge } from "./ui/badge"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import styles from "./CompareDossierView.module.css"

type InterviewLabel = { id: string; candidate: string; role: string; created_at: string }
type Choice = { id: string; label?: InterviewLabel }
type Reply = { key: string; data?: FeedPage; error?: string }

function labelFor(row: InterviewLabel): InterviewLabel {
  return { id: row.id, candidate: row.candidate, role: row.role, created_at: row.created_at }
}

function idLabel(id: string, ids: string[]) {
  let size = 8
  while (size < id.length && ids.some((other) => other !== id && other.startsWith(id.slice(0, size)))) size += 4
  return id.slice(0, size)
}

export default function ComparisonPicker({ open, committed, known, apply, cancel }: {
  open: boolean; committed: string[]; known?: InterviewLabel[]; apply: (ids: string[]) => void; cancel?: () => void
}) {
  const [selection, setSelection] = useState<Choice[]>(() => committed.map((id) => ({ id: id.toLowerCase() })))
  const [search, setSearch] = useState("")
  const [query, setQuery] = useState("")
  const [page, setPage] = useState(1)
  const [attempt, setAttempt] = useState(0)
  const [reply, setReply] = useState<Reply | null>(null)
  const searchInput = useRef<HTMLInputElement>(null)
  const pageStatus = useRef<HTMLParagraphElement>(null)
  const { requestFocus, completeFocus, cancelFocus } = useDeferredFocus<"status">()
  const removeButtons = useRef(new Map<string, HTMLButtonElement>())
  const trimmed = search.trim()
  const key = open && trimmed === query ? JSON.stringify([query, page, attempt]) : ""
  const current = key && reply?.key === key ? reply : null
  const data = current?.data
  const activePage = data?.page ?? page
  const selected = new Set(selection.map((entry) => entry.id))
  const visibleIds = [...selected, ...(data?.items.map((item) => item.id) ?? [])]

  useEffect(() => {
    const timer = window.setTimeout(() => setQuery(trimmed), 140)
    return () => window.clearTimeout(timer)
  }, [trimmed])

  useEffect(() => {
    if (!key) { setReply(null); return }
    const controller = new AbortController()
    const params = new URLSearchParams({ page_size: "50", page: String(page) })
    if (query) params.set("q", query)
    request<FeedPage>(`/api/interviews/feed?${params}`, { signal: controller.signal })
      .then((value) => { if (!controller.signal.aborted) setReply({ key, data: value }) })
      .catch((err) => { if (!controller.signal.aborted) setReply({ key, error: message(err) }) })
    return () => controller.abort()
  }, [key, page, query])

  useEffect(() => {
    const comparisonLabels = new Map((known ?? []).map((row) => [row.id, row]))
    const pageLabels = new Map((data?.items ?? []).map((row) => [row.id, row]))
    setSelection((prior) => {
      let changed = false
      const next = prior.map((entry) => {
        const row = pageLabels.get(entry.id) ?? (!entry.label ? comparisonLabels.get(entry.id) : undefined)
        if (!row || (entry.label && row.candidate === entry.label.candidate && row.role === entry.label.role && row.created_at === entry.label.created_at)) return entry
        changed = true
        return { id: entry.id, label: labelFor(row) }
      })
      return changed ? next : prior
    })
  }, [known, data])

  useEffect(() => {
    if (!open) cancelFocus()
    else if (current) completeFocus(() => pageStatus.current)
  }, [current, open, cancelFocus, completeFocus])

  function filter(value: string) {
    cancelFocus()
    setSearch(value); setPage(1)
  }

  function navigate(next: number) {
    requestFocus("status")
    setPage(next); setAttempt((n) => n + 1)
  }

  function toggle(row: InterviewLabel, checked: boolean) {
    setSelection((prev) => {
      if (!checked) return prev.filter((entry) => entry.id !== row.id)
      if (prev.length >= 6 || prev.some((entry) => entry.id === row.id)) return prev
      return [...prev, { id: row.id, label: labelFor(row) }]
    })
  }

  function remove(index: number) {
    const next = selection.filter((_, i) => i !== index)
    const neighbour = next[index] ?? next[index - 1]
    if (neighbour) removeButtons.current.get(neighbour.id)?.focus()
    else searchInput.current?.focus()
    setSelection(next)
  }

  if (!open) return null
  return <section className={`panel ${styles.pickerPanel}`} aria-labelledby="compare-picker-heading">
    <div className={styles.pickerControls}>
      <div><h2 id="compare-picker-heading">Select interviews</h2>
        <p className="muted">Choose 2 to 6 interviews ({selection.length} of 6 selected). The list includes ongoing, finished and imported interviews outside Trash.</p></div>
      <div className={styles.headerActions}>
        {cancel && <Button type="button" variant="ghost" size="sm" onClick={() => {
          setSelection(committed.map((id) => ({ id: id.toLowerCase() }))); filter(""); cancel()
        }}>Cancel</Button>}
        <Button type="button" size="sm" disabled={selection.length < 2} onClick={() => apply(selection.map((entry) => entry.id))}>
          Compare selected ({selection.length})
        </Button>
      </div>
    </div>
    {selection.length > 0 && <ol role="list" className={styles.selectedInterviews} aria-label="Selected interviews in comparison order">
      {selection.map(({ id, label }, index) => <li key={id}>
        <div><strong>{label ? label.candidate || "Unnamed candidate" : "Interview ID"}</strong>
          <small>{label ? `${label.role || "No role"} · ${dateLabel(label.created_at)} · ${idLabel(id, visibleIds)}` : id}</small></div>
        <Button type="button" size="sm" variant="ghost" aria-label={`Remove ${label ? `${label.candidate || "Unnamed candidate"}, ${label.role || "No role"}, ${dateLabel(label.created_at)}` : "interview"} (${id}) from selection`}
          ref={(node) => { if (node) removeButtons.current.set(id, node); else removeButtons.current.delete(id) }}
          onClick={() => remove(index)}>Remove</Button>
      </li>)}
    </ol>}
    <label className={`field ${styles.pickerSearch}`}>Filter interviews
      <Input ref={searchInput} type="search" maxLength={120} placeholder="Search by candidate or role"
        value={search} onChange={(e) => filter(e.target.value)} />
    </label>
    {current?.error && <WorkspaceError text={current.error} retry={() => navigate(activePage)} />}
    <p className="muted" role="status" tabIndex={-1} ref={pageStatus}>
      {data ? data.filtered ? `${(data.page - 1) * data.page_size + 1} to ${(data.page - 1) * data.page_size + data.items.length} of ${data.filtered} interviews`
        : query ? "No interviews match your filter." : "No saved interviews. Create at least 2 interviews to compare candidates."
        : current?.error ? "This results page could not be loaded." : "Loading interviews…"}
    </p>
    {data && !query && data.total < 2 && <div className="notice row">
      {data.total === 1 && <span>Only 1 interview found. Create another interview to compare candidates.</span>}
      <Button asChild size="sm"><Link href="/interviews/new/">New interview</Link></Button>
    </div>}
    {data && query && data.filtered === 0 && <div className="notice row">
      <Button type="button" variant="outline" size="sm" onClick={() => { filter(""); searchInput.current?.focus() }}>Clear search</Button>
      <Link className="text-action" href="/interviews/">Open interviews</Link>
    </div>}
    {data && data.items.length > 0 && <ul className={styles.pickerList}>
      {data.items.map((row) => <li key={row.id}>
        <label className={selected.has(row.id) ? `${styles.pickerOption} ${styles.pickerOptionSelected}` : styles.pickerOption}>
          <input type="checkbox" checked={selected.has(row.id)} disabled={!selected.has(row.id) && selection.length >= 6}
            onChange={(event) => toggle(row, event.target.checked)} />
          <span className={styles.pickerMeta}><strong>{candidateName(row)}</strong>
            <small>{row.role || "No role"} · {lifecycleText[lifecycle(row)]} · {dateLabel(row.created_at)} · {idLabel(row.id, visibleIds)}</small></span>
          <Badge variant="outline">{row.answer_count} {row.answer_count === 1 ? "answer" : "answers"}</Badge>
        </label>
      </li>)}
    </ul>}
    {((data?.pages ?? 1) > 1 || activePage > 1) && <nav className={styles.headerActions} aria-label="Comparison picker pages">
      <Button type="button" size="sm" variant="outline" disabled={activePage <= 1}
        onClick={() => navigate(activePage - 1)}>Previous interviews</Button>
      <Button type="button" size="sm" variant="outline" disabled={!data || activePage >= data.pages}
        onClick={() => navigate(activePage + 1)}>Next interviews</Button>
    </nav>}
  </section>
}
