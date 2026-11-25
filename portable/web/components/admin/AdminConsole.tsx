"use client"

import dynamic from "next/dynamic"
import { useCallback, useEffect, useState } from "react"
import { BarChart3, Cpu, FileClock, FlaskConical, Plus, RefreshCw, ShieldAlert, ShieldCheck, SlidersHorizontal, Stethoscope, Users } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { getAdminDiagnostics, type DiagnosticsData } from "@/lib/adminDiagnostics"
import {
  AdminApiError,
  deleteAdminModel,
  listAdminModels,
  probeAdminModel,
  toggleAdminModel,
  type ConnectedModel,
  type EnvFallback,
} from "@/lib/adminModels"
import {
  getFleetTelemetry,
  type FleetTelemetryResponse,
} from "@/lib/adminTelemetry"
import { mergeBatchModels } from "@/lib/adminModelPresets"
import { useDirtyRegistry } from "@/lib/dirtyTracking"
import { useDraftGuard } from "@/lib/useDraftGuard"
import { AdminGate } from "./AdminGate"
import { AdminTabNav, type AdminTabItem } from "./AdminTabNav"
import { AdminTabPanel } from "./AdminTabPanel"
import { ModelHealthDrawer } from "./ModelHealthDrawer"
import { ModelList } from "./ModelList"
import { ModelSummaryCards } from "./ModelSummaryCards"
import { RoutingSimulatorPanel } from "./RoutingSimulatorPanel"
import { useAdminAccess } from "./useAdminAccess"
import "./AdminConsole.css"

const AccountsTab = dynamic(() => import("./AccountsTab").then((m) => m.AccountsTab), { ssr: false })
const AuditLogTab = dynamic(() => import("./AuditLogTab").then((m) => m.AuditLogTab), { ssr: false })
const ComplianceTab = dynamic(() => import("./ComplianceTab").then((m) => m.ComplianceTab), { ssr: false })
const DiagnosticsTab = dynamic(() => import("./DiagnosticsTab").then((m) => m.DiagnosticsTab), { ssr: false })
const PlaygroundTab = dynamic(() => import("./PlaygroundTab").then((m) => m.PlaygroundTab), { ssr: false })
const PromptsAndSlaTab = dynamic(() => import("./PromptsAndSlaTab").then((m) => m.PromptsAndSlaTab), { ssr: false })
const SecurityAlertsTab = dynamic(() => import("./SecurityAlertsTab").then((m) => m.SecurityAlertsTab), { ssr: false })
const UsageTab = dynamic(() => import("./UsageTab").then((m) => m.UsageTab), { ssr: false })
const ModelFormModal = dynamic(() => import("./ModelFormModal").then((m) => m.ModelFormModal), { ssr: false })

type AdminTab = "models" | "accounts" | "usage" | "audit" | "diagnostics" | "playground" | "security" | "prompts" | "compliance"

const ADMIN_TABS: readonly AdminTabItem<AdminTab>[] = [
  { id: "models", label: "Models", Icon: Cpu },
  { id: "accounts", label: "Accounts", Icon: Users },
  { id: "usage", label: "Usage", Icon: BarChart3 },
  { id: "audit", label: "Audit log", Icon: FileClock },
  { id: "diagnostics", label: "Diagnostics", Icon: Stethoscope },
  { id: "playground", label: "Playground", Icon: FlaskConical },
  { id: "security", label: "Security", Icon: ShieldAlert },
  { id: "prompts", label: "Prompts & SLA", Icon: SlidersHorizontal },
  { id: "compliance", label: "Compliance", Icon: ShieldCheck },
]

export default function AdminConsole() {
  const access = useAdminAccess()
  const { status, setStatus, account, setAccount, onAuthInvalid } = access

  const [tab, setTab] = useState<AdminTab>("models")
  const [openedTabs, setOpenedTabs] = useState<ReadonlySet<AdminTab>>(() => new Set<AdminTab>(["models"]))
  const { anyDirty, reporterFor } = useDirtyRegistry()
  useDraftGuard(anyDirty, "Discard unsaved admin changes and leave this page?")
  const [models, setModels] = useState<ConnectedModel[]>([])
  const [envFallbacks, setEnvFallbacks] = useState<EnvFallback[]>([])
  const [fleetTelemetry, setFleetTelemetry] = useState<FleetTelemetryResponse | null>(null)
  const [diagnostics, setDiagnostics] = useState<DiagnosticsData | null>(null)
  const [modelsLoading, setModelsLoading] = useState(true)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [bannerError, setBannerError] = useState("")
  const [bannerStatus, setBannerStatus] = useState("")
  const [modalOpen, setModalOpen] = useState(false)
  const [editing, setEditing] = useState<ConnectedModel | null>(null)
  const [healthModel, setHealthModel] = useState<ConnectedModel | null>(null)

  function selectTab(next: AdminTab) {
    setTab(next)
    setOpenedTabs((prev) => (prev.has(next) ? prev : new Set(prev).add(next)))
  }

  const handleAuthFailure = useCallback(
    (err: unknown): boolean => {
      if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) {
        onAuthInvalid(err.message)
        return true
      }
      return false
    },
    [onAuthInvalid],
  )

  const refreshTelemetry = useCallback(async () => {
    try {
      const next = await getFleetTelemetry()
      setFleetTelemetry(next)
    } catch (err) {
      if (!handleAuthFailure(err)) {
        setFleetTelemetry(null)
      }
    }
  }, [handleAuthFailure])

  const refreshDiagnostics = useCallback(async () => {
    try {
      const next = await getAdminDiagnostics()
      setDiagnostics(next)
    } catch (err) {
      if (!handleAuthFailure(err)) {
        setDiagnostics(null)
      }
    }
  }, [handleAuthFailure])

  const loadModels = useCallback(async () => {
    setModelsLoading(true)
    setBannerError("")
    const ignoreNonAuth = (err: unknown) => {
      if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) throw err
      return null
    }
    try {
      const [data, telemetryData, diagData] = await Promise.all([
        listAdminModels(),
        getFleetTelemetry().catch(ignoreNonAuth),
        getAdminDiagnostics().catch(ignoreNonAuth),
      ])
      setModels(data.models)
      setEnvFallbacks(data.envFallbacks)
      setFleetTelemetry(telemetryData)
      setDiagnostics(diagData)
    } catch (err) {
      if (handleAuthFailure(err)) return
      setBannerError(err instanceof Error ? err.message : "Could not load models.")
    } finally {
      setModelsLoading(false)
    }
  }, [handleAuthFailure])

  useEffect(() => {
    if (account?.admin) {
      void loadModels()
    }
  }, [account?.admin, loadModels])

  async function handleProbe(model: ConnectedModel) {
    setBusyId(model.id)
    setBannerError("")
    setBannerStatus("")
    try {
      const res = await probeAdminModel(model.id)
      setModels((prev) => prev.map((m) => (m.id === res.model.id ? res.model : m)))
      void refreshTelemetry()
      if (res.ok) {
        setBannerStatus(`${res.model.display_name} connected (${res.model.last_latency_ms ?? 0} ms).`)
      } else {
        setBannerError(res.detail || res.model.last_error || "Model probe failed.")
      }
    } catch (err) {
      if (!handleAuthFailure(err)) setBannerError(err instanceof Error ? err.message : "Probe failed.")
    } finally {
      setBusyId(null)
    }
  }

  async function handleToggle(model: ConnectedModel) {
    setBusyId(model.id)
    setBannerError("")
    setBannerStatus("")
    try {
      const updated = await toggleAdminModel(model.id, !model.enabled)
      setModels((prev) => prev.map((m) => (m.id === updated.id ? updated : m)))
      void refreshTelemetry()
      setBannerStatus(`${updated.display_name} ${updated.enabled ? "enabled" : "disabled"}.`)
    } catch (err) {
      if (!handleAuthFailure(err)) setBannerError(err instanceof Error ? err.message : "Could not toggle model.")
    } finally {
      setBusyId(null)
    }
  }

  async function handleDelete(model: ConnectedModel) {
    setBusyId(model.id)
    setBannerError("")
    setBannerStatus("")
    try {
      await deleteAdminModel(model.id)
      setModels((prev) => prev.filter((m) => m.id !== model.id))
      if (healthModel?.id === model.id) setHealthModel(null)
      void refreshTelemetry()
      setBannerStatus(`Disconnected ${model.display_name}.`)
    } catch (err) {
      if (!handleAuthFailure(err)) setBannerError(err instanceof Error ? err.message : "Could not disconnect model.")
    } finally {
      setBusyId(null)
    }
  }

  if (access.loading || !status?.access || !account || !account.admin) {
    return (
      <AdminGate
        loading={access.loading}
        status={status}
        account={account}
        error={access.error}
        onError={access.setError}
        onRetry={access.retry}
        onSignedIn={(next) => {
          setAccount(next)
          setStatus((prev) => (prev ? { ...prev, signedIn: true } : prev))
        }}
        onSignedOut={() => {
          setAccount(null)
          setModels([])
          setModelsLoading(true)
          setFleetTelemetry(null)
          setDiagnostics(null)
          setHealthModel(null)
          setStatus((prev) => (prev ? { ...prev, signedIn: false } : prev))
        }}
      />
    )
  }

  return (
    <div className="admin-console">
      <header className="admin-header">
        <div className="admin-header-copy">
          <span className="eyebrow">ADMINISTRATION</span>
          <h1>Model administration</h1>
          <p>Register, configure, test, and manage AI and transcription providers.</p>
        </div>
        <div className="admin-header-actions">
          <Badge variant="default">Admin: {account.email}</Badge>
          <Button type="button" variant="outline" size="sm" disabled={modelsLoading} onClick={() => { access.setError(""); void loadModels() }}>
            <RefreshCw size={14} aria-hidden="true" />
            Refresh
          </Button>
          <Button type="button" size="sm" onClick={() => { setEditing(null); setModalOpen(true) }}>
            <Plus size={14} aria-hidden="true" />
            Connect model
          </Button>
        </div>
      </header>

      <AdminTabNav tabs={ADMIN_TABS} activeTab={tab} onSelect={selectTab} />

      {(bannerError || access.error) && <p role="alert" className="error">{bannerError || access.error}</p>}
      {bannerStatus && <p role="status" className="notice">{bannerStatus}</p>}

      <AdminTabPanel id="models" active={tab === "models"} opened className="stack">
        <ModelSummaryCards
          models={models}
          envFallbacks={envFallbacks}
          telemetry={fleetTelemetry?.summary ?? null}
        />
        {modelsLoading ? (
          <p role="status" className="panel inset muted">Loading connected models…</p>
        ) : (
          <ModelList
            models={models}
            busyId={busyId}
            telemetryByModel={fleetTelemetry?.models}
            usageByModel={diagnostics?.usageByModel}
            onConnect={() => { setEditing(null); setModalOpen(true) }}
            onConfigure={(m) => { setEditing(m); setModalOpen(true) }}
            onProbe={(m) => void handleProbe(m)}
            onToggle={(m) => void handleToggle(m)}
            onDelete={(m) => void handleDelete(m)}
            onViewHealth={(m) => setHealthModel(m)}
            onBatchUpdated={(updated, msg) => {
              setModels((prev) => mergeBatchModels(prev, updated))
              void refreshTelemetry()
              setBannerError("")
              setBannerStatus(msg)
            }}
            onBatchError={(msg) => { if (msg) setBannerStatus(""); setBannerError(msg) }}
            onAuthInvalid={onAuthInvalid}
          />
        )}
        {/* Outside the loading branch so a header Refresh keeps the simulator's inputs and result. */}
        <RoutingSimulatorPanel onAuthInvalid={onAuthInvalid} />
      </AdminTabPanel>

      <AdminTabPanel id="accounts" active={tab === "accounts"} opened={openedTabs.has("accounts")}><AccountsTab onAuthInvalid={onAuthInvalid} /></AdminTabPanel>
      <AdminTabPanel id="usage" active={tab === "usage"} opened={openedTabs.has("usage")}><UsageTab onAuthInvalid={onAuthInvalid} onOpenModels={() => selectTab("models")} /></AdminTabPanel>
      <AdminTabPanel id="audit" active={tab === "audit"} opened={openedTabs.has("audit")}><AuditLogTab onAuthInvalid={onAuthInvalid} /></AdminTabPanel>
      <AdminTabPanel id="diagnostics" active={tab === "diagnostics"} opened={openedTabs.has("diagnostics")}><DiagnosticsTab models={models} onAuthInvalid={onAuthInvalid} /></AdminTabPanel>
      <AdminTabPanel id="playground" active={tab === "playground"} opened={openedTabs.has("playground")}><PlaygroundTab models={models} onAuthInvalid={onAuthInvalid} /></AdminTabPanel>
      <AdminTabPanel id="security" active={tab === "security"} opened={openedTabs.has("security")}><SecurityAlertsTab onAuthInvalid={onAuthInvalid} onDirtyChange={reporterFor("security")} /></AdminTabPanel>
      <AdminTabPanel id="prompts" active={tab === "prompts"} opened={openedTabs.has("prompts")}><PromptsAndSlaTab models={models} onAuthInvalid={onAuthInvalid} onDirtyChange={reporterFor("prompts")} /></AdminTabPanel>
      <AdminTabPanel id="compliance" active={tab === "compliance"} opened={openedTabs.has("compliance")}><ComplianceTab onAuthInvalid={onAuthInvalid} /></AdminTabPanel>

      {modalOpen && (
        <ModelFormModal
          editing={editing}
          onClose={() => setModalOpen(false)}
          onSaved={(saved, created) => {
            setModalOpen(false)
            setModels((prev) => {
              const synced = saved.is_default
                ? prev.map((m) =>
                    m.capability === saved.capability && m.id !== saved.id ? { ...m, is_default: false } : m,
                  )
                : prev
              return created ? [saved, ...synced] : synced.map((m) => (m.id === saved.id ? saved : m))
            })
            void refreshTelemetry()
            void refreshDiagnostics()
            setBannerStatus(created ? `Connected ${saved.display_name}.` : `Updated ${saved.display_name}.`)
          }}
        />
      )}

      {healthModel && (
        <ModelHealthDrawer
          model={healthModel}
          onClose={() => setHealthModel(null)}
          onAuthInvalid={(msg) => {
            setHealthModel(null)
            onAuthInvalid(msg)
          }}
        />
      )}
    </div>
  )
}
