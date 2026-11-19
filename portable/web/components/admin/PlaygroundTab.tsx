"use client"

import { useEffect, useMemo, useRef, useState, type FormEvent } from "react"
import { FlaskConical, Play } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Textarea } from "@/components/ui/textarea"
import { formatUsd } from "@/lib/adminDiagnostics"
import {
  AdminApiError, CAPABILITY_LABELS, PROVIDER_LABELS, parseOptionalFloat, parseOptionalInt,
  type ConnectedModel, type ModelCapability, type ModelProvider,
} from "@/lib/adminModels"
import {
  PRESET_LABELS, SCHEMA_LABELS, getPlaygroundPresets, isCompletionModel, runModelPlayground,
  type PlaygroundExpectedSchema, type PlaygroundModelResult, type PlaygroundPreset,
  type PlaygroundPresetId, type PlaygroundRunResponse,
} from "@/lib/adminPlayground"
import { formatLatency } from "@/lib/adminTelemetry"
import styles from "./PlaygroundTab.module.css"

function ResultCard({ item, expectedSchema }: { item: PlaygroundModelResult; expectedSchema: PlaygroundExpectedSchema }) {
  const providerLabel = PROVIDER_LABELS[item.provider as ModelProvider] ?? item.provider
  const capLabel = CAPABILITY_LABELS[item.capability as ModelCapability] ?? item.capability
  const showSchemaBadge = item.ok && expectedSchema !== "none"

  return (
    <article className={`panel ${styles.resultCard}${!item.ok ? ` ${styles.resultCardError}` : ""}`} aria-label={`Result for ${item.display_name}`}>
      <div className="spread">
        <div className="admin-model-title">
          <strong>{item.display_name}</strong>
          <Badge variant={item.ok ? "success" : "destructive"}>{item.ok ? "Success" : "Error"}</Badge>
          {showSchemaBadge ? (
            <Badge variant={item.schema_valid ? "success" : "destructive"}>{item.schema_valid ? "Schema valid" : "Schema invalid"}</Badge>
          ) : (
            item.ok && <Badge variant="secondary">Free text</Badge>
          )}
        </div>
        <span className="admin-mono">HTTP {item.http_status}</span>
      </div>

      <div className="admin-model-title">
        <Badge variant="outline">{providerLabel}</Badge>
        <Badge variant="secondary">{capLabel}</Badge>
        <span className="admin-mono">{item.target_model}</span>
      </div>

      <div className={styles.metricsRow}>
        <span>Latency: {formatLatency(item.latency_ms)}</span>
        <span>Tokens: {item.input_tokens} in / {item.output_tokens} out</span>
        <span>Est. cost: {formatUsd(item.estimated_cost_usd)}</span>
      </div>

      {(!item.ok || item.error) && <p role="alert" className="error">{item.error || "Model execution failed."}</p>}

      {item.ok && !item.schema_valid && item.schema_errors.length > 0 && (
        <ul className={styles.schemaErrors} aria-label="Schema validation errors">
          {item.schema_errors.map((errMsg, idx) => (
            <li key={`${item.model_id}-serr-${idx}`}>{errMsg}</li>
          ))}
        </ul>
      )}

      {item.output_text !== null && (
        <div className="stack">
          <span className="admin-mono">Sanitized output</span>
          <pre className={styles.outputBox}>{item.output_text || "(empty output)"}</pre>
        </div>
      )}

      {item.parsed_json !== null && (
        <details className={styles.parsedDetails}>
          <summary>Parsed JSON</summary>
          <pre className={styles.outputBox}>{JSON.stringify(item.parsed_json, null, 2)}</pre>
        </details>
      )}
    </article>
  )
}

export function PlaygroundTab({ models, onAuthInvalid }: { models: ConnectedModel[]; onAuthInvalid: (msg: string) => void }) {
  const completionModels = useMemo(() => models.filter(isCompletionModel), [models])
  const [presets, setPresets] = useState<PlaygroundPreset[]>([])
  const [presetsLoading, setPresetsLoading] = useState(true)
  const [presetsError, setPresetsError] = useState("")
  const [presetId, setPresetId] = useState<PlaygroundPresetId>("custom")
  const [selectedIds, setSelectedIds] = useState<string[]>([])
  const [systemPrompt, setSystemPrompt] = useState("")
  const [userInput, setUserInput] = useState("")
  const [frameAsUntrusted, setFrameAsUntrusted] = useState(true)
  const [expectedSchema, setExpectedSchema] = useState<PlaygroundExpectedSchema>("none")
  const [maxTokensRaw, setMaxTokensRaw] = useState("")
  const [temperatureRaw, setTemperatureRaw] = useState("")
  const [running, setRunning] = useState(false)
  const [runError, setRunError] = useState("")
  const [response, setResponse] = useState<PlaygroundRunResponse | null>(null)
  const initializedRef = useRef(false)

  useEffect(() => {
    let active = true
    setPresetsLoading(true)
    setPresetsError("")
    void getPlaygroundPresets()
      .then((list) => { if (active) setPresets(list) })
      .catch((err) => {
        if (!active) return
        if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) { onAuthInvalid(err.message); return }
        setPresetsError(err instanceof Error ? err.message : "Could not load playground presets.")
      })
      .finally(() => { if (active) setPresetsLoading(false) })
    return () => { active = false }
  }, [onAuthInvalid])

  useEffect(() => {
    const validIds = new Set(completionModels.map((m) => m.id))
    setSelectedIds((prev) => {
      const kept = prev.filter((id) => validIds.has(id))
      if (!initializedRef.current && kept.length === 0 && completionModels.length > 0) {
        initializedRef.current = true
        return [(completionModels.find((m) => m.enabled) ?? completionModels[0]).id]
      }
      return kept.length === prev.length ? prev : kept
    })
  }, [completionModels])

  function handlePresetChange(nextId: PlaygroundPresetId) {
    setPresetId(nextId)
    setRunError("")
    const preset = presets.find((p) => p.id === nextId)
    if (!preset) return
    setSystemPrompt(preset.system_prompt)
    setUserInput(preset.user_input)
    setFrameAsUntrusted(preset.frame_as_untrusted)
    setExpectedSchema(preset.expected_schema)
  }

  function toggleModel(id: string) {
    setRunError("")
    setSelectedIds((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : prev.length >= 3 ? prev : [...prev, id]))
  }

  async function handleRun(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    if (running) return
    setRunError("")
    if (selectedIds.length < 1 || selectedIds.length > 3) {
      setRunError("Select between 1 and 3 completion models to run.")
      return
    }
    const cleanSystem = systemPrompt.trim()
    const cleanUser = userInput.trim()
    if (!cleanSystem || !cleanUser) {
      setRunError("System prompt and user input are required.")
      return
    }
    let maxTokens: number | null = null
    let temperature: number | null = null
    try {
      maxTokens = parseOptionalInt(maxTokensRaw, "Max tokens", 1, 2000)
      temperature = parseOptionalFloat(temperatureRaw, "Temperature", 0, 2)
    } catch (err) {
      setRunError(err instanceof Error ? err.message : "Invalid numeric parameter.")
      return
    }
    setRunning(true)
    try {
      const res = await runModelPlayground({
        model_ids: selectedIds,
        preset: presetId,
        system_prompt: cleanSystem,
        user_input: cleanUser,
        frame_as_untrusted: frameAsUntrusted,
        expected_schema: expectedSchema,
        max_tokens: maxTokens,
        temperature,
      })
      setResponse(res)
    } catch (err) {
      if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) { onAuthInvalid(err.message); return }
      setRunError(err instanceof Error ? err.message : "Playground run failed.")
    } finally {
      setRunning(false)
    }
  }

  const activePreset = presets.find((p) => p.id === presetId) ?? null

  return (
    <section className={styles.playground} aria-label="Model playground">
      <div className={`panel inset ${styles.header}`}>
        <div>
          <h2 className="admin-sim-heading"><FlaskConical size={18} aria-hidden="true" />Model playground</h2>
          <p className="muted">Compare 1 to 3 completion models side by side with untrusted input framing and JSON schema validation.</p>
        </div>
        <Badge variant="outline">{selectedIds.length} / 3 models selected</Badge>
      </div>

      {presetsError && <p role="alert" className="error">{presetsError}</p>}

      <form className="panel stack" onSubmit={(e) => void handleRun(e)}>
        <div className="field">
          <label htmlFor="playground-preset">Benchmark preset</label>
          <select id="playground-preset" value={presetId} disabled={running} onChange={(e) => handlePresetChange(e.target.value as PlaygroundPresetId)}>
            <option value="custom">{PRESET_LABELS.custom}</option>
            {presets.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
          </select>
          {presetsLoading ? <small className="muted">Loading benchmark presets...</small> : activePreset && <small className="muted">{activePreset.description}</small>}
        </div>

        <fieldset className="admin-budget-fieldset">
          <legend>Completion models (select 1 to 3)</legend>
          {!completionModels.length ? (
            <p className="muted">No completion-capable models (reference, question planning, judge) are connected yet.</p>
          ) : (
            <div className={styles.modelGrid}>
              {completionModels.map((m) => {
                const checked = selectedIds.includes(m.id)
                const atMax = !checked && selectedIds.length >= 3
                return (
                  <label key={m.id} className={`${styles.modelChoice}${checked ? ` ${styles.modelChoiceSelected}` : ""}${atMax ? ` ${styles.modelChoiceDisabled}` : ""}`}>
                    <input type="checkbox" checked={checked} disabled={running || atMax} onChange={() => toggleModel(m.id)} />
                    <div className={styles.modelMeta}>
                      <div className="admin-model-title">
                        <strong>{m.display_name}</strong>
                        {!m.enabled && <Badge variant="secondary">Disabled</Badge>}
                      </div>
                      <span className="admin-mono">{PROVIDER_LABELS[m.provider] ?? m.provider} / {CAPABILITY_LABELS[m.capability] ?? m.capability}</span>
                      <span className="admin-mono">{m.model_id}</span>
                    </div>
                  </label>
                )
              })}
            </div>
          )}
        </fieldset>

        <div className={styles.promptGrid}>
          <label className="field">
            System prompt
            <Textarea rows={4} maxLength={4000} disabled={running} value={systemPrompt} placeholder="Enter system instructions for the benchmark..." onChange={(e) => setSystemPrompt(e.target.value)} />
          </label>
          <label className="field">
            User input
            <Textarea rows={4} maxLength={8000} disabled={running} value={userInput} placeholder="Enter candidate payload or test prompt..." onChange={(e) => setUserInput(e.target.value)} />
          </label>
        </div>

        <div className={styles.optionsGrid}>
          <label className="field">
            Expected schema
            <select value={expectedSchema} disabled={running} onChange={(e) => setExpectedSchema(e.target.value as PlaygroundExpectedSchema)}>
              {(Object.entries(SCHEMA_LABELS) as [PlaygroundExpectedSchema, string][]).map(([val, lbl]) => <option key={val} value={val}>{lbl}</option>)}
            </select>
          </label>
          <label className="field">
            Max tokens (1 to 2000)
            <Input type="number" min={1} max={2000} step={1} disabled={running} value={maxTokensRaw} placeholder="Model default" onChange={(e) => setMaxTokensRaw(e.target.value)} />
          </label>
          <label className="field">
            Temperature (0 to 2)
            <Input type="number" min={0} max={2} step={0.1} disabled={running} value={temperatureRaw} placeholder="Model default" onChange={(e) => setTemperatureRaw(e.target.value)} />
          </label>
        </div>

        <div className={styles.controlsBar}>
          <label className="check">
            <input type="checkbox" checked={frameAsUntrusted} disabled={running} onChange={(e) => setFrameAsUntrusted(e.target.checked)} />
            Frame user input as untrusted data (prompt-injection guard)
          </label>
          <Button type="submit" size="sm" disabled={running || selectedIds.length === 0}>
            <Play size={14} aria-hidden="true" />
            {running ? "Running benchmark..." : "Run benchmark"}
          </Button>
        </div>
      </form>

      {runError && <p role="alert" className="error">{runError}</p>}

      {response && (
        <div className="stack" aria-live="polite">
          <div className="panel inset spread">
            <div className="admin-model-title">
              <strong>Benchmark results</strong>
              <Badge variant={response.ok_count === response.results.length ? "success" : "warning"}>{response.ok_count} / {response.results.length} succeeded</Badge>
              <Badge variant="outline">Schema: {SCHEMA_LABELS[response.expected_schema] ?? response.expected_schema}</Badge>
              <Badge variant="secondary">{response.frame_as_untrusted ? "Untrusted framing on" : "Raw framing"}</Badge>
            </div>
            <span className="admin-mono">{PRESET_LABELS[response.preset] ?? response.preset}</span>
          </div>
          <div className={styles.resultsGrid}>
            {response.results.map((item) => <ResultCard key={item.model_id} item={item} expectedSchema={response.expected_schema} />)}
          </div>
        </div>
      )}
    </section>
  )
}
