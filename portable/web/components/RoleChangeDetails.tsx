import { useState, type ReactNode } from "react"
import type { RoleVersionDiff, RoleVersionSnapshot, RubricCriterion } from "@/lib/roleCalibration"

type Snapshot = RoleVersionSnapshot
type Props = { before: Snapshot; after: Snapshot; diff: RoleVersionDiff }

function Columns({ before, after, children }: { before: Snapshot; after: Snapshot; children: (v: Snapshot) => ReactNode }) {
  return <div className="grid gap-3 md:grid-cols-2">
    {[before, after].map((role, index) => (
      <div key={index} role="group" aria-label={`Revision ${role.version_number}`} className="min-w-0 rounded-md border border-[var(--line)] p-3">
        <h5 className="font-semibold">Revision {role.version_number}</h5>
        {children(role)}
      </div>
    ))}
  </div>
}

function Lines({ values, ordered = false }: { values: string[]; ordered?: boolean }) {
  if (!values.length) return <p className="muted">None recorded</p>
  const Tag = ordered ? "ol" : "ul"
  return <Tag className={ordered ? "list-decimal pl-6" : "list-disc pl-5"}>
    {values.map((value, i) => <li key={i} className="whitespace-pre-wrap break-words">{value}</li>)}
  </Tag>
}

function Criteria({ items, role }: { items: RubricCriterion[]; role: Snapshot }) {
  return <ul className="stack">
    {items.map(item => <li key={item.id}>
      <strong>{item.criterion}</strong><span className="muted"> · Weight {item.weight} · Slot {role.rubric.findIndex(c => c.id === item.id) + 1}</span>
      {!!item.expected_signals.length && <><p>Expected signals</p><Lines values={item.expected_signals} /></>}
      {!!item.red_flags.length && <><p>Red flags</p><Lines values={item.red_flags} /></>}
    </li>)}
  </ul>
}

export default function RoleChangeDetails({ before, after, diff }: Props) {
  const [showMaterials, setShowMaterials] = useState(false)
  const fieldNames = { name: "Role name", description: "Description", policy: "Resource policy" } as const
  return <div className="stack">
    {Object.entries(fieldNames).map(([field, label]) => {
      const name = field as keyof typeof fieldNames
      if (!diff.changed_fields.includes(name)) return null
      return <section key={name} aria-label={label} className="stack">
        <h4 className="font-semibold">{label}</h4>
        <Columns before={before} after={after}>{v => <p className="whitespace-pre-wrap break-words">{v[name] || "None recorded"}</p>}</Columns>
      </section>
    })}
    {diff.changed_fields.includes("questions") && <section className="stack" aria-label="Question order">
      <h4 className="font-semibold">Question order</h4>
      {diff.questions.reordered && <p>The sequence changed. Each question occurs the same number of times.</p>}
      {!!diff.questions.occurrences.length && <ul className="list-disc pl-5">
        {diff.questions.occurrences.map(change => <li key={change.text} className="break-words">
          “{change.text}” occurs {change.before} {change.before === 1 ? "time" : "times"} in v{before.version_number} and {change.after} {change.after === 1 ? "time" : "times"} in v{after.version_number}.
        </li>)}
      </ul>}
      <Columns before={before} after={after}>{v => <Lines ordered values={v.questions} />}</Columns>
    </section>}
    {diff.changed_fields.includes("rubric") && <section className="stack" aria-label="Grading changes">
      <h4 className="font-semibold">Grading changes</h4>
      {diff.rubric.reordered && <>
        <p>Criterion order changed.</p>
        <Columns before={before} after={after}>{v => <Lines ordered values={v.rubric.map(item => item.criterion)} />}</Columns>
      </>}
      {!!diff.rubric.removed.length && <div><h5>Removed from v{before.version_number}</h5><Criteria items={diff.rubric.removed} role={before} /></div>}
      {!!diff.rubric.added.length && <div><h5>Added in v{after.version_number}</h5><Criteria items={diff.rubric.added} role={after} /></div>}
      {diff.rubric.modified.map(change => {
        const items = [change.version, change.live]
        const different = (field: keyof RubricCriterion) => JSON.stringify(items[0][field]) !== JSON.stringify(items[1][field])
        return <article key={change.id} className="stack">
          <h5 className="font-semibold">{change.live.criterion}</h5>
          <Columns before={before} after={after}>{v => {
            const item = v === before ? change.version : change.live
            return <div className="stack">
              {different("criterion") && <p>Criterion · {item.criterion}</p>}
              {different("weight") && <p>Weight {item.weight}</p>}
              {different("expected_signals") && <div><p>Expected signals</p><Lines values={item.expected_signals} /></div>}
              {different("red_flags") && <div><p>Red flags</p><Lines values={item.red_flags} /></div>}
            </div>
          }}</Columns>
        </article>
      })}
    </section>}
    {diff.changed_fields.includes("permitted_sources") && <details onToggle={event => setShowMaterials(event.currentTarget.open)}>
      <summary>Compare permitted materials</summary>
      {showMaterials && <Columns before={before} after={after}>{v => v.permitted_sources.length ? v.permitted_sources.map((item, i) => (
        <div key={i} className="break-words"><strong>{item.label}</strong><p className="whitespace-pre-wrap">{item.text}</p></div>
      )) : <p>None recorded</p>}</Columns>}
    </details>}
  </div>
}
