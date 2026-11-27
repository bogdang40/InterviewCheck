import { adminRequest } from "./adminModels"

type Excerpts = { answer_excerpt: string; source_excerpt: string }
export type ScriptedReply = { id: string; label: string; reply: Record<string, unknown>; questions: string[] }
export type RehearsalCase = {
  id: string
  label: string
  question: string
  answer: string
  notice: boolean
  gate: "notice_required" | "archived" | "no_eligible_passage" | "matched_passage"
  comparison: string
  explanation: string
  local_question: string
  payload: { question: string; matched_passages: Excerpts[] } | null
  scripts: ScriptedReply[]
}

const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value)
const text = (value: unknown): value is string => typeof value === "string" && !!value.length
function validScript(value: unknown): value is ScriptedReply {
  return object(value) && text(value.id) && text(value.label) && object(value.reply)
    && Array.isArray(value.questions) && value.questions.length <= 2 && value.questions.every(text)
}

function validCase(value: unknown): value is RehearsalCase {
  if (!object(value) || !["id", "label", "question", "answer", "comparison", "explanation", "local_question"].every(k => text(value[k]))
    || typeof value.notice !== "boolean" || !Array.isArray(value.scripts) || !value.scripts.every(validScript)) return false
  if (value.gate === "matched_passage") {
    const payload = value.payload
    return value.notice && value.scripts.length > 0 && object(payload) && payload.question === value.question
      && Array.isArray(payload.matched_passages) && payload.matched_passages.length > 0 && payload.matched_passages.length <= 3
      && payload.matched_passages.every(p => object(p) && text(p.answer_excerpt) && text(p.source_excerpt))
  }
  return ["notice_required", "archived", "no_eligible_passage"].includes(String(value.gate))
    && value.payload === null && value.scripts.length === 0
}

export async function getSavedReviewRehearsal(signal: AbortSignal): Promise<RehearsalCase[]> {
  const raw = await adminRequest<unknown>("/api/admin/models/playground/saved-review-rehearsal", { signal })
  if (!object(raw) || !Array.isArray(raw.cases) || !raw.cases.length || !raw.cases.every(validCase)
    || new Set(raw.cases.map(item => item.id)).size !== raw.cases.length) {
    throw new Error("The server returned an incomplete rehearsal. Reload the examples.")
  }
  return raw.cases
}
