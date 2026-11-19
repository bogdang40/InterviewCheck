import { AdminApiError, extractApiError } from "./adminModels"

export type KeySource = "env" | "file"

export type KeyStatusResponse = {
  active_key_id: string
  key_source: KeySource | string
  previous_keys_configured: number
  total_with_keys: number
  current_v2_count: number
  needs_rotation_count: number
}

export type RotateKeysResponse = {
  active_key_id: string
  rotated_count: number
  already_current_count: number
  total_with_keys: number
  current_v2_count: number
  needs_rotation_count: number
}

type UnknownRecord = Record<string, unknown>

const asRecord = (val: unknown): UnknownRecord =>
  val && typeof val === "object" && !Array.isArray(val) ? (val as UnknownRecord) : {}

const asInt = (val: unknown): number =>
  typeof val === "number" && Number.isFinite(val) ? Math.max(0, Math.trunc(val)) : 0

const asStr = (val: unknown): string => (typeof val === "string" ? val : "")

async function keyRotationRequest<T>(url: string, method: "GET" | "POST"): Promise<T> {
  const response = await fetch(url, {
    method,
    credentials: "include",
    cache: "no-store",
    headers: { "X-InterviewCheck": "1" },
  })
  const data = await response.json().catch(() => null)
  if (!response.ok) {
    const code =
      data && typeof data === "object" && "error" in data
        ? (data as { error?: { code?: string } }).error?.code
        : undefined
    throw new AdminApiError(response.status, extractApiError(data, response.status), code)
  }
  return data as T
}

function normalizeKeyStatus(raw: UnknownRecord): KeyStatusResponse {
  return {
    active_key_id: asStr(raw.active_key_id),
    key_source: asStr(raw.key_source) || "file",
    previous_keys_configured: asInt(raw.previous_keys_configured),
    total_with_keys: asInt(raw.total_with_keys),
    current_v2_count: asInt(raw.current_v2_count),
    needs_rotation_count: asInt(raw.needs_rotation_count),
  }
}

function normalizeRotateResponse(raw: UnknownRecord): RotateKeysResponse {
  const nested = asRecord(raw.status)
  const total = asInt(raw.total_with_keys ?? raw.total ?? nested.total_with_keys)
  const rotated = asInt(raw.rotated_count ?? raw.reencrypted_count ?? raw.rotated)
  const currentV2 = asInt(raw.current_v2_count ?? nested.current_v2_count ?? raw.total_v2_count)
  const needsRotation = asInt(raw.needs_rotation_count ?? nested.needs_rotation_count)
  const alreadyCurrent = asInt(
    raw.already_current_count ?? raw.unchanged_count ?? raw.skipped_count ?? Math.max(0, currentV2 - rotated),
  )
  return {
    active_key_id: asStr(raw.active_key_id || nested.active_key_id),
    rotated_count: rotated,
    already_current_count: alreadyCurrent,
    total_with_keys: total,
    current_v2_count: currentV2,
    needs_rotation_count: needsRotation,
  }
}

export async function getModelKeyStatus(): Promise<KeyStatusResponse> {
  const raw = await keyRotationRequest<UnknownRecord>("/api/admin/models/key-status", "GET")
  return normalizeKeyStatus(asRecord(raw))
}

export async function rotateModelKeys(): Promise<RotateKeysResponse> {
  const raw = await keyRotationRequest<UnknownRecord>("/api/admin/models/rotate-keys", "POST")
  return normalizeRotateResponse(asRecord(raw))
}
