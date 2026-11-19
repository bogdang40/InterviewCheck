"use client"

import { useCallback, useEffect, useState } from "react"
import { Cpu, FileClock, Plus, RefreshCw, Users } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  AdminApiError,
  deleteAdminModel,
  listAdminModels,
  probeAdminModel,
  toggleAdminModel,
  type ConnectedModel,
  type EnvFallback,
} from "@/lib/adminModels"
import { type ProviderStatus } from "@/lib/integrations"
import { type AccountSnapshot } from "@/lib/useAccountStatus"
import { AccountsTab } from "./AccountsTab"
import { AdminGate } from "./AdminGate"
import { AuditLogTab } from "./AuditLogTab"
import { ModelFormModal } from "./ModelFormModal"
import { ModelList } from "./ModelList"
import { ModelSummaryCards } from "./ModelSummaryCards"
import "./AdminConsole.css"

type AdminTab = "models" | "accounts" | "audit"

export default function AdminConsole() {
  const [status, setStatus] = useState<ProviderStatus | null>(null)
  const [account, setAccount] = useState<AccountSnapshot | null>(null)
  const [gateLoading, setGateLoading] = useState(true)
  const [gateError, setGateError] = useState("")

  const [tab, setTab] = useState<AdminTab>("models")
  const [models, setModels] = useState<ConnectedModel[]>([])
  const [envFallbacks, setEnvFallbacks] = useState<EnvFallback[]>([])
  const [modelsLoading, setModelsLoading] = useState(false)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [bannerError, setBannerError] = useState("")
  const [bannerStatus, setBannerStatus] = useState("")
  const [modalOpen, setModalOpen] = useState(false)
  const [editing, setEditing] = useState<ConnectedModel | null>(null)

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

  const loadModels = useCallback(async () => {
    setModelsLoading(true)
    setBannerError("")
    try {
      const data = await listAdminModels()
      setModels(data.models)
      setEnvFallbacks(data.envFallbacks)
    } catch (err) {
      if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) {
        setGateError(err.message)
        void bootstrap(true)
        return
      }
      setBannerError(err instanceof Error ? err.message : "Could not load models.")
    } finally {
      setModelsLoading(false)
    }
  }, [bootstrap])

  useEffect(() => {
    void bootstrap()
  }, [bootstrap])

  useEffect(() => {
    if (account?.admin) {
      void loadModels()
    }
  }, [account?.admin, loadModels])

  function handleAuthFailure(err: unknown): boolean {
    if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) {
      setGateError(err.message)
      void bootstrap(true)
      return true
    }
    return false
  }

  async function handleProbe(model: ConnectedModel) {
    setBusyId(model.id)
    setBannerError("")
    setBannerStatus("")
    try {
      const res = await probeAdminModel(model.id)
      setModels((prev) => prev.map((m) => (m.id === res.model.id ? res.model : m)))
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
            <RefreshCw size={14} />
            Refresh
          </Button>
          <Button type="button" size="sm" onClick={() => { setEditing(null); setModalOpen(true) }}>
            <Plus size={14} />
            Connect model
          </Button>
        </div>
      </header>

      <div className="admin-tabs" role="tablist" aria-label="Admin sections">
        <button id="tab-models" type="button" role="tab" aria-selected={tab === "models"} className="admin-tab" onClick={() => setTab("models")}>
          <Cpu size={15} aria-hidden="true" />
          Models
        </button>
        <button id="tab-accounts" type="button" role="tab" aria-selected={tab === "accounts"} className="admin-tab" onClick={() => setTab("accounts")}>
          <Users size={15} aria-hidden="true" />
          Accounts
        </button>
        <button id="tab-audit" type="button" role="tab" aria-selected={tab === "audit"} className="admin-tab" onClick={() => setTab("audit")}>
          <FileClock size={15} aria-hidden="true" />
          Audit log
        </button>
      </div>

      {bannerError && <p role="alert" className="error">{bannerError}</p>}
      {bannerStatus && <p role="status" className="notice">{bannerStatus}</p>}

      {tab === "models" && (
        <div role="tabpanel" aria-labelledby="tab-models" className="stack">
          <ModelSummaryCards models={models} envFallbacks={envFallbacks} />
          {modelsLoading ? (
            <p role="status" className="panel inset muted">Loading connected models…</p>
          ) : (
            <ModelList
              models={models}
              busyId={busyId}
              onConnect={() => { setEditing(null); setModalOpen(true) }}
              onConfigure={(m) => { setEditing(m); setModalOpen(true) }}
              onProbe={(m) => void handleProbe(m)}
              onToggle={(m) => void handleToggle(m)}
              onDelete={(m) => void handleDelete(m)}
            />
          )}
        </div>
      )}

      {tab === "accounts" && (
        <div role="tabpanel" aria-labelledby="tab-accounts">
          <AccountsTab onAuthInvalid={(msg) => { setGateError(msg); void bootstrap(true) }} />
        </div>
      )}

      {tab === "audit" && (
        <div role="tabpanel" aria-labelledby="tab-audit">
          <AuditLogTab onAuthInvalid={(msg) => { setGateError(msg); void bootstrap(true) }} />
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
            setBannerStatus(created ? `Connected ${saved.display_name}.` : `Updated ${saved.display_name}.`)
          }}
        />
      )}
    </div>
  )
}
