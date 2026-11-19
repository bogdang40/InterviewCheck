import type { RubricCriterion, CalibratedRole } from "./roleCalibration"
import { RoleApiError, extractApiError } from "./roleCalibration"

export type RubricTemplateCriterion = {
  id?: string
  criterion: string
  weight: number
  expected_signals: string[]
  red_flags: string[]
}

export type RubricTemplate = {
  id: string
  title: string
  category: string
  summary: string
  default_policy: string
  suggested_questions: string[]
  rubric: RubricTemplateCriterion[]
}

export type CloneRolePayload = {
  name?: string | null
  change_note?: string
}

async function roleTemplateRequest<T>(url: string, options: RequestInit = {}): Promise<T> {
  const headers = new Headers(options.headers)
  headers.set("X-InterviewCheck", "1")
  if (options.body !== undefined && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json")
  }
  const response = await fetch(url, { ...options, credentials: "include", cache: "no-store", headers })
  const data = await response.json().catch(() => null)
  if (!response.ok) {
    throw new RoleApiError(
      response.status,
      extractApiError(data, response.status),
      response.headers.get("X-InterviewCheck-Conflict"),
    )
  }
  return data as T
}

export async function fetchRubricTemplates(signal?: AbortSignal): Promise<RubricTemplate[]> {
  const data = await roleTemplateRequest<{ templates?: RubricTemplate[] }>("/api/roles/rubric-templates", {
    method: "GET",
    signal,
  })
  return Array.isArray(data?.templates) ? data.templates : []
}

export function cloneRole(roleId: string, payload: CloneRolePayload = {}): Promise<CalibratedRole> {
  return roleTemplateRequest<CalibratedRole>(`/api/roles/${encodeURIComponent(roleId)}/clone`, {
    method: "POST",
    body: JSON.stringify(payload),
  })
}

export function rubricCriteriaFromTemplate(template: RubricTemplate): RubricCriterion[] {
  return template.rubric.slice(0, 25).map((item) => ({
    id: crypto.randomUUID(),
    criterion: String(item.criterion ?? "").trim().slice(0, 500),
    weight: Math.min(100, Math.max(1, Math.trunc(Number(item.weight) || 1))),
    expected_signals: Array.isArray(item.expected_signals)
      ? item.expected_signals.map((s) => String(s).trim()).filter(Boolean).slice(0, 20)
      : [],
    red_flags: Array.isArray(item.red_flags)
      ? item.red_flags.map((s) => String(s).trim()).filter(Boolean).slice(0, 20)
      : [],
  }))
}
