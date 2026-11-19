import { useState } from "react"
import { Button } from "./ui/button"
import { Textarea } from "./ui/textarea"
import type { Exchange } from "@/lib/transcript"
import styles from "./TranscriptBatchImport.module.css"

const PAGE = 8

export function TranscriptBatchSelection({
  rows,
  selected,
  toggle,
  edit,
  busy,
}: {
  rows: Exchange[]
  selected: Set<number>
  toggle: (ordinal: number | null, check: boolean) => void
  edit: (ordinal: number, key: "question" | "answer", text: string) => void
  busy: boolean
}) {
  const [page, setPage] = useState(0)
  const count = Math.ceil(rows.length / PAGE)
  const current = Math.min(page, count - 1)
  const start = Math.max(0, current * PAGE)
  if (!rows.length) return <p className="notice">No selected interviewer prompt has a candidate answer.</p>
  return (
    <div className="stack">
      <div className="spread">
        <h3>Select exchanges</h3>
        <div className="row">
          {rows.length <= 100 && (
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={busy}
              onClick={() => toggle(null, true)}
            >
              Select all
            </Button>
          )}
          <Button
            type="button"
            size="sm"
            variant="ghost"
            disabled={busy || !selected.size}
            onClick={() => toggle(null, false)}
          >
            Clear selection
          </Button>
        </div>
      </div>
      <ol className={styles.selection} start={start + 1}>
        {rows.slice(start, start + PAGE).map((row) => (
          <li key={row.ordinal}>
            <label className="check">
              <input
                type="checkbox"
                checked={selected.has(row.ordinal)}
                disabled={busy || (!selected.has(row.ordinal) && selected.size >= 100)}
                onChange={(e) => toggle(row.ordinal, e.target.checked)}
              />{" "}
              Include exchange {row.ordinal}
            </label>
            <details>
              <summary>
                {row.question.slice(0, 140)}
                {row.question.length > 140 ? "…" : ""}
              </summary>
              <div className="stack">
                <label className="field">
                  Question {row.ordinal}
                  <Textarea
                    disabled={busy}
                    value={row.question}
                    onChange={(e) => edit(row.ordinal, "question", e.target.value)}
                  />
                </label>
                <label className="field">
                  Answer {row.ordinal}
                  <Textarea
                    rows={4}
                    disabled={busy}
                    value={row.answer}
                    onChange={(e) => edit(row.ordinal, "answer", e.target.value)}
                  />
                </label>
              </div>
            </details>
          </li>
        ))}
      </ol>
      {count > 1 && (
        <div className="row">
          <Button
            type="button"
            variant="outline"
            size="sm"
            disabled={busy || current <= 0}
            onClick={() => setPage(current - 1)}
          >
            Previous page
          </Button>
          <span>
            Page {current + 1} of {count}
          </span>
          <Button
            type="button"
            variant="outline"
            size="sm"
            disabled={busy || current >= count - 1}
            onClick={() => setPage(current + 1)}
          >
            Next page
          </Button>
        </div>
      )}
    </div>
  )
}
