import type { PanelStatus, PanelView } from "./panelReview"
import type { Disposition } from "./api"
import { downloadResponse } from "./download"
import { readJson, send } from "./http"

export type CalibrationExportFormat = "csv" | "json"
export type CalibrationReviewerVote = { reviewer_id?: string; reviewer_email: string; disposition: Disposition; created_at: string }
export type CalibrationQueueItem = {
  role_id: string | null; role_name: string; session_id: string; candidate: string
  panel_status?: PanelStatus
  answer_id: string; question: string; current_disposition: Disposition; reviewers: CalibrationReviewerVote[]
}
export type CalibrationQueueSummary = { roles_with_disagreements: number; total_disagreed_answers: number; reviewer_count: number }
export type CalibrationDisagreementsResponse = { matching_cases?: number; page?: number; summary: CalibrationQueueSummary; items: CalibrationQueueItem[] }

const EMPTY_SUMMARY: CalibrationQueueSummary = { roles_with_disagreements: 0, total_disagreed_answers: 0, reviewer_count: 0 }

export function buildCalibrationQuery(
  roleId?: string,
  opts: { limit?: number; format?: CalibrationExportFormat; panelView?: PanelView; page?: number } = {},
): string {
  const params = new URLSearchParams()
  const trimmedRole = roleId?.trim()
  if (trimmedRole) params.set("role_id", trimmedRole)
  if (typeof opts.limit === "number" && Number.isFinite(opts.limit) && opts.limit >= 1) {
    params.set("limit", String(Math.trunc(opts.limit)))
  }
  if (opts.page && opts.page > 1) params.set("page", String(opts.page))
  if (opts.panelView) params.set("panel_view", opts.panelView)
  if (opts.format) params.set("format", opts.format)
  const qs = params.toString()
  return qs ? `?${qs}` : ""
}

export async function fetchCalibrationDisagreements(
  roleId?: string,
  limit = 50,
  signal?: AbortSignal,
  panelView?: PanelView,
  page = 1,
): Promise<CalibrationDisagreementsResponse> {
  const res = await send(`/api/calibration/disagreements${buildCalibrationQuery(roleId, { limit, panelView, page })}`, { signal })
  const data = (await readJson(res)) as Partial<CalibrationDisagreementsResponse> | null
  return {
    matching_cases: data?.matching_cases, page: data?.page,
    summary: data?.summary ? { ...EMPTY_SUMMARY, ...data.summary } : EMPTY_SUMMARY,
    items: Array.isArray(data?.items) ? data.items : [],
  }
}

export async function downloadCalibrationExport(roleId?: string, format: CalibrationExportFormat = "csv"): Promise<string> {
  const res = await send(`/api/calibration/export${buildCalibrationQuery(roleId, { format })}`)
  return downloadResponse(res, `calibration-queue.${format}`)
}
