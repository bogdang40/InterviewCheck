import Link from "next/link"
import { dateLabel } from "@/lib/api"
import type { CompareCounts, CompareSessionSummary } from "@/lib/compareInterviews"
import { lifecycleText, type Lifecycle } from "@/lib/interview-list"
import { interviewURL } from "@/lib/workspace"
import { Badge } from "./ui/badge"
import styles from "./CompareDossierView.module.css"

type CountField = [keyof CompareCounts, string, string, string?]
const evidence: CountField[] = [
  ["match", "Passage match", "answer with a passage match", "answers with a passage match"],
  ["no_match", "No passage match", "answer without a passage match", "answers without a passage match"],
  ["insufficient", "Limited evidence", "answer with limited evidence", "answers with limited evidence"],
]
const review: CountField[] = [
  ["pending", "Pending", "pending disposition", "pending dispositions"], ["explained", "Explained", "explained"],
  ["unresolved", "Unresolved", "unresolved"], ["disclosed", "Disclosed", "disclosed"],
]
const groups = [{ label: "Evidence", fields: evidence }, { label: "Review outcome", fields: review }]

export default function ComparisonCandidateCard({ session, showPolicy }: { session: CompareSessionSummary; showPolicy: boolean }) {
  const { counts } = session
  const nonzero = groups.flatMap(group => group.fields
    .filter(([key]) => counts[key] > 0)
    .map(([key, , singular, plural]) => `${counts[key]} ${counts[key] === 1 ? singular : plural ?? singular}`))
  const state = lifecycleText[session.lifecycle as Lifecycle] || session.lifecycle || "Unknown"
  return <article className={`panel ${styles.candidateCard}`} aria-labelledby={`compare-candidate-${session.id}`}>
    <div className={styles.cardHead}>
      <div>
        <Link id={`compare-candidate-${session.id}`} className={styles.cardTitle} href={interviewURL(session.id)}>
          {session.candidate || "Unnamed candidate"}
        </Link>
        <p className={styles.cardMeta}>{session.role || "No role assigned"}</p>
      </div>
      <Badge variant="outline">{state}</Badge>
    </div>
    <p className={styles.cardMeta}>
      {dateLabel(session.created_at)} · {session.consent ? "Consent recorded" : "No consent"} ·{" "}
      {session.answer_count} {session.answer_count === 1 ? "answer" : "answers"}
    </p>
    {showPolicy && <div>
      <strong className={styles.cardMeta}>Assistance policy</strong>
      {session.policy?.trim() ? <p className={styles.policyText}>{session.policy}</p>
        : <p className={styles.cardMeta}>No policy recorded.</p>}
    </div>}
    {nonzero.length > 0 && <p className={styles.countSummary}>{nonzero.join(" · ")}</p>}
    <details className={styles.allCounts}>
      <summary aria-label={`All counts for ${session.candidate || "unnamed candidate"}`}>All counts</summary>
      <div className={styles.countGroups}>
        {groups.map(group => <div key={group.label}>
          <strong>{group.label}</strong>
          <dl>{group.fields.map(([key, label]) => <div key={key}><dt>{label}</dt><dd>{counts[key]}</dd></div>)}</dl>
        </div>)}
      </div>
    </details>
  </article>
}
