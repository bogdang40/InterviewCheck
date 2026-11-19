import {
  adminRequest,
  type ConnectedModel,
  type ModelCapability,
  type ModelParameters,
  type ModelProvider,
  type ModelStatus,
} from "./adminModels"

export const BATCH_TOGGLE_MAX = 25
export const BATCH_PROBE_MAX = 10

export type ModelPresetParameters = Partial<ModelParameters> & {
  daily_token_limit?: number | null
  monthly_cost_limit_usd?: number | null
  input_cost_per_1m_usd?: number | null
  output_cost_per_1m_usd?: number | null
}

export type ModelPreset = {
  id?: string
  provider: ModelProvider
  capability: ModelCapability
  model_id: string
  display_name: string
  slug_prefix: string
  endpoint_placeholder?: string | null
  api_version_default?: string | null
  description?: string
  parameters?: ModelPresetParameters
}

export type BatchToggleResponse = {
  updated: number
  models: ConnectedModel[]
}

export type BatchProbeItemResult = {
  id: string
  ok: boolean
  status: ModelStatus | string
  detail: string | null
  latency_ms: number | null
  model: ConnectedModel | null
}

export type BatchProbeResponse = {
  probed: number
  ok_count: number
  error_count: number
  results: BatchProbeItemResult[]
}

export function getPresetKey(preset: ModelPreset): string {
  return preset.id || `${preset.provider}:${preset.capability}:${preset.slug_prefix}`
}

export async function listAdminModelPresets(): Promise<ModelPreset[]> {
  const res = await adminRequest<{ presets: ModelPreset[] }>("/api/admin/models/presets")
  return Array.isArray(res.presets) ? res.presets : []
}

export function batchToggleAdminModels(
  modelIds: string[],
  enabled: boolean,
): Promise<BatchToggleResponse> {
  return adminRequest<BatchToggleResponse>("/api/admin/models/batch/toggle", {
    method: "POST",
    body: JSON.stringify({ model_ids: modelIds, enabled }),
  })
}

export function batchProbeAdminModels(modelIds: string[]): Promise<BatchProbeResponse> {
  return adminRequest<BatchProbeResponse>("/api/admin/models/batch/probe", {
    method: "POST",
    body: JSON.stringify({ model_ids: modelIds }),
  })
}

export function mergeBatchModels(
  prev: ConnectedModel[],
  updates: Array<ConnectedModel | null | undefined>,
): ConnectedModel[] {
  const byId = new Map<string, ConnectedModel>()
  for (const item of updates) {
    if (item) byId.set(item.id, item)
  }
  if (!byId.size) return prev
  return prev.map((existing) => byId.get(existing.id) ?? existing)
}
