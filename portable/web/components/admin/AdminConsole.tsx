"use client"

import dynamic from "next/dynamic"
import { useCallback, useEffect, useRef, useState, type KeyboardEvent as ReactKeyboardEvent } from "react"
import { Cpu, FileClock, Plus, RefreshCw, Stethoscope, Users, type LucideIcon } from "lucide-react"
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
import { type ProviderStatus } from "@/lib/integrations"
import { type AccountSnapshot } from "@/lib/useAccountStatus"
import { AdminGate } from "./AdminGate"
import { ModelHealthDrawer } from "./ModelHealthDrawer"
import { ModelList } from "./ModelList"
import { ModelSummaryCards } from "./ModelSummaryCards"
import { RoutingSimulatorPanel } from "./RoutingSimulatorPanel"
import "./AdminConsole.css"

const AccountsTab = dynamic(() => import("./AccountsTab").then((m) => m.AccountsTab), { ssr: false })
const AuditLogTab = dynamic(() => import("./AuditLogTab").then((m) => m.AuditLogTab), { ssr: false })
const DiagnosticsTab = dynamic(() => import("./DiagnosticsTab").then((m) => m.DiagnosticsTab), { ssr: false })
const ModelFormModal = dynamic(() => import("./ModelFormModal").then((m) => m.ModelFormModal), { ssr: false })

type AdminTab = "models" | "accounts" | "audit" | "diagnostics"

const ADMIN_TABS: readonly { id: AdminTab; label: string; Icon: LucideIcon }[] = [
  { id: "models", label: "Models", Icon: Cpu },
  { id: "accounts", label: "Accounts", Icon: Users },
  { id: "audit", label: "Audit log", Icon: FileClock },
  { id: "diagnostics", label: "Diagnostics", Icon: Stethoscope },
]

export default function AdminConsole() {
  const [status, setStatus] = useState<ProviderStatus | null>(null)
  const [account, setAccount] = useState<AccountSnapshot | null>(null)
  const [gateLoading, setGateLoading] = useState(true)
  const [gateError, setGateError] = useState("")

  const [tab, setTab] = useState<AdminTab>("models")
  const tabRefs = useRef<Partial<Record<AdminTab, HTMLButtonElement | null>>>({})
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

  function handleTabKeyDown(e: ReactKeyboardEvent<HTMLButtonElement>, current: AdminTab) {
    const idx = ADMIN_TABS.findIndex((item) => item.id === current)
    const offset = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : null
    const nextIdx = offset !== null ? (idx + offset + ADMIN_TABS.length) % ADMIN_TABS.length : e.key === "Home" ? 0 : e.key === "End" ? ADMIN_TABS.length - 1 : -1
    if (idx < 0 || nextIdx < 0) return
    e.preventDefault()
    const nextTab = ADMIN_TABS[nextIdx].id
    setTab(nextTab)
    tabRefs.current[nextTab]?.focus()
  }

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

  const handleAuthFailure = useCallback(
    (err: unknown): boolean => {
      if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) {
        setGateError(err.message)
        void bootstrap(true)
        return true
      }
      return false
    },
    [bootstrap],
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

      <div className="admin-tabs" role="tablist" aria-label="Admin sections">
        {ADMIN_TABS.map(({ id, label, Icon }) => {
          const selected = tab === id
          return (
            <button
              key={id}
              ref={(el) => { tabRefs.current[id] = el }}
              id={`tab-${id}`}
              type="button"
              role="tab"
              aria-selected={selected}
              aria-controls={`panel-${id}`}
              tabIndex={selected ? 0 : -1}
              className="admin-tab"
              onClick={() => setTab(id)}
              onKeyDown={(e) => handleTabKeyDown(e, id)}
            >
              <Icon size={15} aria-hidden="true" />
              {label}
            </button>
          )
        })}
      </div>

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
              />
              <RoutingSimulatorPanel onAuthInvalid={(msg) => { setGateError(msg); void bootstrap(true) }} />
            </>
          )}
        </div>
      )}

      {tab === "accounts" && (
        <div id="panel-accounts" role="tabpanel" aria-labelledby="tab-accounts">
          <AccountsTab onAuthInvalid={(msg) => { setGateError(msg); void bootstrap(true) }} />
        </div>
      )}

      {tab === "audit" && (
        <div id="panel-audit" role="tabpanel" aria-labelledby="tab-audit">
          <AuditLogTab onAuthInvalid={(msg) => { setGateError(msg); void bootstrap(true) }} />
        </div>
      )}

      {tab === "diagnostics" && (
        <div id="panel-diagnostics" role="tabpanel" aria-labelledby="tab-diagnostics">
          <DiagnosticsTab models={models} onAuthInvalid={(msg) => { setGateError(msg); void bootstrap(true) }} />
        </div>
      )}

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
