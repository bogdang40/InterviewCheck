import type { Answer } from "@/lib/api"
import { statusText } from "@/lib/api"
import MarkedText from "./MarkedText"
import styles from "./RevisionHistory.module.css"

type Snapshot = Pick<Answer, "question" | "answer" | "references" | "result" | "note" | "disposition" | "parent_answer_id" | "planned_slot">
export type SavedRevision = {
  revision: number
  kind: "baseline" | "answer_edit" | "review_update"
  actor: { kind: "local_operator" } | { kind: "account"; id: string } | null
  saved_at: string | null
  snapshot: Snapshot
}

const outcomes = {
  pending: "Pending review", explained: "Explained", unresolved: "Unresolved", disclosed: "Candidate disclosed assistance",
}
const savedTime = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "long" })

export default function RevisionSnapshot({ entry, current }: { entry: SavedRevision; current: boolean }) {
  const { snapshot, actor, saved_at } = entry
  const author = actor?.kind === "account" ? "Workspace account" : actor?.kind === "local_operator" ? "Local operator" : "Operator unknown"
  return <section className={styles.snapshot} aria-label="Read only snapshot">
    <h3>{current ? "Current" : "Earlier"} revision {entry.revision}</h3>
    <p className={styles.meta}>{author} · {saved_at
      ? <time dateTime={saved_at}>{savedTime.format(new Date(saved_at))}</time> : "Save time unknown"}</p>
    <dl className={styles.fields}>
      <dt>Question</dt><dd>{snapshot.question}</dd>
      <dt>Candidate response</dt><dd><MarkedText text={snapshot.answer} passages={snapshot.result.passages}/></dd>
      <dt>Saved outcome</dt><dd>{outcomes[snapshot.disposition]}</dd>
      <dt>Saved interviewer note</dt><dd>{snapshot.note || "No saved note."}</dd>
      {snapshot.planned_slot != null && <><dt>Planned question</dt><dd>Slot {snapshot.planned_slot}</dd></>}
      {snapshot.parent_answer_id && <><dt>Parent exchange ID</dt><dd>{snapshot.parent_answer_id}</dd></>}
    </dl>
    <details>
      <summary>Saved evidence</summary>
      <p><strong>{statusText[snapshot.result.status]}</strong></p>
      <p>{snapshot.result.explanation}</p>
      {snapshot.result.passages.map((passage, index) => <div className={styles.excerpt} key={index}>
        <strong>{passage.label}</strong><p>{passage.source_excerpt}</p>
      </div>)}
      {snapshot.references.map((source, index) => <div className={styles.excerpt} key={index}>
        <strong>{source.label}{source.permitted && " (permitted)"}</strong><p>{source.text}</p>
      </div>)}
      {snapshot.result.follow_up && <p><strong>Follow up</strong><br/>{snapshot.result.follow_up}</p>}
    </details>
  </section>
}
