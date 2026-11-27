import type { Answer, Source } from "./api"

export type DeferredReceipt = {
  question_id: string; parent_answer_id: string; child_answer_id: string; submission_sha256: string
}
export type DeferredReply = Answer & { deferred_replay?: boolean; deferred_receipt?: DeferredReceipt }

function trimInput(value: string) {
  // Send one canonical value for the UI, the API's whitespace-stripping input model and the receipt.
  return value.replace(/^[\p{White_Space}\uFEFF]+|[\p{White_Space}\uFEFF]+$/gu, "")
}

export function deferredFields(question: string, answer: string, sources: Source[]) {
  return { question: trimInput(question), answer: trimInput(answer), references: sources.map(source => ({
    label: trimInput(source.label), text: trimInput(source.text), permitted: !!source.permitted,
  })) }
}

export async function expectedReceipt(questionId: string, childId: string, parentId: string,
                                      fields: ReturnType<typeof deferredFields>): Promise<DeferredReceipt> {
  if (!globalThis.crypto?.subtle) throw new Error("Open the workspace on HTTPS or localhost to verify the saved response.")
  const values = [childId, parentId, null, fields.question, fields.answer,
    fields.references.map(r => [r.label, r.text, r.permitted])]
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(values))))
  return { question_id: questionId, parent_answer_id: parentId, child_answer_id: childId,
    submission_sha256: Array.from(digest, n => n.toString(16).padStart(2, "0")).join("") }
}

export function matchesReceipt(reply: DeferredReply, expected: DeferredReceipt) {
  const actual = reply.deferred_receipt
  return !!actual && actual.question_id === expected.question_id && actual.parent_answer_id === expected.parent_answer_id
    && actual.child_answer_id === expected.child_answer_id && actual.submission_sha256 === expected.submission_sha256
}
