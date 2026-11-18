export type Source = { label: string; text: string; permitted: boolean }
export type Passage = { label: string; answer_excerpt: string; source_excerpt: string; words: number }
export type Disposition = "pending" | "explained" | "unresolved" | "disclosed"
export type Answer = {
  id: string
  question: string
  answer: string
  references: Source[]
  result: {
    status: "match" | "no_match" | "insufficient"
    explanation: string
    passages: Passage[]
    follow_up: string
  }
  note: string
  disposition: Disposition
  legacy?: Record<string, unknown> | null
}
export type Session = {
  id: string
  candidate: string
  role: string
  policy: string
  consent: boolean
  created_at: string
  answer_count: number
  review_count: number
}
export type Interview = Session & { answers: Answer[] }
export type Role = { id: string; name: string; description: string; questions: string[] }

export async function api<T>(path: string, method = "GET", body?: unknown): Promise<T> {
  const response = await fetch("/api/" + path, {
    method,
    cache: "no-store",
    headers: { "Content-Type": "application/json", "X-InterviewCheck": "1" },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  if (!response.ok) {
    const data = await response.json().catch(() => ({}))
    const detail = typeof data.detail === "string" ? data.detail : data.detail?.[0]?.msg
    throw new Error(detail || data.error?.message || `Request failed (HTTP ${response.status}).`)
  }
  return response.status === 204 ? (undefined as T) : response.json()
}

export function message(error: unknown) {
  return error instanceof Error ? error.message : "The operation failed."
}
export const statusText = {
  match: "Passage match",
  no_match: "No passage match",
  insufficient: "Limited evidence",
}
export const dateLabel = (iso: string) =>
  new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", year: "numeric" }).format(
    new Date(iso),
  )
