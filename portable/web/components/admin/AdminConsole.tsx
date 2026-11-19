"use client"

import dynamic from "next/dynamic"
import { useCallback, useEffect, useState } from "react"
import { Cpu, FileClock, FlaskConical, Plus, RefreshCw, ShieldAlert, ShieldCheck, SlidersHorizontal, Stethoscope, Users } from "lucide-react"
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
import { type ProviderStatus } from "@/lib/integrations"
import { type AccountSnapshot } from "@/lib/useAccountStatus"
import { AdminGate } from "./AdminGate"
import { AdminTabNav, type AdminTabItem } from "./AdminTabNav"
import { ModelHealthDrawer } from "./ModelHealthDrawer"
import { ModelList } from "./ModelList"
import { ModelSummaryCards } from "./ModelSummaryCards"
import { RoutingSimulatorPanel } from "./RoutingSimulatorPanel"
import "./AdminConsole.css"

const AccountsTab = dynamic(() => import("./AccountsTab").then((m) => m.AccountsTab), { ssr: false })
const AuditLogTab = dynamic(() => import("./AuditLogTab").then((m) => m.AuditLogTab), { ssr: false })
const ComplianceTab = dynamic(() => import("./ComplianceTab").then((m) => m.ComplianceTab), { ssr: false })
const DiagnosticsTab = dynamic(() => import("./DiagnosticsTab").then((m) => m.DiagnosticsTab), { ssr: false })
const PlaygroundTab = dynamic(() => import("./PlaygroundTab").then((m) => m.PlaygroundTab), { ssr: false })
const PromptsAndSlaTab = dynamic(() => import("./PromptsAndSlaTab").then((m) => m.PromptsAndSlaTab), { ssr: false })
const SecurityAlertsTab = dynamic(() => import("./SecurityAlertsTab").then((m) => m.SecurityAlertsTab), { ssr: false })
const ModelFormModal = dynamic(() => import("./ModelFormModal").then((m) => m.ModelFormModal), { ssr: false })

type AdminTab = "models" | "accounts" | "audit" | "diagnostics" | "playground" | "security" | "prompts" | "compliance"

const ADMIN_TABS: readonly AdminTabItem<AdminTab>[] = [
  { id: "models", label: "Models", Icon: Cpu },
  { id: "accounts", label: "Accounts", Icon: Users },
  { id: "audit", label: "Audit log", Icon: FileClock },
  { id: "diagnostics", label: "Diagnostics", Icon: Stethoscope },
  { id: "playground", label: "Playground", Icon: FlaskConical },
  { id: "security", label: "Security", Icon: ShieldAlert },
  { id: "prompts", label: "Prompts & SLA", Icon: SlidersHorizontal },
  { id: "compliance", label: "Compliance", Icon: ShieldCheck },
]

export default function AdminConsole() {
  const [status, setStatus] = useState<ProviderStatus | null>(null)
  const [account, setAccount] = useState<AccountSnapshot | null>(null)
  const [gateLoading, setGateLoading] = useState(true)
  const [gateError, setGateError] = useState("")

  const [tab, setTab] = useState<AdminTab>("models")
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

  const bootstrap = useCallback(async (preserveError = false) => {
    setGateLoading(true)
    if (!preserveError) setGateError("")
    try {
      const res = await fetch("/api/integrations/status", { cache: "no-store" })
      if (!res.ok) throw new Error(`Could not check workspace status (HTTP ${res.status}).`)
      const nextStatus = (await res.json()) as ProviderStatus
      setStatus(nextStatus)
      if (!nextStatus.access || !nextStatus.signedIn) {
        setAccount(null)
        return
      }
      const acctRes = await fetch("/api/integrations/account", { cache: "no-store" })
      if (!acctRes.ok) {
        setAccount(null)
        return
      }
      setAccount((await acctRes.json()) as AccountSnapshot)
    } catch (err) {
      setGateError(err instanceof Error ? err.message : "Could not check account status.")
    } finally {
      setGateLoading(false)
    }
  }, [])

  const onAuthInvalid = useCallback(
    (msg: string) => {
      setGateError(msg)
      void bootstrap(true)
    },
    [bootstrap],
  )

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
    void bootstrap()
  }, [bootstrap])

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

  if (gateLoading || !status?.access || !account || !account.admin) {
    return (
      <AdminGate
        loading={gateLoading}
        status={status}
        account={account}
        error={gateError}
        onError={setGateError}
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
          <Button type="button" variant="outline" size="sm" disabled={modelsLoading} onClick={() => void loadModels()}>
            <RefreshCw size={14} aria-hidden="true" />
            Refresh
          </Button>
          <Button type="button" size="sm" onClick={() => { setEditing(null); setModalOpen(true) }}>
            <Plus size={14} aria-hidden="true" />
            Connect model
          </Button>
        </div>
      </header>

      <AdminTabNav tabs={ADMIN_TABS} activeTab={tab} onSelect={setTab} />

      {bannerError && <p role="alert" className="error">{bannerError}</p>}
      {bannerStatus && <p role="status" className="notice">{bannerStatus}</p>}

      {tab === "models" && (
        <div id="panel-models" role="tabpanel" aria-labelledby="tab-models" className="stack">
          <ModelSummaryCards
            models={models}
            envFallbacks={envFallbacks}
            telemetry={fleetTelemetry?.summary ?? null}
          />
          {modelsLoading ? (
            <p role="status" className="panel inset muted">Loading connected models…</p>
          ) : (
            <>
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
              <RoutingSimulatorPanel onAuthInvalid={onAuthInvalid} />
            </>
          )}
        </div>
      )}

      {tab === "accounts" && <div id="panel-accounts" role="tabpanel" aria-labelledby="tab-accounts"><AccountsTab onAuthInvalid={onAuthInvalid} /></div>}
      {tab === "audit" && <div id="panel-audit" role="tabpanel" aria-labelledby="tab-audit"><AuditLogTab onAuthInvalid={onAuthInvalid} /></div>}
      {tab === "diagnostics" && <div id="panel-diagnostics" role="tabpanel" aria-labelledby="tab-diagnostics"><DiagnosticsTab models={models} onAuthInvalid={onAuthInvalid} /></div>}
      {tab === "playground" && <div id="panel-playground" role="tabpanel" aria-labelledby="tab-playground"><PlaygroundTab models={models} onAuthInvalid={onAuthInvalid} /></div>}
      {tab === "security" && <div id="panel-security" role="tabpanel" aria-labelledby="tab-security"><SecurityAlertsTab onAuthInvalid={onAuthInvalid} /></div>}
      {tab === "prompts" && <div id="panel-prompts" role="tabpanel" aria-labelledby="tab-prompts"><PromptsAndSlaTab models={models} onAuthInvalid={onAuthInvalid} /></div>}
      {tab === "compliance" && <div id="panel-compliance" role="tabpanel" aria-labelledby="tab-compliance"><ComplianceTab onAuthInvalid={onAuthInvalid} /></div>}

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
            setGateError(msg)
            void bootstrap(true)
          }}
        />
      )}
    </div>
  )
}
