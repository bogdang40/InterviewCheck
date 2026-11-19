"use client"

import { useState } from "react"
import { Activity, Cpu, Power, Settings2, Trash2 } from "lucide-react"
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

export function ModelList({
  models,
  busyId,
  onConnect,
  onConfigure,
  onProbe,
  onToggle,
  onDelete,
}: {
  models: ConnectedModel[]
  busyId: string | null
  onConnect: () => void
  onConfigure: (model: ConnectedModel) => void
  onProbe: (model: ConnectedModel) => void
  onToggle: (model: ConnectedModel) => void
  onDelete: (model: ConnectedModel) => void
}) {
  const [search, setSearch] = useState("")
  const [provider, setProvider] = useState<"" | ModelProvider>("")
  const [capability, setCapability] = useState<"" | ModelCapability>("")
  const [status, setStatus] = useState<"" | ModelStatus>("")
  const [confirmDeleteId, setConfirmDeleteId] = useState<string | null>(null)

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
            const rowBusy = busyId === m.id
            return (
              <article className="panel admin-model-card" key={m.id} data-model-slug={m.slug}>
                <div className="admin-model-main">
                  <div className="admin-model-title">
                    <strong>{m.display_name}</strong>
                    <Badge variant={statusVariant(m.status)}>{m.status}</Badge>
                    {m.is_default && <Badge variant="default">Default</Badge>}
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
                </div>
                <div className="admin-model-health">
                  <span>
                    {m.last_latency_ms !== null ? `${m.last_latency_ms} ms` : "Not tested"}
                  </span>
                  <small className="muted">{formatChecked(m.last_checked_at)}</small>
                  <small className="muted">Priority {m.parameters.fallback_priority}</small>
                </div>
                <div className="admin-model-actions">
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    disabled={rowBusy}
                    onClick={() => onProbe(m)}
                  >
                    <Activity size={14} />
                    {rowBusy ? "Testing…" : "Test connection"}
                  </Button>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    disabled={rowBusy}
                    aria-pressed={m.enabled}
                    onClick={() => onToggle(m)}
                  >
                    <Power size={14} />
                    {m.enabled ? "Disable" : "Enable"}
                  </Button>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    disabled={rowBusy}
                    onClick={() => onConfigure(m)}
                  >
                    <Settings2 size={14} />
                    Configure
                  </Button>
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    disabled={rowBusy}
                    onClick={() => setConfirmDeleteId(confirmDeleteId === m.id ? null : m.id)}
                  >
                    <Trash2 size={14} />
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
