import Link from "next/link"
import { useId } from "react"
import { ArrowRight } from "lucide-react"
import { dateLabel } from "@/lib/api"
import type { FeedItem } from "@/lib/bulkArchive"
import { candidateName, lifecycle, lifecycleText } from "@/lib/interview-list"
import { interviewURL } from "@/lib/workspace"
import styles from "./BulkArchiveToolbar.module.css"

type Props = {
  session: FeedItem
  review?: boolean
  resume?: () => void
  selected?: boolean
  selectionDisabled?: boolean
  onToggleSelect?: (sessionId: string, checked: boolean) => void
}

export default function SessionRow({
  session,
  review = false,
  resume,
  selected = false,
  selectionDisabled = false,
  onToggleSelect,
}: Props) {
  const name = candidateName(session)
  const state = lifecycle(session)
  const action = review ? "Review" : resume ? "Resume" : "Open"
  const title = action + " " + name
  const description = useId()
  const tags = session.tags ?? []
  const rowClassName = onToggleSelect ? `work-row ${styles.rowLink}` : "work-row"
  const body = (
    <>
      <span className="session-monogram" aria-hidden="true">
        {name.trim().slice(0, 1).toLocaleUpperCase()}
      </span>
      <span className="session-identity">
        <strong>{name}</strong>
        <small id={description + "-role"}>
          {session.role || "Role unspecified"} <span aria-hidden="true">·</span>{" "}
          {dateLabel(session.created_at)}
        </small>
      </span>
      <span className="session-labels" id={description + "-state"}>
        <span className={"lifecycle " + state}>{lifecycleText[state]}</span>
        {session.review_count > 0 && <span className="pending-label">{session.review_count} pending</span>}
        {tags.length > 0 && (
          <span className={styles.tagList} aria-label="Tags">
            {tags.map((tag) => (
              <span key={tag} className={styles.tagBadge}>
                {tag}
              </span>
            ))}
          </span>
        )}
      </span>
      <span className="row-action" aria-hidden="true">
        {review && <span>Review match</span>}
        <ArrowRight size={16} />
      </span>
    </>
  )
  const describes = description + "-role " + description + "-state"
  const row = resume ? (
    <button
      type="button"
      className={rowClassName}
      aria-label={title}
      aria-describedby={describes}
      onClick={resume}
    >
      {body}
    </button>
  ) : (
    <Link
      className={rowClassName}
      href={interviewURL(session.id, review ? session.first_pending_answer_id : null)}
      aria-label={title}
      aria-describedby={describes}
    >
      {body}
    </Link>
  )
  if (!onToggleSelect) return row
  return (
    <div className={styles.rowWrap} data-selected={selected ? "true" : undefined}>
      <label className={styles.rowCheck}>
        <input
          type="checkbox"
          checked={selected}
          disabled={selectionDisabled}
          aria-label={`Select ${name}`}
          onChange={(e) => onToggleSelect(session.id, e.target.checked)}
        />
      </label>
      {row}
    </div>
  )
}
