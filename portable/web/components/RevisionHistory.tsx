import { useEffect, useId, useRef, useState } from "react"
import { ChevronDown, History } from "lucide-react"
import { useResource } from "@/lib/workspace"
import { Button } from "./ui/button"
import RevisionSnapshot, { type SavedRevision } from "./RevisionSnapshot"
import styles from "./RevisionHistory.module.css"

type HistoryPage = {
  current_revision: number
  baseline_revision: number
  entries: Omit<SavedRevision, "snapshot">[]
  next_before_revision: number | null
}

const kindLabel = { baseline: "Baseline", answer_edit: "Answer edit", review_update: "Review update" }

function HistoryPageView({ path, editorRevision }: { path: string; editorRevision: number }) {
  const [cursors, setCursors] = useState<number[]>([])
  const [chosen, setChosen] = useState<number>()
  const selectId = useId()
  const picker = useRef<HTMLSelectElement>(null)
  const focusPicker = useRef(false)
  const cursor = cursors.at(-1)
  const list = useResource<HistoryPage>(cursor ? path + "?before_revision=" + cursor : path)
  const page = list.data
  const selected = page?.entries.find(entry => entry.revision === chosen) ?? page?.entries[0]
  const detail = useResource<SavedRevision>(selected ? path + "/" + selected.revision : null)

  useEffect(() => {
    if (page && focusPicker.current && picker.current) {
      picker.current.focus()
      focusPicker.current = false
    }
  }, [page])

  function changePage(next: number[]) {
    focusPicker.current = true
    setChosen(undefined)
    setCursors(next)
  }

  if (list.error) return <div className={styles.feedback}>
    <p role="alert">{list.error}</p>
    <Button type="button" variant="outline" size="sm" onClick={list.reload}>Retry revision list</Button>
  </div>
  if (!page) return <p role="status">Loading revision history…</p>
  const older = page.next_before_revision
  return <>
    {page.current_revision !== editorRevision && <p className={styles.notice}>
      The editor has revision {editorRevision}. The latest saved revision is {page.current_revision}.
    </p>}
    <div className="field">
      <label htmlFor={selectId}>Saved revision</label>
      <select id={selectId} ref={picker} value={selected?.revision ?? ""} onChange={event => setChosen(Number(event.target.value))}>
        {page.entries.map(entry => <option key={entry.revision} value={entry.revision}>
          {entry.revision === page.current_revision ? "Current" : "Earlier"} revision {entry.revision} · {kindLabel[entry.kind]}
        </option>)}
      </select>
    </div>
    {(cursors.length > 0 || older !== null) && <div className="row">
      {cursors.length > 0 && <Button type="button" size="sm" variant="outline"
        onClick={() => changePage(cursors.slice(0, -1))}>Newer revisions</Button>}
      {older !== null && <Button type="button" size="sm" variant="outline"
        onClick={() => changePage([...cursors, older])}>Older revisions</Button>}
    </div>}
    {page.baseline_revision > 1 && <p className={styles.meta}>History starts at revision {page.baseline_revision}.</p>}
    {detail.error ? <div className={styles.feedback}>
      <p role="alert">{detail.error}</p>
      <Button type="button" variant="outline" size="sm" onClick={detail.reload}>Retry saved revision</Button>
    </div> : detail.data ? <RevisionSnapshot entry={detail.data} current={detail.data.revision === page.current_revision}/>
      : <p role="status">Loading saved revision…</p>}
  </>
}

export default function RevisionHistory({ sessionId, answerId, revision, conflict }: {
  sessionId: string; answerId: string; revision: number; conflict: boolean
}) {
  const [open, setOpen] = useState(false)
  const trigger = useRef<HTMLButtonElement>(null)
  const id = useId()
  function close() {
    setOpen(false)
    trigger.current?.focus()
  }
  return <div className={styles.panel} onKeyDown={event => {
    if (open && event.key === "Escape" && event.target instanceof HTMLElement && event.target.tagName !== "SELECT") {
      event.stopPropagation()
      close()
    }
  }}>
    <button ref={trigger} className={styles.trigger} type="button" aria-expanded={open} aria-controls={id}
      onClick={() => setOpen(!open)}>
      <History size={16} aria-hidden="true"/>Revision history<ChevronDown size={16} aria-hidden="true"/>
    </button>
    <section id={id} hidden={!open} className={styles.body} aria-label="Saved revision history">
      {open && <>
        <HistoryPageView key={[sessionId, answerId, revision, conflict].join("/")}
          path={`sessions/${sessionId}/answers/${answerId}/history`} editorRevision={revision}/>
        <Button type="button" className={styles.close} size="sm" variant="outline" onClick={close}>Close history</Button>
      </>}
    </section>
  </div>
}
