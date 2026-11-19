"use client"

import { useState } from "react"
import { Activity, CheckSquare, Power, X } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { AdminApiError, type ConnectedModel } from "@/lib/adminModels"
import {
  BATCH_PROBE_MAX,
  BATCH_TOGGLE_MAX,
  batchProbeAdminModels,
  batchToggleAdminModels,
  type BatchProbeResponse,
} from "@/lib/adminModelPresets"

type ModelBatchBarProps = {
  visibleCount: number
  selectedIds: string[]
  allVisibleSelected: boolean
  disabled: boolean
  modelNamesById: Record<string, string>
  onToggleSelectVisible: () => void
  onClearSelection: () => void
  onBusyChange: (busy: boolean) => void
  onBatchUpdated: (models: Array<ConnectedModel | null | undefined>, statusMessage: string) => void
  onBatchError: (message: string) => void
  onAuthInvalid: (message: string) => void
}

export function ModelBatchBar(props: ModelBatchBarProps) {
  const { visibleCount, selectedIds, allVisibleSelected, disabled, modelNamesById } = props
  const [busy, setBusy] = useState(false)
  const [probeSummary, setProbeSummary] = useState<BatchProbeResponse | null>(null)

  const selectedCount = selectedIds.length
  const controlsLocked = busy || disabled
  const overToggleLimit = selectedCount > BATCH_TOGGLE_MAX
  const overProbeLimit = selectedCount > BATCH_PROBE_MAX

  async function runBatch(action: "enable" | "disable" | "probe") {
    if (!selectedCount || controlsLocked) return
    if (action === "probe" ? overProbeLimit : overToggleLimit) return
    setBusy(true)
    props.onBusyChange(true)
    props.onBatchError("")
    try {
      if (action === "probe") {
        const res = await batchProbeAdminModels(selectedIds)
        setProbeSummary(res)
        const noun = res.probed === 1 ? "model" : "models"
        props.onBatchUpdated(
          res.results.map((item) => item.model),
          `Probed ${res.probed} ${noun}: ${res.ok_count} connected, ${res.error_count} failed.`,
        )
      } else {
        const enabled = action === "enable"
        const res = await batchToggleAdminModels(selectedIds, enabled)
        const noun = res.updated === 1 ? "model" : "models"
        props.onBatchUpdated(res.models, `${res.updated} ${noun} ${enabled ? "enabled" : "disabled"}.`)
      }
    } catch (err) {
      if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) {
        props.onAuthInvalid(err.message)
      } else {
        props.onBatchError(err instanceof Error ? err.message : "Batch model operation failed.")
      }
    } finally {
      setBusy(false)
      props.onBusyChange(false)
    }
  }

  return (
    <div className="panel inset stack" role="region" aria-label="Batch model operations" style={{ padding: "12px 14px", gap: 10 }}>
      <div className="row" style={{ justifyContent: "space-between", flexWrap: "wrap", gap: 8 }}>
        <div className="row" style={{ flexWrap: "wrap", gap: 8 }}>
          <Badge variant={selectedCount > 0 ? "default" : "outline"} role="status" aria-live="polite">
            {selectedCount} selected
          </Badge>
          <Button type="button" variant="outline" size="sm" className="max-sm:min-h-11" disabled={controlsLocked || visibleCount === 0} onClick={props.onToggleSelectVisible}>
            <CheckSquare size={14} aria-hidden="true" />
            {allVisibleSelected ? "Deselect visible" : `Select visible (${visibleCount})`}
          </Button>
          {selectedCount > 0 && (
            <Button type="button" variant="ghost" size="sm" className="max-sm:min-h-11" disabled={controlsLocked} onClick={props.onClearSelection}>
              <X size={14} aria-hidden="true" />
              Clear selection
            </Button>
          )}
        </div>

        <div className="row" style={{ flexWrap: "wrap", gap: 8 }}>
          <Button type="button" variant="outline" size="sm" className="max-sm:min-h-11" disabled={controlsLocked || selectedCount === 0 || overToggleLimit} onClick={() => void runBatch("enable")}>
            <Power size={14} aria-hidden="true" />
            Activate selected
          </Button>
          <Button type="button" variant="outline" size="sm" className="max-sm:min-h-11" disabled={controlsLocked || selectedCount === 0 || overToggleLimit} onClick={() => void runBatch("disable")}>
            <Power size={14} aria-hidden="true" />
            Pause selected
          </Button>
          <Button type="button" variant="outline" size="sm" className="max-sm:min-h-11" disabled={controlsLocked || selectedCount === 0 || overProbeLimit} onClick={() => void runBatch("probe")}>
            <Activity size={14} aria-hidden="true" />
            {busy ? "Running…" : "Batch probe"}
          </Button>
        </div>
      </div>

      {overToggleLimit && <small className="error">Batch toggle supports at most {BATCH_TOGGLE_MAX} models at once.</small>}
      {!overToggleLimit && overProbeLimit && <small className="muted">Batch probe supports up to {BATCH_PROBE_MAX} models per run.</small>}

      {probeSummary && (
        <div className="stack" role="status" aria-live="polite" aria-label="Batch probe results" style={{ gap: 6 }}>
          <div className="row" style={{ justifyContent: "space-between", flexWrap: "wrap", gap: 8 }}>
            <small className="muted">
              Batch probe summary: {probeSummary.ok_count} connected, {probeSummary.error_count} failed out of {probeSummary.probed}.
            </small>
            <Button type="button" variant="ghost" size="sm" onClick={() => setProbeSummary(null)}>
              Dismiss
            </Button>
          </div>
          <ul className="stack" style={{ listStyle: "none", padding: 0, margin: 0, gap: 6 }}>
            {probeSummary.results.map((item) => (
              <li key={item.id} className="row" style={{ flexWrap: "wrap", gap: 8, alignItems: "center", minWidth: 0 }}>
                <strong>{modelNamesById[item.id] ?? item.model?.display_name ?? item.id}</strong>
                <Badge variant={item.ok ? "success" : "destructive"}>{item.status}</Badge>
                {item.latency_ms !== null && <span className="admin-mono">{item.latency_ms} ms</span>}
                {item.detail && <small className={item.ok ? "muted" : "error"}>{item.detail}</small>}
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}
