import { useMemo } from "react"
import type { Answer, Interview, QuestionOrigin } from "@/lib/api"
import { Button } from "./ui/button"

export const noQuestionOrigin = { parent_answer_id: null, planned_slot: null }

export function originOf(value?: QuestionOrigin | null) {
  return { parent_answer_id: value?.parent_answer_id || null, planned_slot: value?.planned_slot || null }
}

export function OriginPicker({
  session,
  answerId,
  origin,
  change,
}: {
  session: Interview
  answerId: string
  origin: QuestionOrigin
  change: (value: QuestionOrigin, question?: string) => void
}) {
  const possibleParents = useMemo(() => {
    // Exclude descendants as well as this exchange from the editable parent choices.
    const children = new Map<string, string[]>()
    for (const a of session.answers)
      if (a.parent_answer_id) {
        const siblings = children.get(a.parent_answer_id) || []
        siblings.push(a.id)
        children.set(a.parent_answer_id, siblings)
      }
    const blocked = new Set<string>(),
      stack = [answerId]
    while (stack.length) {
      const id = stack.pop()!
      if (blocked.has(id)) continue
      blocked.add(id)
      for (const child of children.get(id) || []) stack.push(child)
    }
    return session.answers.map((a, i) => ({ a, number: i + 1 })).filter((row) => !blocked.has(row.a.id))
  }, [session.answers, answerId])
  const slots = session.planned_questions
  const duplicate = useMemo(() => {
    const seen = new Set<string>(),
      repeated = new Set<string>()
    for (const q of slots) {
      if (seen.has(q)) repeated.add(q)
      seen.add(q)
    }
    return repeated
  }, [slots])
  return (
    <>
      {!!slots.length && (
        <label className="field">
          Planned question
          <select
            value={origin.planned_slot || ""}
            onChange={(e) => {
              if (!e.target.value) {
                change(noQuestionOrigin)
                return
              }
              const slot = Number(e.target.value)
              change({ parent_answer_id: null, planned_slot: slot }, slots[slot - 1])
            }}
          >
            <option value="">Choose a question</option>
            {slots.map((question, i) => (
              <option key={i} value={i + 1}>
                {duplicate.has(question) ? `Slot ${i + 1}. ${question}` : question}
              </option>
            ))}
          </select>
        </label>
      )}
      {!!possibleParents.length && (
        <label className="field">
          Parent exchange
          <select
            value={origin.parent_answer_id || ""}
            onChange={(e) => change({ parent_answer_id: e.target.value || null, planned_slot: null })}
          >
            <option value="">No parent exchange</option>
            {possibleParents.map(({ a, number }) => (
              <option value={a.id} key={a.id}>
                Question {number}. {a.question.slice(0, 120)}
              </option>
            ))}
          </select>
        </label>
      )}
    </>
  )
}

export default function QuestionLineage({
  session,
  selected,
  disabled,
  navigate,
  askSlot,
}: {
  session: Interview
  selected?: Answer
  disabled: boolean
  navigate: (id: string) => void
  askSlot?: (slot: number) => void
}) {
  const index = useMemo(() => {
    const byId = new Map(session.answers.map((a, i) => [a.id, i + 1]))
    const bySlot = new Map<number, number>()
    for (const a of session.answers)
      if (a.planned_slot) bySlot.set(a.planned_slot, (bySlot.get(a.planned_slot) || 0) + 1)
    return { byId, bySlot }
  }, [session.answers])
  const children = selected ? session.answers.filter((a) => a.parent_answer_id === selected.id) : []
  if (!session.planned_questions.length && !selected?.parent_answer_id && !children.length) return null
  return (
    <section className="panel form-panel stack" aria-label="Question lineage">
      {selected?.parent_answer_id && (
        <div className="row">
          <strong>Follow up to</strong>
          <Button
            variant="outline"
            size="sm"
            disabled={disabled}
            onClick={() => navigate(selected.parent_answer_id!)}
          >
            Parent question {index.byId.get(selected.parent_answer_id)}
          </Button>
        </div>
      )}
      {selected?.planned_slot && (
        <p>
          From planned slot {selected.planned_slot}: {session.planned_questions[selected.planned_slot - 1]}
        </p>
      )}
      {!!children.length && (
        <div className="row">
          <strong>Follow up exchanges</strong>
          {children.map((child) => (
            <Button
              key={child.id}
              size="sm"
              variant="outline"
              disabled={disabled}
              onClick={() => navigate(child.id)}
            >
              Question {index.byId.get(child.id)}
            </Button>
          ))}
        </div>
      )}
      {!!session.planned_questions.length && (
        <details>
          <summary>
            Question plan · {index.bySlot.size} of {session.planned_questions.length} slots recorded
          </summary>
          <ol>
            {session.planned_questions.map((question, i) => (
              <li key={i}>
                <div className="spread">
                  <span>
                    <strong>Slot {i + 1}.</strong> {question}
                  </span>
                  {index.bySlot.has(i + 1) ? (
                    <small>{index.bySlot.get(i + 1)} recorded</small>
                  ) : askSlot ? (
                    <Button size="sm" variant="ghost" disabled={disabled} onClick={() => askSlot(i + 1)}>
                      Ask slot {i + 1}
                    </Button>
                  ) : (
                    <small>No linked exchange</small>
                  )}
                </div>
              </li>
            ))}
          </ol>
        </details>
      )}
    </section>
  )
}
