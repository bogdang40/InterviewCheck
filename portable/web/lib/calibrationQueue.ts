import type { Disposition } from "./api"
import { extractApiError } from "./roleCalibration"

export type CalibrationExportFormat = "csv" | "json"
export type CalibrationReviewerVote = { reviewer_id?: string; reviewer_email: string; disposition: Disposition; created_at: string }
export type CalibrationQueueItem = {
  role_id: string | null; role_name: string; session_id: string; candidate: string
  answer_id: string; question: string; current_disposition: Disposition; reviewers: CalibrationReviewerVote[]
}
export type CalibrationQueueSummary = { roles_with_disagreements: number; total_disagreed_answers: number; reviewer_count: number }
export type CalibrationDisagreementsResponse = { summary: CalibrationQueueSummary; items: CalibrationQueueItem[] }

const EMPTY_SUMMARY: CalibrationQueueSummary = { roles_with_disagreements: 0, total_disagreed_answers: 0, reviewer_count: 0 }

export function buildCalibrationQuery(
  roleId?: string,
  opts: { limit?: number; format?: CalibrationExportFormat } = {},
): string {
  const params = new URLSearchParams()
  const trimmedRole = roleId?.trim()
  if (trimmedRole) params.set("role_id", trimmedRole)
  if (typeof opts.limit === "number" && Number.isFinite(opts.limit) && opts.limit >= 1) {
    params.set("limit", String(Math.trunc(opts.limit)))
  }
  if (opts.format) params.set("format", opts.format)
  const qs = params.toString()
  return qs ? `?${qs}` : ""
}

function resolveFilename(header: string | null, format: CalibrationExportFormat): string {
  const match = header ? /filename="?([^";]+)"?/i.exec(header) : null
  const cleaned = (match?.[1]?.split(/[\\/]/).pop() || "").trim().replace(/[^a-zA-Z0-9._-]/g, "-")
  return cleaned || `calibration-queue.${format}`
}

async function fetchCalibrationApi(path: string, signal?: AbortSignal): Promise<Response> {
  const response = await fetch(`/api/${path}`, {
    method: "GET",
    credentials: "include",
    cache: "no-store",
    signal,
    headers: { "X-InterviewCheck": "1" },
  })
  if (!response.ok) {
    const data = await response.json().catch(() => null)
    throw new Error(extractApiError(data, response.status))
  }
  return response
}

export async function fetchCalibrationDisagreements(
  roleId?: string,
  limit = 50,
  signal?: AbortSignal,
): Promise<CalibrationDisagreementsResponse> {
  const res = await fetchCalibrationApi(`calibration/disagreements${buildCalibrationQuery(roleId, { limit })}`, signal)
  const data = (await res.json().catch(() => null)) as Partial<CalibrationDisagreementsResponse> | null
  return {
    summary: data?.summary ? { ...EMPTY_SUMMARY, ...data.summary } : EMPTY_SUMMARY,
    items: Array.isArray(data?.items) ? data.items : [],
  }
}

export async function downloadCalibrationExport(roleId?: string, format: CalibrationExportFormat = "csv"): Promise<string> {
  const res = await fetchCalibrationApi(`calibration/export${buildCalibrationQuery(roleId, { format })}`)
  const filename = resolveFilename(res.headers.get("Content-Disposition"), format)
  const objectUrl = URL.createObjectURL(await res.blob())
  try {
    const anchor = document.createElement("a")
    anchor.href = objectUrl
    anchor.download = filename
    anchor.style.display = "none"
    document.body.appendChild(anchor)
    anchor.click()
    anchor.remove()
  } finally {
    window.setTimeout(() => URL.revokeObjectURL(objectUrl), 1000)
  }
  return filename
}
