import Link from "next/link"
import { useId } from "react"
import { ArrowRight } from "lucide-react"
import { dateLabel } from "@/lib/api"
import { candidateName, lifecycle, lifecycleText, type SessionCard } from "@/lib/interview-list"
import { interviewURL } from "@/lib/workspace"

type Props = {
  session: SessionCard
  review?: boolean
  resume?: () => void
}

export default function SessionRow({ session, review = false, resume }: Props) {
  const name = candidateName(session)
  const state = lifecycle(session)
  const action = review ? "Review" : resume ? "Resume" : "Open"
  const title = action + " " + name
  const description = useId()
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
      </span>
      <span className="row-action" aria-hidden="true">
        {review && <span>Review match</span>}
        <ArrowRight size={16} />
      </span>
    </>
  )
  const describes = description + "-role " + description + "-state"
  return resume ? (
    <button
      type="button"
      className="work-row"
      aria-label={title}
      aria-describedby={describes}
      onClick={resume}
    >
      {body}
    </button>
  ) : (
    <Link
      className="work-row"
      href={interviewURL(session.id, review ? session.first_pending_answer_id : null)}
      aria-label={title}
      aria-describedby={describes}
    >
      {body}
    </Link>
  )
}
