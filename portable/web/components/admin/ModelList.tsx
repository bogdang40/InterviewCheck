"use client"

import { useState } from "react"
import { Activity, Cpu, History, Power, Settings2, Trash2 } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import {
  CAPABILITY_LABELS,
  PROVIDER_LABELS,
  type ConnectedModel,
  type ModelCapability,
  type ModelProvider,
  type ModelStatus,
} from "@/lib/adminModels"
import {
  formatModelBudgetBadge,
  type ModelUsageSummary,
} from "@/lib/adminDiagnostics"
import {
  computeFallbackRanks,
  formatLatency,
  formatUptime,
  type ModelTelemetrySummary,
} from "@/lib/adminTelemetry"
import { ModelBatchBar } from "./ModelBatchBar"

function statusVariant(status: ModelStatus) {
  if (status === "connected") return "success" as const
  if (status === "error") return "destructive" as const
  if (status === "disabled") return "secondary" as const
  return "outline" as const
}

function formatChecked(iso: string | null) {
  if (!iso) return "Never checked"
  const date = new Date(iso)
  return Number.isNaN(date.getTime()) ? iso : date.toLocaleString()
}

function chainBadgeLabel(rank: number | undefined, enabled: boolean): string {
  if (!enabled || !rank) return "Inactive in chain"
  return rank === 1 ? "#1 Primary" : `#${rank} Fallback`
}

export function ModelList({
  models,
  busyId,
  telemetryByModel,
  usageByModel,
  onConnect,
  onConfigure,
  onProbe,
  onToggle,
  onDelete,
  onViewHealth,
  onBatchUpdated,
  onBatchError,
  onAuthInvalid,
}: {
  models: ConnectedModel[]
  busyId: string | null
  telemetryByModel?: Record<string, ModelTelemetrySummary>
  usageByModel?: Record<string, ModelUsageSummary>
  onConnect: () => void
  onConfigure: (model: ConnectedModel) => void
  onProbe: (model: ConnectedModel) => void
  onToggle: (model: ConnectedModel) => void
  onDelete: (model: ConnectedModel) => void
  onViewHealth?: (model: ConnectedModel) => void
  onBatchUpdated?: (updated: Array<ConnectedModel | null | undefined>, statusMessage: string) => void
  onBatchError?: (message: string) => void
  onAuthInvalid?: (message: string) => void
}) {
  const [search, setSearch] = useState("")
  const [provider, setProvider] = useState<"" | ModelProvider>("")
  const [capability, setCapability] = useState<"" | ModelCapability>("")
  const [status, setStatus] = useState<"" | ModelStatus>("")
  const [confirmDeleteId, setConfirmDeleteId] = useState<string | null>(null)
  const [selectedIds, setSelectedIds] = useState<string[]>([])
  const [batchBusy, setBatchBusy] = useState(false)

  const fallbackRanks = computeFallbackRanks(models)
  const tokens = search.trim().toLowerCase().split(/\s+/).filter(Boolean)
  const filtered = models.filter((m) => {
    if (provider && m.provider !== provider) return false
    if (capability && m.capability !== capability) return false
    if (status && m.status !== status) return false
    if (tokens.length) {
      const hay = `${m.display_name} ${m.slug} ${m.model_id}`.toLowerCase()
      if (!tokens.every((t) => hay.includes(t))) return false
    }
    return true
  })

  const modelNamesById = Object.fromEntries(models.map((m) => [m.id, m.display_name]))
  const activeSelectedIds = selectedIds.filter((id) => id in modelNamesById)
  const selectedSet = new Set(activeSelectedIds)
  const visibleIds = filtered.map((m) => m.id)
  const allVisibleSelected = visibleIds.length > 0 && visibleIds.every((id) => selectedSet.has(id))
  const toggleCard = (id: string) =>
    setSelectedIds((prev) => (prev.includes(id) ? prev.filter((item) => item !== id) : [...prev, id]))
  const toggleVisible = () =>
    setSelectedIds((prev) =>
      allVisibleSelected
        ? prev.filter((id) => !visibleIds.includes(id))
        : Array.from(new Set([...prev.filter((id) => id in modelNamesById), ...visibleIds])),
    )

  return (
    <section className="stack" aria-label="Connected models">
      <div className="panel inset admin-filters">
        <label className="field">
          Search models
          <Input
            type="search"
            value={search}
            placeholder="Name, slug, or model ID"
            onChange={(e) => setSearch(e.target.value)}
          />
        </label>
        <label className="field">
          Provider filter
          <select value={provider} onChange={(e) => setProvider(e.target.value as "" | ModelProvider)}>
            <option value="">All providers</option>
            {Object.entries(PROVIDER_LABELS).map(([k, label]) => (
              <option key={k} value={k}>
                {label}
              </option>
            ))}
          </select>
        </label>
        <label className="field">
          Capability filter
          <select value={capability} onChange={(e) => setCapability(e.target.value as "" | ModelCapability)}>
            <option value="">All capabilities</option>
            {Object.entries(CAPABILITY_LABELS).map(([k, label]) => (
              <option key={k} value={k}>
                {label}
              </option>
            ))}
          </select>
        </label>
        <label className="field">
          Status filter
          <select value={status} onChange={(e) => setStatus(e.target.value as "" | ModelStatus)}>
            <option value="">All statuses</option>
            <option value="connected">Connected</option>
            <option value="unverified">Unverified</option>
            <option value="error">Error</option>
            <option value="disabled">Disabled</option>
          </select>
        </label>
      </div>

      {models.length > 0 && onBatchUpdated && onBatchError && onAuthInvalid && (
        <ModelBatchBar
          visibleCount={visibleIds.length} selectedIds={activeSelectedIds} allVisibleSelected={allVisibleSelected}
          disabled={Boolean(busyId)} modelNamesById={modelNamesById} onToggleSelectVisible={toggleVisible}
          onClearSelection={() => setSelectedIds([])} onBusyChange={setBatchBusy}
          onBatchUpdated={onBatchUpdated} onBatchError={onBatchError} onAuthInvalid={onAuthInvalid}
        />
      )}

      {!models.length ? (
        <div className="panel empty">
          <div className="empty-icon">
            <Cpu size={20} aria-hidden="true" />
          </div>
          <strong>No models registered</strong>
          <p>Connect an OpenAI, Anthropic, Azure OpenAI, Deepgram, or OpenAI-compatible endpoint.</p>
          <Button size="sm" onClick={onConnect}>
            Connect model
          </Button>
        </div>
      ) : !filtered.length ? (
        <div className="panel empty">
          <strong>No models match the active filters</strong>
          <p>Clear or adjust the filters above to view registered models.</p>
        </div>
      ) : (
        <div className="admin-model-list">
          {filtered.map((m) => {
            const rowBusy = busyId === m.id || (batchBusy && selectedSet.has(m.id))
            const rank = fallbackRanks[m.id]
            const modelTelemetry = telemetryByModel?.[m.id]
            const budgetBadge = formatModelBudgetBadge(m, usageByModel?.[m.id])
            return (
              <article className="panel admin-model-card" key={m.id} data-model-slug={m.slug}>
                <div className="admin-model-main">
                  <div className="admin-model-title">
                    <label className="check" style={{ gap: 4 }}>
                      <input type="checkbox" checked={selectedSet.has(m.id)} disabled={rowBusy} aria-label={`Select ${m.display_name}`} onChange={() => toggleCard(m.id)} />
                    </label>
                    <strong>{m.display_name}</strong>
                    <Badge variant={statusVariant(m.status)}>{m.status}</Badge>
                    {m.is_default && <Badge variant="default">Default</Badge>}
                    <Badge
                      variant={m.enabled && rank === 1 ? "default" : m.enabled ? "outline" : "secondary"}
                      className="admin-chain-badge"
                    >
                      {chainBadgeLabel(rank, m.enabled)}
                    </Badge>
                    {budgetBadge && (
                      <Badge
                        variant={budgetBadge.overLimit ? "destructive" : "outline"}
                        className="admin-budget-badge"
                      >
                        {budgetBadge.label}
                      </Badge>
                    )}
                  </div>
                  <span className="admin-mono">
                    {m.slug} · {m.model_id}
                  </span>
                  {m.endpoint && <span className="admin-mono">{m.endpoint}</span>}
                  {m.last_error && (
                    <p role="alert" className="error">
                      {m.last_error}
                    </p>
                  )}
                </div>
                <div className="admin-model-meta">
                  <span>{PROVIDER_LABELS[m.provider] ?? m.provider}</span>
                  <span className="muted">{CAPABILITY_LABELS[m.capability] ?? m.capability}</span>
                  <span className="admin-mono">
                    {m.hasKey ? `Key ${m.key_hint || "configured"}` : "No key stored"}
                  </span>
                  <small className="admin-mono">
                    Max retries {m.parameters.max_retries ?? 0} · RPM{" "}
                    {m.parameters.rpm_limit ?? "Unlimited"}
                  </small>
                </div>
                <div className="admin-model-health">
                  <span>
                    {m.last_latency_ms !== null ? `${m.last_latency_ms} ms` : "Not tested"}
                  </span>
                  <small className="muted">{formatChecked(m.last_checked_at)}</small>
                  <small className="muted">Priority {m.parameters.fallback_priority}</small>
                  {modelTelemetry && modelTelemetry.total_checks > 0 ? (
                    <small className="muted">
                      Uptime {formatUptime(modelTelemetry.uptime_pct)} · Avg{" "}
                      {formatLatency(modelTelemetry.avg_latency_ms)} · P95{" "}
                      {formatLatency(modelTelemetry.p95_latency_ms)}
                    </small>
                  ) : (
                    <small className="muted">No telemetry checks yet</small>
                  )}
                </div>
                <div className="admin-model-actions">
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    disabled={rowBusy}
                    onClick={() => onProbe(m)}
                  >
                    <Activity size={14} aria-hidden="true" />
                    {rowBusy ? "Testing…" : "Test connection"}
                  </Button>
                  {onViewHealth && (
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      disabled={rowBusy}
                      onClick={() => onViewHealth(m)}
                    >
                      <History size={14} aria-hidden="true" />
                      Health history
                    </Button>
                  )}
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    disabled={rowBusy}
                    aria-pressed={m.enabled}
                    onClick={() => onToggle(m)}
                  >
                    <Power size={14} aria-hidden="true" />
                    {m.enabled ? "Disable" : "Enable"}
                  </Button>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    disabled={rowBusy}
                    onClick={() => onConfigure(m)}
                  >
                    <Settings2 size={14} aria-hidden="true" />
                    Configure
                  </Button>
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    disabled={rowBusy}
                    onClick={() => setConfirmDeleteId(confirmDeleteId === m.id ? null : m.id)}
                  >
                    <Trash2 size={14} aria-hidden="true" />
                    Disconnect
                  </Button>
                </div>
                {confirmDeleteId === m.id && (
                  <div className="admin-confirm-bar" role="region" aria-label={`Confirm disconnect ${m.display_name}`}>
                    <span>Disconnect {m.display_name}? Stored encrypted credentials will be removed.</span>
                    <div className="row">
                      <Button
                        type="button"
                        variant="destructive"
                        size="sm"
                        disabled={rowBusy}
                        onClick={() => {
                          setConfirmDeleteId(null)
                          onDelete(m)
                        }}
                      >
                        Confirm disconnect
                      </Button>
                      <Button
                        type="button"
                        variant="outline"
                        size="sm"
                        disabled={rowBusy}
                        onClick={() => setConfirmDeleteId(null)}
                      >
                        Cancel
                      </Button>
                    </div>
                  </div>
                )}
              </article>
            )
          })}
        </div>
      )}
    </section>
  )
}
