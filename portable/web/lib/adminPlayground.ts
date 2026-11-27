import { adminRequest, type ConnectedModel, type ModelCapability } from "./adminModels"
import type { EstimateStatus } from "./adminUsage"

export type PlaygroundPresetId =
  | "custom"
  | "authoring_questions"
  | "ai_judge_rubric"
  | "prompt_injection_probe"

export type PlaygroundExpectedSchema =
  | "none"
  | "json_object"
  | "json_string_array"
  | "judge_verdict"

export type PlaygroundPreset = {
  id: Exclude<PlaygroundPresetId, "custom">
  label: string
  description: string
  system_prompt: string
  user_input: string
  frame_as_untrusted: boolean
  expected_schema: PlaygroundExpectedSchema
}

export type PlaygroundRunPayload = {
  model_ids: string[]
  preset: PlaygroundPresetId
  system_prompt: string
  user_input: string
  frame_as_untrusted: boolean
  expected_schema: PlaygroundExpectedSchema
  max_tokens?: number | null
  temperature?: number | null
}

export type PlaygroundModelResult = {
  model_id: string
  slug: string
  display_name: string
  provider: string
  capability: string
  target_model: string
  ok: boolean
  http_status: number
  latency_ms: number | null
  input_tokens: number
  output_tokens: number
  unsplit_tokens: number
  estimated_cost_usd: number
  estimate_status: EstimateStatus | "not_called"
  output_text: string | null
  parsed_json: unknown
  schema_valid: boolean
  schema_errors: string[]
  error: string | null
}

export type PlaygroundRunResponse = {
  preset: PlaygroundPresetId
  expected_schema: PlaygroundExpectedSchema
  frame_as_untrusted: boolean
  ok_count: number
  results: PlaygroundModelResult[]
}

export const COMPLETION_CAPABILITIES: readonly ModelCapability[] = [
  "reference",
  "question_planning",
  "judge",
]

export const SCHEMA_LABELS: Record<PlaygroundExpectedSchema, string> = {
  none: "None (free text)",
  json_object: "JSON object",
  json_string_array: "JSON string array",
  judge_verdict: "Judge verdict",
}

export const PRESET_LABELS: Record<PlaygroundPresetId, string> = {
  custom: "Custom prompt",
  authoring_questions: "Authoring questions",
  ai_judge_rubric: "AI judge rubric",
  prompt_injection_probe: "Prompt injection probe",
}

export function isCompletionModel(model: ConnectedModel): boolean {
  return COMPLETION_CAPABILITIES.includes(model.capability)
}

export async function getPlaygroundPresets(): Promise<PlaygroundPreset[]> {
  const data = await adminRequest<{ presets: PlaygroundPreset[] }>(
    "/api/admin/models/playground/presets",
  )
  return Array.isArray(data?.presets) ? data.presets : []
}

export function runModelPlayground(
  payload: PlaygroundRunPayload,
): Promise<PlaygroundRunResponse> {
  return adminRequest<PlaygroundRunResponse>("/api/admin/models/playground/run", {
    method: "POST",
    body: JSON.stringify(payload),
  })
}
