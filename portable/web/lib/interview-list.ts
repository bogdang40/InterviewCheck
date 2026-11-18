import type { Session } from "./api"

export type SessionCard = Pick<
  Session,
  | "id"
  | "candidate"
  | "role"
  | "created_at"
  | "consent"
  | "ended_at"
  | "answer_count"
  | "review_count"
  | "first_pending_answer_id"
>
export type Overview = {
  total: number
  active_count: number
  pending_count: number
  pending_sessions: number
  pending: SessionCard[]
  active: SessionCard[]
}
export type InterviewPage = {
  items: SessionCard[]
  total: number
  filtered: number
  page: number
  pages: number
  page_size: number
}
export type Lifecycle = "active" | "finished" | "archived"
export type SessionSort = "newest" | "oldest" | "candidate" | "pending"

export function lifecycle(session: SessionCard): Lifecycle {
  if (session.ended_at) return "finished"
  return session.consent ? "active" : "archived"
}

export const lifecycleText = { active: "In progress", finished: "Finished", archived: "Archive only" }

export function candidateName(session: SessionCard) {
  return session.candidate || "Unnamed candidate"
}
