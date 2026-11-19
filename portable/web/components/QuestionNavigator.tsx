import { BookmarkCheck, Circle, CircleDot, ListChecks } from "lucide-react"
import type { Answer } from "@/lib/api"

export const needsReview = (answer: Answer) =>
  answer.result.status === "match" && answer.disposition === "pending"

export function nextPending(answers: Answer[], from: string) {
  const index = answers.findIndex((a) => a.id === from)
  return [...answers.slice(index + 1), ...answers.slice(0, Math.max(0, index))].find(needsReview)
}

export function outcomeText(a: Answer) {
  if (needsReview(a)) return "Needs review"
  switch (a.disposition) {
    case "pending":
      return "Captured"
    case "explained":
      return "Explained"
    case "unresolved":
      return "Unresolved"
    case "disclosed":
      return "Assistance disclosed"
  }
}

export default function QuestionNavigator({
  answers,
  active,
  disabled,
  onSelect,
}: {
  answers: Answer[]
  active?: string
  disabled: boolean
  onSelect: (answer: Answer) => void
}) {
  return (
    <nav className="question-index" aria-label="Interview questions">
      <div className="index-heading">
        <ListChecks size={17} />
        <strong>Questions</strong>
        <span>{answers.length}</span>
      </div>
      <div className="question-list">
        {answers.map((a, i) => {
          const Icon = needsReview(a) ? CircleDot : a.disposition === "pending" ? Circle : BookmarkCheck
          return (
            <button
              type="button"
              className="question-link"
              key={a.id}
              aria-current={a.id === active ? "true" : undefined}
              disabled={disabled}
              onClick={() => onSelect(a)}
            >
              <span className="q-number">{String(i + 1).padStart(2, "0")}</span>
              <span>
                <b>{a.question}</b>
                <small className={needsReview(a) ? "needs-review" : ""}>
                  <Icon size={12} />
                  {outcomeText(a)}
                </small>
              </span>
            </button>
          )
        })}
      </div>
      <label className="mobile-question-picker">
        Selected question
        <select
          value={active ?? ""}
          disabled={disabled}
          onChange={(e) => {
            const a = answers.find((a) => a.id === e.target.value)
            if (a) onSelect(a)
          }}
        >
          <option value="" disabled>
            Select a question
          </option>
          {answers.map((a, i) => (
            <option key={a.id} value={a.id}>
              {i + 1}. {a.question} · {outcomeText(a)}
            </option>
          ))}
        </select>
      </label>
    </nav>
  )
}
