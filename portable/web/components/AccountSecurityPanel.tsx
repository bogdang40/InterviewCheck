"use client"

import dynamic from "next/dynamic"
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react"
import { Check, Copy, KeyRound, Laptop, RefreshCw, X } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import {
  API_TOKEN_SCOPES, SCOPE_LABELS, createApiToken, listAccountSessions, listApiTokens,
  revokeAccountSession, revokeApiToken,
  type AccountSession, type ApiTokenScope, type ApiTokenSummary,
} from "@/lib/accountSecurity"

const TotpSetupCard = dynamic(() => import("./TotpSetupCard").then((m) => m.TotpSetupCard), { ssr: false })

const fmt = (iso: string | null | undefined) => {
  if (!iso) return "Never"
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString()
}

export function AccountSecurityPanel({
  isAdmin,
  onCurrentSessionRevoked,
}: {
  isAdmin: boolean
  onCurrentSessionRevoked?: () => void
}) {
  const [sessions, setSessions] = useState<AccountSession[]>([])
  const [tokens, setTokens] = useState<ApiTokenSummary[]>([])
  const [loading, setLoading] = useState(true)
  const [busyKey, setBusyKey] = useState<string | null>(null)
  const [error, setError] = useState("")
  const [status, setStatus] = useState("")
  const [tokenName, setTokenName] = useState("")
  const [scopes, setScopes] = useState<ApiTokenScope[]>(["read:interviews"])
  const [ttlDaysRaw, setTtlDaysRaw] = useState("")
  const [revealedToken, setRevealedToken] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)
  const abortRef = useRef<AbortController | null>(null)

  const visibleScopes = API_TOKEN_SCOPES.filter((s) => s !== "admin:models" || isAdmin)

  const refresh = useCallback(async () => {
    abortRef.current?.abort()
    const controller = new AbortController()
    abortRef.current = controller
    setLoading(true); setError("")
    try {
      const [sessionList, tokenList] = await Promise.all([
        listAccountSessions(controller.signal),
        listApiTokens(controller.signal),
      ])
      if (controller.signal.aborted || abortRef.current !== controller) return
      setSessions(sessionList); setTokens(tokenList)
    } catch (err) {
      if (controller.signal.aborted || ((err instanceof DOMException || err instanceof Error) && err.name === "AbortError")) return
      setError(err instanceof Error ? err.message : "Could not load account security settings.")
    } finally {
      if (abortRef.current === controller) setLoading(false)
    }
  }, [])

  useEffect(() => {
    void refresh()
    return () => {
      abortRef.current?.abort()
      abortRef.current = null
    }
  }, [refresh])
  useEffect(() => {
    if (!isAdmin) setScopes((prev) => prev.filter((s) => s !== "admin:models"))
  }, [isAdmin])

  async function handleRevokeSession(s: AccountSession) {
    setBusyKey(`session:${s.id}`); setError(""); setStatus("")
    try {
      await revokeAccountSession(s.id)
      if (s.isCurrent) { onCurrentSessionRevoked?.(); return }
      setSessions((prev) => prev.filter((item) => item.id !== s.id))
      setStatus(`Revoked session (${s.deviceName || "Browser session"}).`)
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not revoke session.")
    } finally { setBusyKey(null) }
  }

  async function handleCreateToken(e: FormEvent<HTMLFormElement>) {
    e.preventDefault(); setError(""); setStatus("")
    const cleanName = tokenName.trim()
    if (!cleanName) { setError("Token name is required."); return }
    const cleanScopes = scopes.filter((s) => s !== "admin:models" || isAdmin)
    if (!cleanScopes.length) { setError("Select at least one token scope."); return }
    let ttlDays: number | null = null
    const rawTtl = ttlDaysRaw.trim()
    if (rawTtl) {
      const parsed = /^\d+$/.test(rawTtl) ? Number.parseInt(rawTtl, 10) : 0
      if (parsed < 1 || parsed > 365) { setError("Expiration days must be a whole number between 1 and 365."); return }
      ttlDays = parsed
    }
    setBusyKey("create-token")
    try {
      const created = await createApiToken({ name: cleanName, scopes: cleanScopes, ttlDays })
      setRevealedToken(created.token); setCopied(false); setTokenName(""); setTtlDaysRaw("")
      setTokens((prev) => [created.apiToken, ...prev])
      setStatus(`Created API token ${created.apiToken.name}.`)
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not create API token.")
    } finally { setBusyKey(null) }
  }

  async function handleRevokeToken(t: ApiTokenSummary) {
    setBusyKey(`token:${t.id}`); setError(""); setStatus("")
    try {
      await revokeApiToken(t.id)
      setTokens((prev) => prev.map((item) => (item.id === t.id ? { ...item, revokedAt: new Date().toISOString() } : item)))
      setStatus(`Revoked API token ${t.name}.`)
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not revoke API token.")
    } finally { setBusyKey(null) }
  }

  async function copyRevealedToken() {
    if (!revealedToken) return
    try { await navigator.clipboard.writeText(revealedToken); setCopied(true) }
    catch { setError("Clipboard access failed. Copy the token text manually.") }
  }

  return (
    <div className="stack">
      <div className="spread">
        <div><h3>Account security</h3><p className="muted">Review active device sessions and manage scoped API tokens.</p></div>
        <Button type="button" variant="outline" size="sm" disabled={loading || busyKey !== null} onClick={() => void refresh()}>
          <RefreshCw size={14} aria-hidden="true" />Refresh security
        </Button>
      </div>
      {error && <p role="alert" className="error">{error}</p>}
      {status && <p role="status" className="notice">{status}</p>}

      <TotpSetupCard />

      <section className="panel inset stack" aria-label="Active device sessions">
        <h4 className="row"><Laptop size={16} aria-hidden="true" /><span>Active device sessions</span></h4>
        {loading ? <p role="status" className="muted">Loading active sessions...</p> : !sessions.length ? (
          <p className="muted">No active sessions recorded.</p>
        ) : (
          <div className="w-full min-w-0 overflow-x-auto">
            <table className="w-full border-collapse text-left text-sm">
              <thead>
                <tr className="border-b border-[var(--line)] text-xs text-[var(--secondary-ink)]">
                  <th className="py-2 pr-3 font-semibold">Device</th><th className="py-2 pr-3 font-semibold">Created</th>
                  <th className="py-2 pr-3 font-semibold">Last seen</th><th className="py-2 pr-3 font-semibold">Expires</th>
                  <th className="py-2 font-semibold">Action</th>
                </tr>
              </thead>
              <tbody>
                {sessions.map((s) => (
                  <tr key={s.id} className="border-b border-[var(--line)] align-top">
                    <td className="py-2 pr-3">
                      <div className="flex flex-wrap items-center gap-1.5">
                        <span className="font-medium">{s.deviceName || "Browser session"}</span>
                        {s.isCurrent && <Badge variant="default">Current</Badge>}
                      </div>
                    </td>
                    <td className="py-2 pr-3 font-mono text-xs">{fmt(s.createdAt)}</td>
                    <td className="py-2 pr-3 font-mono text-xs">{fmt(s.lastSeenAt)}</td>
                    <td className="py-2 pr-3 font-mono text-xs">{fmt(s.expiresAt)}</td>
                    <td className="py-2">
                      <Button type="button" variant="outline" size="xs" disabled={busyKey !== null} onClick={() => void handleRevokeSession(s)}>
                        {busyKey === `session:${s.id}` ? "Revoking..." : "Revoke"}
                      </Button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <section className="panel inset stack" aria-label="Scoped API tokens">
        <h4 className="row"><KeyRound size={16} aria-hidden="true" /><span>Scoped API tokens</span></h4>
        {revealedToken && (
          <div role="status" className="notice stack">
            <div className="spread">
              <strong>Copy this API token now. It will not be shown again.</strong>
              <Button type="button" variant="ghost" size="xs" aria-label="Dismiss token banner" onClick={() => setRevealedToken(null)}>
                <X size={14} aria-hidden="true" />Dismiss
              </Button>
            </div>
            <div className="flex flex-wrap items-center gap-2">
              <code className="font-mono text-xs break-all select-all">{revealedToken}</code>
              <Button type="button" variant="outline" size="xs" onClick={() => void copyRevealedToken()}>
                {copied ? <Check size={14} aria-hidden="true" /> : <Copy size={14} aria-hidden="true" />}
                {copied ? "Copied" : "Copy token"}
              </Button>
            </div>
          </div>
        )}
        <form className="stack" onSubmit={(e) => void handleCreateToken(e)} noValidate>
          <div className="dual">
            <label className="field">Token name<Input maxLength={80} required disabled={busyKey !== null} value={tokenName} placeholder="CI report exporter" onChange={(e) => setTokenName(e.target.value)} /></label>
            <label className="field">TTL (days, 1 to 365)<Input type="number" min={1} max={365} step={1} disabled={busyKey !== null} value={ttlDaysRaw} placeholder="Optional (no expiration)" onChange={(e) => setTtlDaysRaw(e.target.value)} /></label>
          </div>
          <fieldset className="border border-[var(--color-input)] rounded-lg p-3 min-w-0">
            <legend className="text-xs font-semibold px-1.5 text-[var(--secondary-ink)]">Token scopes</legend>
            <div className="flex flex-wrap gap-x-4 gap-y-2">
              {visibleScopes.map((scope) => (
                <label key={scope} className="check">
                  <input type="checkbox" checked={scopes.includes(scope)} disabled={busyKey !== null} onChange={() => setScopes((p) => (p.includes(scope) ? p.filter((x) => x !== scope) : [...p, scope]))} />
                  <span>{SCOPE_LABELS[scope]}</span>
                </label>
              ))}
            </div>
          </fieldset>
          <div><Button type="submit" size="sm" disabled={busyKey !== null}>{busyKey === "create-token" ? "Generating..." : "Generate token"}</Button></div>
        </form>
        {loading ? <p role="status" className="muted">Loading API tokens...</p> : !tokens.length ? (
          <p className="muted">No API tokens created yet.</p>
        ) : (
          <div className="w-full min-w-0 overflow-x-auto">
            <table className="w-full border-collapse text-left text-sm">
              <thead>
                <tr className="border-b border-[var(--line)] text-xs text-[var(--secondary-ink)]">
                  <th className="py-2 pr-3 font-semibold">Name</th><th className="py-2 pr-3 font-semibold">Prefix</th>
                  <th className="py-2 pr-3 font-semibold">Scopes</th><th className="py-2 pr-3 font-semibold">Status</th>
                  <th className="py-2 pr-3 font-semibold">Expires</th><th className="py-2 font-semibold">Action</th>
                </tr>
              </thead>
              <tbody>
                {tokens.map((t) => {
                  const isRevoked = Boolean(t.revokedAt)
                  return (
                    <tr key={t.id} className="border-b border-[var(--line)] align-top">
                      <td className="py-2 pr-3 font-medium">{t.name}</td>
                      <td className="py-2 pr-3 font-mono text-xs">{t.tokenPrefix}...</td>
                      <td className="py-2 pr-3"><div className="flex flex-wrap gap-1">{t.scopes.map((sc) => <Badge key={sc} variant="outline">{sc}</Badge>)}</div></td>
                      <td className="py-2 pr-3"><Badge variant={isRevoked ? "secondary" : "success"}>{isRevoked ? "Revoked" : "Active"}</Badge></td>
                      <td className="py-2 pr-3 font-mono text-xs">{t.expiresAt ? fmt(t.expiresAt) : "Never"}</td>
                      <td className="py-2">
                        {!isRevoked && <Button type="button" variant="outline" size="xs" disabled={busyKey !== null} onClick={() => void handleRevokeToken(t)}>{busyKey === `token:${t.id}` ? "Revoking..." : "Revoke"}</Button>}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  )
}
