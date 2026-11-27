import type { RubricSnapshot } from "@/lib/sessionScorecard"

export default function InterviewRubric({ snapshot }: { snapshot: RubricSnapshot | null }) {
  if (!snapshot) {
    return <p className="muted">The original rubric was not recorded. Available template criteria come from the current role.</p>
  }
  if (snapshot.role_id === null) return <p className="muted">This interview started without a role template.</p>
  const revision = Number.isSafeInteger(snapshot.version_number)
    ? `Role version ${snapshot.version_number}`
    : `Role revision ${snapshot.role_content_sha256?.slice(0, 12)}`
  const label = `Rubric at interview start · ${revision}`
  if (!snapshot.criteria.length) return <p className="muted">{label}. No criteria were recorded at this revision.</p>
  return <details className="panel inset">
    <summary>{label}</summary>
    <ol className="stack">
      {snapshot.criteria.map(c => <li key={c.id}>
        <p><strong>{c.criterion}</strong> · Weight {c.weight}</p>
        {!!c.expected_signals.length && <><strong>Expected signals</strong><ul>
          {c.expected_signals.map((text, i) => <li key={i}>{text}</li>)}
        </ul></>}
        {!!c.red_flags.length && <><strong>Red flags</strong><ul>
          {c.red_flags.map((text, i) => <li key={i}>{text}</li>)}
        </ul></>}
      </li>)}
    </ol>
  </details>
}
