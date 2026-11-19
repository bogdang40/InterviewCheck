"use client"

import { useEffect, useState } from "react"
import { Button } from "@/components/ui/button"
import { CAPABILITY_LABELS, PROVIDER_LABELS } from "@/lib/adminModels"
import {
  getPresetKey,
  listAdminModelPresets,
  type ModelPreset,
} from "@/lib/adminModelPresets"
import { type ModelParameterValues } from "./ModelParameterFields"

function numStr(val: number | null | undefined, fallback = ""): string {
  return val != null ? String(val) : fallback
}

export function parameterValuesFromPreset(preset: ModelPreset): ModelParameterValues {
  const p = preset.parameters ?? {}
  return {
    temperature: numStr(p.temperature),
    maxTokens: numStr(p.max_tokens),
    timeoutS: numStr(p.timeout_s),
    fallbackPriority: numStr(p.fallback_priority, "100"),
    maxRetries: numStr(p.max_retries, "0"),
    rpmLimit: numStr(p.rpm_limit),
    dailyTokenLimit: numStr(p.daily_token_limit),
    monthlyCostLimitUsd: numStr(p.monthly_cost_limit_usd),
    inputCostPer1mUsd: numStr(p.input_cost_per_1m_usd),
    outputCostPer1mUsd: numStr(p.output_cost_per_1m_usd),
  }
}

export function ModelPresetPicker({
  busy,
  onApplyPreset,
}: {
  busy: boolean
  onApplyPreset: (preset: ModelPreset) => void
}) {
  const [presets, setPresets] = useState<ModelPreset[]>([])
  const [selectedKey, setSelectedKey] = useState("")
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState("")
  const [reloadNonce, setReloadNonce] = useState(0)

  useEffect(() => {
    let active = true
    setLoading(true)
    setError("")
    listAdminModelPresets()
      .then((items) => {
        if (active) setPresets(items)
      })
      .catch((err) => {
        if (active) {
          setError(err instanceof Error ? err.message : "Could not load presets.")
        }
      })
      .finally(() => {
        if (active) setLoading(false)
      })
    return () => {
      active = false
    }
  }, [reloadNonce])

  const activePreset = presets.find((p) => getPresetKey(p) === selectedKey) ?? null

  function handleSelect(nextKey: string) {
    setSelectedKey(nextKey)
    const match = presets.find((p) => getPresetKey(p) === nextKey)
    if (match) onApplyPreset(match)
  }

  return (
    <div className="panel inset stack" style={{ padding: "12px 14px", gap: 8 }}>
      <label className="field">
        Quick-start template
        <select
          value={selectedKey}
          disabled={busy || loading || presets.length === 0}
          onChange={(e) => handleSelect(e.target.value)}
        >
          <option value="">
            {loading ? "Loading presets..." : "Custom configuration (manual entry)"}
          </option>
          {presets.map((preset) => {
            const key = getPresetKey(preset)
            const providerLabel = PROVIDER_LABELS[preset.provider] ?? preset.provider
            const capLabel = CAPABILITY_LABELS[preset.capability] ?? preset.capability
            return (
              <option key={key} value={key}>
                {preset.display_name} ({providerLabel} / {capLabel})
              </option>
            )
          })}
        </select>
      </label>

      {activePreset && (
        <small role="status" className="muted">
          {activePreset.description
            ? `${activePreset.description} `
            : ""}
          Prefilled fields for {activePreset.display_name}. Enter an API key
          {activePreset.endpoint_placeholder ? " and HTTPS endpoint" : ""} to connect.
        </small>
      )}

      {error && (
        <div className="row" style={{ alignItems: "center", justifyContent: "space-between", gap: 8 }}>
          <small role="alert" className="error">
            {error}
          </small>
          <Button
            type="button"
            variant="outline"
            size="sm"
            disabled={busy || loading}
            onClick={() => setReloadNonce((n) => n + 1)}
          >
            Retry
          </Button>
        </div>
      )}
    </div>
  )
}
