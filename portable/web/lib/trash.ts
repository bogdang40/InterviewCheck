export type TrashedInterview = {
  id: string
  candidate: string
  role: string
  created_at: string
  trashed_at: string
  operation_version: string
  answer_count: number
}

export type TrashPage = { items: TrashedInterview[]; total: number; page: number; page_size: number }
type MoveNotice = Pick<TrashedInterview, "id" | "operation_version">
const noticeKey = "interviewcheck.last-trash-move"

export function moveNotice(): MoveNotice | null {
  try {
    const data = JSON.parse(sessionStorage.getItem(noticeKey) || "null")
    return data && typeof data.id === "string" && typeof data.operation_version === "string" ? data : null
  } catch {
    return null
  }
}

export function rememberMove(entry: MoveNotice | null) {
  try {
    if (entry)
      sessionStorage.setItem(
        noticeKey,
        JSON.stringify({ id: entry.id, operation_version: entry.operation_version }),
      )
    else sessionStorage.removeItem(noticeKey)
  } catch {
    /* Restore remains available in Trash when browser storage is disabled. */
  }
}
