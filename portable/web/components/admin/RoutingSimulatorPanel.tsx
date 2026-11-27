"use client"

import { useState, type FormEvent } from "react"
import { GitBranch, Play } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import {
  simulateModelChain,
  type SimulateChainResponse,
  type SimulatedChainCandidate,
} from "@/lib/adminDiagnostics"
import {
  AdminApiError,
  CAPABILITY_LABELS,
  PROVIDER_LABELS,
  type ModelCapability,
  type ModelProvider,
} from "@/lib/adminModels"

function providerLabel(provider: string): string {
  return PROVIDER_LABELS[provider as ModelProvider] ?? provider
}

function routingResult(result: SimulateChainResponse) {
  switch (result.failure_reason) {
    case "workspace_allowance": return "Would fail 429 (workspace attempt allowance reached)"
    case "model_budget": return "Would fail 429 (model budget reached)"
    case "model_rpm": return "Would fail 429 (model request rate reached)"
    case "circuit_open": return "Would fail 503 (model circuit open)"
    default: return result.would_fail_503 ? "Would fail 503 (no active candidate)" : `Chain ready (${result.active_chain.length} active)`
  }
}

function budgetLabel(status: string): string {
  if (status === "daily_token_limit_exceeded") return "Daily token limit exceeded"
  if (status === "monthly_cost_limit_exceeded") return "Monthly estimated spend threshold reached"
  return status === "ok" ? "Budget ok" : status
}

function CandidateRow({ item, skipped = false }: { item: SimulatedChainCandidate; skipped?: boolean }) {
  const name = item.display_name || item.slug || item.model_id || providerLabel(item.provider)
  return (
    <li className={skipped ? "panel inset admin-sim-item skipped" : "panel inset admin-sim-item"}>
      <div className="admin-sim-row-head">
        <div className="admin-model-title">
          <Badge variant={skipped ? "secondary" : item.rank === 1 ? "default" : "outline"}>
            {skipped ? "Skipped" : item.rank === 1 ? "#1 Primary" : `#${item.rank} Fallback`}
          </Badge>
          <strong>{name}</strong>
          <Badge variant="outline">{item.source === "env" ? "Env fallback" : "Registry"}</Badge>
          {item.is_default && <Badge variant="default">Default</Badge>}
          {item.budget_status !== "ok" && <Badge variant="destructive">{budgetLabel(item.budget_status)}</Badge>}
        </div>
        <span className="admin-mono">
          {providerLabel(item.provider)}
          {item.model_id ? ` · ${item.model_id}` : ""}
        </span>
      </div>
      <div className="admin-sim-meta admin-mono">
        <span>Status: {item.status || "env"}</span>
        {item.fallback_priority != null && <span>Priority: {item.fallback_priority}</span>}
        <span>RPM remaining: {item.rpm_remaining != null ? item.rpm_remaining : "Unlimited"}</span>
        <span>{budgetLabel(item.budget_status)}</span>
      </div>
      {item.skip_reason && <p className="admin-sim-reason">{item.skip_reason === "workspace_attempt_allowance_exhausted"
        ? "Workspace monthly attempt allowance reached" : item.skip_reason}</p>}
    </li>
  )
}

export function RoutingSimulatorPanel({ onAuthInvalid }: { onAuthInvalid: (msg: string) => void }) {
  const [capability, setCapability] = useState<ModelCapability>("reference")
  const [provider, setProvider] = useState("")
  const [allowReferenceFallback, setAllowReferenceFallback] = useState(false)
  const [running, setRunning] = useState(false)
  const [error, setError] = useState("")
  const [result, setResult] = useState<SimulateChainResponse | null>(null)

  async function handleSimulate(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    if (running) return
    setRunning(true)
    setError("")
    try {
      const trimmed = provider.trim()
      const res = await simulateModelChain({
        capability,
        ...(trimmed ? { provider: trimmed } : {}),
        allow_reference_fallback: allowReferenceFallback,
      })
      setResult(res)
    } catch (err) {
      if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) {
        onAuthInvalid(err.message)
        return
      }
      setError(err instanceof Error ? err.message : "Could not simulate routing chain.")
    } finally {
      setRunning(false)
    }
  }

  return (
    <section className="panel stack" aria-label="Routing chain simulator">
      <div>
        <h2 className="admin-sim-heading">
          <GitBranch size={18} aria-hidden="true" />
          Routing chain simulator
        </h2>
        <p className="muted">
          Preview candidate selection, fallback priority, request rate limits, and model budgets without calling a provider.
        </p>
      </div>

      <form className="admin-sim-form" onSubmit={(e) => void handleSimulate(e)}>
        <label className="field">
          Capability
          <select value={capability} disabled={running} onChange={(e) => setCapability(e.target.value as ModelCapability)}>
            {Object.entries(CAPABILITY_LABELS).map(([k, label]) => (
              <option key={k} value={k}>
                {label}
              </option>
            ))}
          </select>
        </label>
        <label className="field">
          Simulator provider or slug (optional)
          <Input
            type="text"
            disabled={running}
            value={provider}
            placeholder="e.g. openai, anthropic, or model slug"
            onChange={(e) => setProvider(e.target.value)}
          />
        </label>
        <div className="admin-sim-submit">
          <label className="check">
            <input
              type="checkbox"
              checked={allowReferenceFallback}
              disabled={running}
              onChange={(e) => setAllowReferenceFallback(e.target.checked)}
            />
            Allow reference fallback
          </label>
          <Button type="submit" size="sm" disabled={running}>
            <Play size={14} aria-hidden="true" />
            {running ? "Simulating…" : "Test capability chain"}
          </Button>
        </div>
      </form>

      {error && <p role="alert" className="error">{error}</p>}

      {result && (
        <div className="stack" aria-live="polite">
          <div className="admin-model-title">
            <Badge variant={result.would_fail_503 || result.would_fail_429 ? "destructive" : "success"}>
              {routingResult(result)}
            </Badge>
            <span className="admin-mono">
              {CAPABILITY_LABELS[result.capability] ?? result.capability}
              {result.provider_filter ? ` · Filter: ${result.provider_filter}` : ""}
            </span>
          </div>

          {result.active_chain.length > 0 ? (
            <div className="stack">
              <h3>Active routing order</h3>
              <ol className="admin-sim-list">
                {result.active_chain.map((item, idx) => (
                  <CandidateRow key={`${item.source}-${item.id ?? item.slug ?? item.provider}-${idx}`} item={item} />
                ))}
              </ol>
            </div>
          ) : (
            <p className="panel inset muted">No active candidates are eligible for this capability chain.</p>
          )}

          {result.skipped.length > 0 && (
            <div className="stack">
              <h3>Skipped candidates ({result.skipped.length})</h3>
              <ul className="admin-sim-list">
                {result.skipped.map((item, idx) => (
                  <CandidateRow key={`skip-${item.source}-${item.id ?? item.slug ?? item.provider}-${idx}`} item={item} skipped />
                ))}
              </ul>
            </div>
          )}
        </div>
      )}
    </section>
  )
}
