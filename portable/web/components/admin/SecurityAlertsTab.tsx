"use client"

import { useCallback, useEffect, useRef, useState, type FormEvent } from "react"
import { BellRing, LockOpen, Play, Plus, RefreshCw, ShieldAlert, Trash2, Users } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { AdminApiError, CAPABILITY_LABELS, listAdminUsers, type AdminMember, type ModelCapability } from "@/lib/adminModels"
import { useReportDirty, type DirtyReporter } from "@/lib/dirtyTracking"
import {
  ALERT_TRIGGER_LABELS, ALERT_TRIGGER_TYPES, clearAdminRateLimits, createAlertRule, deleteAlertRule,
  evaluateAlertRules, listAdminRateLimits, listAdminUserSessions, listAlertRules, revokeAdminUserSessions,
  testAlertRule, updateAlertRule, type AdminUserSession, type AlertRule,
  type AlertTriggerType, type RateLimitEntry,
} from "@/lib/adminSecurityAlerts"
import { AlertDeliveryHistoryPanel } from "./AlertDeliveryHistoryPanel"
import { CspReportsPanel } from "./CspReportsPanel"
import styles from "./SecurityAlertsTab.module.css"

const CAPABILITIES: readonly ModelCapability[] = ["reference", "question_planning", "transcription", "embedding", "judge"]
const fmt = (iso: string | null | undefined) => (!iso ? "Never" : Number.isNaN(new Date(iso).getTime()) ? iso : new Date(iso).toLocaleString())

export function SecurityAlertsTab({ onAuthInvalid, onDirtyChange }: { onAuthInvalid: (msg: string) => void; onDirtyChange?: DirtyReporter }) {
  const [rateLimits, setRateLimits] = useState<RateLimitEntry[]>([])
  const [rlLoading, setRlLoading] = useState(true), [rlError, setRlError] = useState("")
  const [accounts, setAccounts] = useState<AdminMember[]>([])
  const [userSearch, setUserSearch] = useState(""), [selectedUid, setSelectedUid] = useState("")
  const [userSessions, setUserSessions] = useState<AdminUserSession[]>([])
  const [sessionsLoading, setSessionsLoading] = useState(false), [sessionError, setSessionError] = useState("")
  const [rules, setRules] = useState<AlertRule[]>([])
  const [refreshTick, setRefreshTick] = useState(0)
  const [alertsLoading, setAlertsLoading] = useState(true), [alertsError, setAlertsError] = useState("")
  const [statusMsg, setStatusMsg] = useState(""), [busyKey, setBusyKey] = useState<string | null>(null)
  const [formOpen, setFormOpen] = useState(false)
  const [editingRule, setEditingRule] = useState<AlertRule | null>(null)
  const [name, setName] = useState(""), [triggerType, setTriggerType] = useState<AlertTriggerType>("model_error_streak")
  const [thresholdRaw, setThresholdRaw] = useState("3"), [capabilityFilter, setCapabilityFilter] = useState("")
  const [webhookUrl, setWebhookUrl] = useState(""), [signingSecret, setSigningSecret] = useState("")
  const [clearSecret, setClearSecret] = useState(false), [cooldownRaw, setCooldownRaw] = useState("15")
  const [enabled, setEnabled] = useState(true)
  const openedRule = useRef("")
  const ruleSnapshot = JSON.stringify([name, triggerType, thresholdRaw, capabilityFilter, webhookUrl, signingSecret, clearSecret, cooldownRaw, enabled])
  useReportDirty(formOpen && ruleSnapshot !== openedRule.current, onDirtyChange)

  const checkAuth = useCallback((err: unknown): boolean => {
    if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) { onAuthInvalid(err.message); return true }
    return false
  }, [onAuthInvalid])

  const loadRateLimits = useCallback(async () => {
    setRlLoading(true); setRlError("")
    try { setRateLimits(await listAdminRateLimits()) }
    catch (err) { if (!checkAuth(err)) setRlError(err instanceof Error ? err.message : "Could not load rate limits.") }
    finally { setRlLoading(false) }
  }, [checkAuth])

  const loadAccounts = useCallback(async (q = "") => {
    setSessionError("")
    try {
      const res = await listAdminUsers(q.trim() || undefined)
      setAccounts(res.users)
      setSelectedUid((prev) => (prev && res.users.some((u) => u.user.id === prev) ? prev : res.users[0]?.user.id ?? ""))
    } catch (err) { if (!checkAuth(err)) setSessionError(err instanceof Error ? err.message : "Could not load accounts.") }
  }, [checkAuth])

  const loadUserSessions = useCallback(async (uid: string) => {
    if (!uid) { setUserSessions([]); return }
    setSessionsLoading(true); setSessionError("")
    try { setUserSessions(await listAdminUserSessions(uid)) }
    catch (err) { if (!checkAuth(err)) setSessionError(err instanceof Error ? err.message : "Could not load user sessions.") }
    finally { setSessionsLoading(false) }
  }, [checkAuth])

  const loadAlerts = useCallback(async () => {
    setAlertsLoading(true); setAlertsError("")
    try { const res = await listAlertRules(); setRules(res.rules) }
    catch (err) { if (!checkAuth(err)) setAlertsError(err instanceof Error ? err.message : "Could not load alert rules.") }
    finally { setAlertsLoading(false) }
  }, [checkAuth])

  useEffect(() => { void loadRateLimits(); void loadAccounts(); void loadAlerts() }, [loadRateLimits, loadAccounts, loadAlerts])
  useEffect(() => { if (selectedUid) void loadUserSessions(selectedUid); else setUserSessions([]) }, [selectedUid, loadUserSessions])

  async function handleUnlock(entry?: RateLimitEntry) {
    setBusyKey(entry ? `rl:${entry.id}` : "rl:all"); setRlError(""); setStatusMsg("")
    try {
      const res = await clearAdminRateLimits(entry ? (entry.keyHash ? { keyHash: entry.keyHash } : { key: entry.key }) : undefined)
      setStatusMsg(entry ? `Unlocked ${entry.key} (${res.cleared} bucket cleared).` : `Cleared ${res.cleared} rate-limit buckets.`)
      await loadRateLimits()
    } catch (err) { if (!checkAuth(err)) setRlError(err instanceof Error ? err.message : "Could not clear rate limits.") }
    finally { setBusyKey(null) }
  }

  async function handleRevokeSessions(sessionId?: string) {
    if (!selectedUid) return
    setBusyKey(sessionId ? `sess:${sessionId}` : "sess:all"); setSessionError(""); setStatusMsg("")
    try {
      const res = await revokeAdminUserSessions(selectedUid, sessionId)
      setStatusMsg(`Revoked ${res.revokedCount} session(s) without disabling the account.`)
      await loadUserSessions(selectedUid)
    } catch (err) { if (!checkAuth(err)) setSessionError(err instanceof Error ? err.message : "Could not revoke user sessions.") }
    finally { setBusyKey(null) }
  }

  function openRuleForm(rule: AlertRule | null) {
    setEditingRule(rule); setName(rule?.name ?? ""); setTriggerType(rule?.trigger_type ?? "model_error_streak")
    setThresholdRaw(String(rule?.threshold_value ?? 3)); setCapabilityFilter(rule?.capability_filter ?? "")
    setWebhookUrl(rule?.webhook_url ?? ""); setSigningSecret(""); setClearSecret(false)
    setCooldownRaw(String(rule?.cooldown_minutes ?? 15)); setEnabled(rule?.enabled ?? true)
    setFormOpen(true); setAlertsError("")
    openedRule.current = JSON.stringify([
      rule?.name ?? "", rule?.trigger_type ?? "model_error_streak", String(rule?.threshold_value ?? 3), rule?.capability_filter ?? "",
      rule?.webhook_url ?? "", "", false, String(rule?.cooldown_minutes ?? 15), rule?.enabled ?? true,
    ])
  }

  async function handleSaveRule(e: FormEvent<HTMLFormElement>) {
    e.preventDefault(); setAlertsError(""); setStatusMsg("")
    const cleanName = name.trim(), cleanUrl = webhookUrl.trim()
    const threshold = Number(thresholdRaw), cooldown = Number.parseInt(cooldownRaw, 10)
    if (!cleanName || !cleanUrl) { setAlertsError("Alert name and webhook URL are required."); return }
    if (!Number.isFinite(threshold) || threshold < 0) { setAlertsError("Threshold must be a non-negative number."); return }
    if (!Number.isInteger(cooldown) || cooldown < 0 || cooldown > 1440) { setAlertsError("Cooldown must be between 0 and 1440 minutes."); return }
    setBusyKey("save-rule")
    try {
      const payload = {
        name: cleanName, trigger_type: triggerType, threshold_value: threshold,
        capability_filter: capabilityFilter || null, webhook_url: cleanUrl, cooldown_minutes: cooldown, enabled,
        ...(signingSecret.trim() ? { signing_secret: signingSecret.trim() } : {}),
        ...(editingRule && clearSecret ? { clear_signing_secret: true } : {}),
      }
      if (editingRule) { await updateAlertRule(editingRule.id, payload); setStatusMsg(`Updated alert rule ${cleanName}.`) }
      else { await createAlertRule(payload); setStatusMsg(`Created alert rule ${cleanName}.`) }
      setFormOpen(false); setEditingRule(null); await loadAlerts(); setRefreshTick((t) => t + 1)
    } catch (err) { if (!checkAuth(err)) setAlertsError(err instanceof Error ? err.message : "Could not save alert rule.") }
    finally { setBusyKey(null) }
  }

  async function handleToggleRule(rule: AlertRule) {
    setBusyKey(`toggle:${rule.id}`); setAlertsError("")
    try {
      const updated = await updateAlertRule(rule.id, { enabled: !rule.enabled })
      setRules((prev) => prev.map((r) => (r.id === updated.id ? updated : r)))
      setStatusMsg(`${updated.name} ${updated.enabled ? "enabled" : "disabled"}.`)
    } catch (err) { if (!checkAuth(err)) setAlertsError(err instanceof Error ? err.message : "Could not toggle alert rule.") }
    finally { setBusyKey(null) }
  }

  async function handleDeleteRule(rule: AlertRule) {
    setBusyKey(`del:${rule.id}`); setAlertsError("")
    try {
      await deleteAlertRule(rule.id)
      setRules((prev) => prev.filter((r) => r.id !== rule.id))
      setRefreshTick((t) => t + 1)
      setStatusMsg(`Deleted alert rule ${rule.name}.`)
    } catch (err) { if (!checkAuth(err)) setAlertsError(err instanceof Error ? err.message : "Could not delete alert rule.") }
    finally { setBusyKey(null) }
  }

  async function handleTestRule(rule: AlertRule) {
    setBusyKey(`test:${rule.id}`); setAlertsError(""); setStatusMsg("")
    try {
      const res = await testAlertRule(rule.id)
      if (res.ok) setStatusMsg(`Webhook test succeeded for ${rule.name} (HTTP ${res.delivery?.http_status ?? res.http_status ?? 200}).`)
      else setAlertsError(res.error || res.detail || `Webhook test failed for ${rule.name}.`)
      await loadAlerts(); setRefreshTick((t) => t + 1)
    } catch (err) { if (!checkAuth(err)) setAlertsError(err instanceof Error ? err.message : "Webhook test failed.") }
    finally { setBusyKey(null) }
  }

  async function handleEvaluateAll() {
    setBusyKey("evaluate"); setAlertsError(""); setStatusMsg("")
    try {
      const res = await evaluateAlertRules()
      setStatusMsg(`Evaluated ${res.evaluated ?? rules.length} rule(s); ${res.triggered ?? 0} triggered.`)
      await loadAlerts(); setRefreshTick((t) => t + 1)
    } catch (err) { if (!checkAuth(err)) setAlertsError(err instanceof Error ? err.message : "Could not evaluate alert rules.") }
    finally { setBusyKey(null) }
  }

  const selectedMember = accounts.find((a) => a.user.id === selectedUid) ?? null

  return (
    <div className={styles.securityTab}>
      {statusMsg && <p role="status" className="notice">{statusMsg}</p>}
      <section className="panel stack" aria-label="Rate limits and lockouts">
        <div className={styles.sectionHead}>
          <div>
            <h2 className="admin-sim-heading"><ShieldAlert size={18} aria-hidden="true" />Rate limits and lockouts</h2>
            <p className="muted">Inspect active rate-limit buckets and account lockouts, then unlock individual keys or clear all.</p>
          </div>
          <div className={styles.actionsRow}>
            <Button type="button" variant="outline" size="sm" disabled={rlLoading || busyKey !== null} onClick={() => void loadRateLimits()}><RefreshCw size={14} aria-hidden="true" />Refresh</Button>
            <Button type="button" variant="outline" size="sm" disabled={rlLoading || busyKey !== null || !rateLimits.length} onClick={() => void handleUnlock()}><LockOpen size={14} aria-hidden="true" />Clear all</Button>
          </div>
        </div>
        {rlError && <p role="alert" className="error">{rlError}</p>}
        {rlLoading ? <p role="status" className="muted">Loading rate-limit buckets...</p> : !rateLimits.length ? (
          <p className="muted">No active rate-limit or lockout buckets.</p>
        ) : (
          <div className="admin-table-wrap">
            <table className="admin-table">
              <thead><tr><th>Key</th><th>Hits</th><th>Remaining</th><th>Reset at</th><th>Action</th></tr></thead>
              <tbody>
                {rateLimits.map((entry) => (
                  <tr key={entry.id}>
                    <td><div className="admin-model-title"><span className="admin-mono">{entry.key}</span><Badge variant="outline">{entry.limiter}</Badge><Badge variant="secondary">{entry.source}</Badge></div></td>
                    <td className="admin-mono">{entry.max !== null ? `${entry.hits} / ${entry.max}` : entry.hits}</td>
                    <td className="admin-mono">{entry.remaining}</td>
                    <td className="admin-mono">{fmt(entry.resetAt)}</td>
                    <td><Button type="button" variant="outline" size="xs" disabled={busyKey !== null} onClick={() => void handleUnlock(entry)}>Unlock</Button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <section className="panel stack" aria-label="User session revocation">
        <div className={styles.sectionHead}>
          <div>
            <h2 className="admin-sim-heading"><Users size={18} aria-hidden="true" />User session inspection</h2>
            <p className="muted">Inspect active sessions for any user and force-revoke sessions without disabling their account.</p>
          </div>
          <Button type="button" variant="destructive" size="sm" disabled={!selectedUid || busyKey !== null || !userSessions.length} onClick={() => void handleRevokeSessions()}>Revoke all sessions</Button>
        </div>
        <form className={styles.userPickerRow} onSubmit={(e) => { e.preventDefault(); void loadAccounts(userSearch) }}>
          <label className="field">Account
            <select value={selectedUid} disabled={busyKey !== null} onChange={(e) => setSelectedUid(e.target.value)}>
              {!accounts.length && <option value="">No accounts loaded</option>}
              {accounts.map((m) => <option key={m.user.id} value={m.user.id}>{m.user.email} ({m.user.role})</option>)}
            </select>
          </label>
          <label className="field">Filter accounts<Input value={userSearch} placeholder="Email filter" onChange={(e) => setUserSearch(e.target.value)} /></label>
          <Button type="submit" variant="outline" size="sm" disabled={busyKey !== null}>Search</Button>
        </form>
        {selectedMember && <p className="muted">Inspecting {selectedMember.user.email} ({selectedMember.user.disabled ? "disabled" : "active account"}). Revoking sessions signs devices out without disabling login.</p>}
        {sessionError && <p role="alert" className="error">{sessionError}</p>}
        {sessionsLoading ? <p role="status" className="muted">Loading user sessions...</p> : !userSessions.length ? (
          <p className="muted">No active sessions for the selected account.</p>
        ) : (
          <div className="admin-table-wrap">
            <table className="admin-table">
              <thead><tr><th>Device</th><th>Created</th><th>Last seen</th><th>Expires</th><th>Action</th></tr></thead>
              <tbody>
                {userSessions.map((s) => (
                  <tr key={s.id}>
                    <td>{s.deviceName || "Browser session"}</td><td className="admin-mono">{fmt(s.createdAt)}</td>
                    <td className="admin-mono">{fmt(s.lastSeenAt)}</td><td className="admin-mono">{fmt(s.expiresAt)}</td>
                    <td><Button type="button" variant="outline" size="xs" disabled={busyKey !== null} onClick={() => void handleRevokeSessions(s.id)}>Revoke</Button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <section className="panel stack" aria-label="Model and budget webhook alerts">
        <div className={styles.sectionHead}>
          <div>
            <h2 className="admin-sim-heading"><BellRing size={18} aria-hidden="true" />Model and budget alert rules</h2>
            <p className="muted">Configure signed HTTPS webhook alerts for model errors, uptime drops, failed probes, and budget thresholds.</p>
          </div>
          <div className={styles.actionsRow}>
            <Button type="button" variant="outline" size="sm" disabled={alertsLoading || busyKey !== null} onClick={() => void handleEvaluateAll()}><Play size={14} aria-hidden="true" />Evaluate now</Button>
            <Button type="button" size="sm" disabled={busyKey !== null} onClick={() => openRuleForm(null)}><Plus size={14} aria-hidden="true" />New alert rule</Button>
          </div>
        </div>
        {alertsError && <p role="alert" className="error">{alertsError}</p>}
        {formOpen && (
          <form className="panel inset stack" onSubmit={(e) => void handleSaveRule(e)}>
            <h3>{editingRule ? `Edit alert rule: ${editingRule.name}` : "Create webhook alert rule"}</h3>
            <div className={styles.alertFormGrid}>
              <label className="field">Rule name<Input required maxLength={100} value={name} placeholder="High error streak" onChange={(e) => setName(e.target.value)} /></label>
              <label className="field">Trigger type<select value={triggerType} onChange={(e) => setTriggerType(e.target.value as AlertTriggerType)}>{ALERT_TRIGGER_TYPES.map((t) => <option key={t} value={t}>{ALERT_TRIGGER_LABELS[t]}</option>)}</select></label>
              <label className="field">Threshold value<Input type="number" step="any" min={0} required value={thresholdRaw} onChange={(e) => setThresholdRaw(e.target.value)} /></label>
              <label className="field">Capability filter<select value={capabilityFilter} onChange={(e) => setCapabilityFilter(e.target.value)}><option value="">All capabilities</option>{CAPABILITIES.map((c) => <option key={c} value={c}>{CAPABILITY_LABELS[c]}</option>)}</select></label>
              <label className="field">Webhook URL (HTTPS)<Input type="url" required value={webhookUrl} placeholder="https://hooks.example.com/alerts" onChange={(e) => setWebhookUrl(e.target.value)} /></label>
              <label className="field">Cooldown (minutes)<Input type="number" min={0} max={1440} step={1} required value={cooldownRaw} onChange={(e) => setCooldownRaw(e.target.value)} /></label>
            </div>
            <div className="dual">
              <label className="field">Signing secret (optional HMAC-SHA256)<Input type="password" value={signingSecret} placeholder={editingRule?.has_secret ? "Leave blank to keep existing" : "Optional signing secret"} onChange={(e) => setSigningSecret(e.target.value)} /></label>
              <div className="stack">
                <label className="check"><input type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} />Rule enabled</label>
                {editingRule?.has_secret && <label className="check"><input type="checkbox" checked={clearSecret} onChange={(e) => setClearSecret(e.target.checked)} />Clear stored signing secret</label>}
              </div>
            </div>
            <div className={styles.actionsRow}>
              <Button type="submit" size="sm" disabled={busyKey !== null}>{editingRule ? "Save rule" : "Create rule"}</Button>
              <Button type="button" variant="ghost" size="sm" disabled={busyKey !== null} onClick={() => { setFormOpen(false); setEditingRule(null) }}>Cancel</Button>
            </div>
          </form>
        )}
        {alertsLoading ? <p role="status" className="muted">Loading alert rules...</p> : !rules.length ? (
          <p className="muted">No webhook alert rules configured yet.</p>
        ) : (
          <div className={styles.ruleCardList}>
            {rules.map((rule) => (
              <article key={rule.id} className={`panel inset ${styles.ruleCard}`}>
                <div className={styles.sectionHead}>
                  <div className="admin-model-title">
                    <strong>{rule.name}</strong>
                    <Badge variant={rule.enabled ? "success" : "secondary"}>{rule.enabled ? "Enabled" : "Disabled"}</Badge>
                    <Badge variant="outline">{ALERT_TRIGGER_LABELS[rule.trigger_type] ?? rule.trigger_type}: {rule.threshold_value}</Badge>
                    {rule.capability_filter && <Badge variant="secondary">{CAPABILITY_LABELS[rule.capability_filter as ModelCapability] ?? rule.capability_filter}</Badge>}
                    {rule.secret_hint && <Badge variant="outline">Signed ({rule.secret_hint})</Badge>}
                  </div>
                  <div className={styles.actionsRow}>
                    <Button type="button" variant="outline" size="xs" disabled={busyKey !== null} onClick={() => void handleTestRule(rule)}>Test webhook</Button>
                    <Button type="button" variant="outline" size="xs" disabled={busyKey !== null} onClick={() => void handleToggleRule(rule)}>{rule.enabled ? "Disable" : "Enable"}</Button>
                    <Button type="button" variant="outline" size="xs" disabled={busyKey !== null} onClick={() => openRuleForm(rule)}>Edit</Button>
                    <Button type="button" variant="destructive" size="xs" aria-label={`Delete ${rule.name}`} disabled={busyKey !== null} onClick={() => void handleDeleteRule(rule)}><Trash2 size={13} aria-hidden="true" /></Button>
                  </div>
                </div>
                <div className={styles.ruleUrl}>{rule.webhook_url}</div>
                <div className={styles.ruleMeta}><span>Cooldown: {rule.cooldown_minutes} min</span><span>Last triggered: {fmt(rule.last_triggered_at)}</span></div>
              </article>
            ))}
          </div>
        )}
        <AlertDeliveryHistoryPanel rules={rules} refreshTick={refreshTick} onAuthInvalid={onAuthInvalid} />
      </section>

      <CspReportsPanel onAuthInvalid={onAuthInvalid} />
    </div>
  )
}
