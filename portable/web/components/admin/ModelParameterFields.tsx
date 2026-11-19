"use client"

import { Input } from "@/components/ui/input"
import {
  parseOptionalFloat,
  parseOptionalInt,
  type ConnectedModel,
  type ModelParameters,
} from "@/lib/adminModels"

export type ModelParameterValues = {
  temperature: string
  maxTokens: string
  timeoutS: string
  fallbackPriority: string
  maxRetries: string
  rpmLimit: string
}

export function initialParameterValues(editing: ConnectedModel | null): ModelParameterValues {
  return {
    temperature:
      editing?.parameters.temperature != null ? String(editing.parameters.temperature) : "",
    maxTokens: editing?.parameters.max_tokens != null ? String(editing.parameters.max_tokens) : "",
    timeoutS: editing?.parameters.timeout_s != null ? String(editing.parameters.timeout_s) : "",
    fallbackPriority: editing ? String(editing.parameters.fallback_priority) : "100",
    maxRetries:
      editing?.parameters.max_retries != null ? String(editing.parameters.max_retries) : "0",
    rpmLimit: editing?.parameters.rpm_limit != null ? String(editing.parameters.rpm_limit) : "",
  }
}

export function parseModelParameterValues(values: ModelParameterValues): ModelParameters {
  const priorityParsed = parseOptionalInt(values.fallbackPriority, "Fallback priority", 0, 10000)
  if (priorityParsed === null) {
    throw new Error("Fallback priority is required (0 to 10000).")
  }
  const retriesParsed = parseOptionalInt(values.maxRetries, "Max retries", 0, 3)
  if (retriesParsed === null) {
    throw new Error("Max retries is required (0 to 3).")
  }
  return {
    temperature: parseOptionalFloat(values.temperature, "Temperature", 0, 2),
    max_tokens: parseOptionalInt(values.maxTokens, "Max tokens", 1, 128000),
    timeout_s: parseOptionalFloat(values.timeoutS, "Timeout (seconds)", 1, 180),
    fallback_priority: priorityParsed,
    max_retries: retriesParsed,
    rpm_limit: parseOptionalInt(values.rpmLimit, "RPM limit", 1, 10000),
  }
}

export function ModelParameterFields({
  values,
  busy,
  onChange,
}: {
  values: ModelParameterValues
  busy: boolean
  onChange: (next: ModelParameterValues) => void
}) {
  return (
    <div className="admin-param-grid">
      <label className="field">
        Temperature (0 to 2)
        <Input
          type="number"
          step="0.1"
          min="0"
          max="2"
          disabled={busy}
          value={values.temperature}
          placeholder="Default"
          onChange={(e) => onChange({ ...values, temperature: e.target.value })}
        />
      </label>
      <label className="field">
        Max tokens (1 to 128000)
        <Input
          type="number"
          step="1"
          min="1"
          max="128000"
          disabled={busy}
          value={values.maxTokens}
          placeholder="Default"
          onChange={(e) => onChange({ ...values, maxTokens: e.target.value })}
        />
      </label>
      <label className="field">
        Timeout seconds (1 to 180)
        <Input
          type="number"
          step="any"
          min="1"
          max="180"
          disabled={busy}
          value={values.timeoutS}
          placeholder="Default"
          onChange={(e) => onChange({ ...values, timeoutS: e.target.value })}
        />
      </label>
      <label className="field">
        Fallback priority (0 to 10000)
        <Input
          type="number"
          step="1"
          min="0"
          max="10000"
          required
          disabled={busy}
          value={values.fallbackPriority}
          onChange={(e) => onChange({ ...values, fallbackPriority: e.target.value })}
        />
      </label>
      <label className="field">
        Max retries (0 to 3)
        <Input
          type="number"
          step="1"
          min="0"
          max="3"
          required
          disabled={busy}
          value={values.maxRetries}
          onChange={(e) => onChange({ ...values, maxRetries: e.target.value })}
        />
      </label>
      <label className="field">
        RPM limit (1 to 10000)
        <Input
          type="number"
          step="1"
          min="1"
          max="10000"
          disabled={busy}
          value={values.rpmLimit}
          placeholder="Unlimited"
          onChange={(e) => onChange({ ...values, rpmLimit: e.target.value })}
        />
      </label>
    </div>
  )
}
