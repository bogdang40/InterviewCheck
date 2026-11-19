"use client"

import { useCallback, useEffect, useRef, useState, type FormEvent } from "react"
import { Check, Copy, RefreshCw, ShieldCheck, X } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import {
  disableTotp, getTotpStatus, isTotpUnsupported, regenerateBackupCodes, startTotpSetup, verifyTotpSetup,
  type TotpSetup, type TotpStatus,
} from "@/lib/totpApi"

const fmt = (iso: string | null | undefined) => {
  if (!iso) return "Not verified"
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString()
}

export function TotpSetupCard() {
  const [status, setStatus] = useState<TotpStatus | null>(null)
  const [setup, setSetup] = useState<TotpSetup | null>(null)
  const [verifyCode, setVerifyCode] = useState("")
  const [backupCodes, setBackupCodes] = useState<string[] | null>(null)
  const [mode, setMode] = useState<"idle" | "regen" | "disable">("idle")
  const [regenCode, setRegenCode] = useState("")
  const [disablePassword, setDisablePassword] = useState("")
  const [disableCode, setDisableCode] = useState("")
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState<string | null>(null)
  const [copiedKey, setCopiedKey] = useState<string | null>(null)
  const [error, setError] = useState("")
  const [notice, setNotice] = useState("")
  const abortRef = useRef<AbortController | null>(null)

  const loadStatus = useCallback(async () => {
    abortRef.current?.abort()
    const controller = new AbortController()
    abortRef.current = controller
    setLoading(true); setError("")
    try {
      const next = await getTotpStatus(controller.signal)
      if (controller.signal.aborted || abortRef.current !== controller) return
      setStatus(next)
    } catch (err) {
      if (controller.signal.aborted || ((err instanceof DOMException || err instanceof Error) && err.name === "AbortError")) return
      setError(err instanceof Error ? err.message : "Could not load two-factor status.")
    } finally {
      if (abortRef.current === controller) setLoading(false)
    }
  }, [])

  useEffect(() => {
    void loadStatus()
    return () => {
      abortRef.current?.abort()
      abortRef.current = null
    }
  }, [loadStatus])

  async function copyText(key: string, value: string) {
    try {
      await navigator.clipboard.writeText(value)
      setCopiedKey(key)
    } catch {
      setError("Clipboard access failed. Copy the text manually.")
    }
  }

  async function handleStartSetup() {
    setBusy("setup"); setError(""); setNotice("")
    try {
      const next = await startTotpSetup()
      setSetup(next); setVerifyCode(""); setCopiedKey(null)
    } catch (err) {
      if (isTotpUnsupported(err)) setStatus({ enabled: false, verifiedAt: null, remainingBackupCodes: 0, supported: false })
      else setError(err instanceof Error ? err.message : "Could not start two-factor setup.")
    } finally { setBusy(null) }
  }

  async function handleVerify(e: FormEvent<HTMLFormElement>) {
    e.preventDefault(); setError(""); setNotice("")
    const code = verifyCode.trim()
    if (!/^\d{6}$/.test(code)) { setError("Enter the 6-digit code from your authenticator app."); return }
    setBusy("verify")
    try {
      const res = await verifyTotpSetup(code)
      setSetup(null); setVerifyCode(""); setBackupCodes(res.backupCodes)
      setStatus({ enabled: true, verifiedAt: res.verifiedAt, remainingBackupCodes: res.backupCodes.length, supported: true })
      setNotice("Two-factor authentication is now enabled.")
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not verify two-factor code.")
    } finally { setBusy(null) }
  }

  async function handleRegenerate(e: FormEvent<HTMLFormElement>) {
    e.preventDefault(); setError(""); setNotice("")
    const code = regenCode.trim()
    if (!/^\d{6}$/.test(code)) { setError("Enter a valid 6-digit authenticator code."); return }
    setBusy("regen")
    try {
      const res = await regenerateBackupCodes(code)
      setBackupCodes(res.backupCodes); setRegenCode(""); setMode("idle")
      setStatus((prev) => (prev ? { ...prev, remainingBackupCodes: res.backupCodes.length } : prev))
      setNotice("Generated 8 new single-use backup codes.")
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not regenerate backup codes.")
    } finally { setBusy(null) }
  }

  async function handleDisable(e: FormEvent<HTMLFormElement>) {
    e.preventDefault(); setError(""); setNotice("")
    if (disablePassword.length < 10) { setError("Enter your current password (at least 10 characters)."); return }
    if (disableCode.trim().length < 6) { setError("Enter your 6-digit authenticator code or a backup code."); return }
    setBusy("disable")
    try {
      await disableTotp(disablePassword, disableCode.trim())
      setDisablePassword(""); setDisableCode(""); setBackupCodes(null); setMode("idle")
      setStatus({ enabled: false, verifiedAt: null, remainingBackupCodes: 0, supported: true })
      setNotice("Two-factor authentication has been disabled.")
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not disable two-factor authentication.")
    } finally { setBusy(null) }
  }

  const unsupported = status?.supported === false

  return (
    <section className="panel inset stack" aria-label="Two-factor authentication">
      <div className="spread">
        <div className="row">
          <ShieldCheck size={16} aria-hidden="true" />
          <h4>Two-factor authentication (TOTP)</h4>
          {!loading && status && (
            <Badge variant={unsupported ? "secondary" : status.enabled ? "success" : "secondary"}>
              {unsupported ? "Unavailable" : status.enabled ? "Enabled" : "Disabled"}
            </Badge>
          )}
        </div>
        <Button type="button" variant="outline" size="xs" disabled={loading || busy !== null} onClick={() => void loadStatus()}>
          <RefreshCw size={13} aria-hidden="true" />Refresh 2FA
        </Button>
      </div>

      {error && <p role="alert" className="error">{error}</p>}
      {notice && <p role="status" className="notice">{notice}</p>}

      {backupCodes && (
        <div role="status" className="notice stack">
          <div className="spread">
            <strong>Save these single-use backup codes now. They will not be shown again.</strong>
            <Button type="button" variant="ghost" size="xs" aria-label="Dismiss backup codes" onClick={() => setBackupCodes(null)}>
              <X size={14} aria-hidden="true" />Dismiss
            </Button>
          </div>
          <div className="grid grid-cols-2 gap-1.5 font-mono text-xs sm:grid-cols-4">
            {backupCodes.map((c) => <code key={c} className="select-all">{c}</code>)}
          </div>
          <div>
            <Button type="button" variant="outline" size="xs" onClick={() => void copyText("codes", backupCodes.join("\n"))}>
              {copiedKey === "codes" ? <Check size={13} aria-hidden="true" /> : <Copy size={13} aria-hidden="true" />}
              {copiedKey === "codes" ? "Copied codes" : "Copy all codes"}
            </Button>
          </div>
        </div>
      )}

      {loading ? (
        <p role="status" className="muted">Loading two-factor status...</p>
      ) : unsupported ? (
        <p className="muted">Two-factor authentication is not enabled on this server.</p>
      ) : setup ? (
        <form className="stack" onSubmit={(e) => void handleVerify(e)} noValidate>
          <p className="muted">Add this key in your authenticator app, then enter a 6-digit verification code to activate 2FA.</p>
          <div className="panel inset stack">
            <div className="spread">
              <span className="text-xs font-semibold">Manual secret ({setup.issuer})</span>
              <Button type="button" variant="outline" size="xs" onClick={() => void copyText("secret", setup.secret)}>
                {copiedKey === "secret" ? <Check size={13} aria-hidden="true" /> : <Copy size={13} aria-hidden="true" />}
                {copiedKey === "secret" ? "Copied" : "Copy secret"}
              </Button>
            </div>
            <code className="font-mono text-xs break-all select-all">{setup.secret}</code>
            <div className="spread">
              <span className="text-xs font-semibold">Authenticator URI</span>
              <Button type="button" variant="outline" size="xs" onClick={() => void copyText("uri", setup.otpauthUri)}>
                {copiedKey === "uri" ? <Check size={13} aria-hidden="true" /> : <Copy size={13} aria-hidden="true" />}
                {copiedKey === "uri" ? "Copied" : "Copy URI"}
              </Button>
            </div>
            <code className="font-mono text-xs break-all select-all">{setup.otpauthUri}</code>
          </div>
          <label className="field">
            Verification code (6 digits)
            <Input type="text" inputMode="numeric" autoComplete="one-time-code" maxLength={6} placeholder="123456" disabled={busy !== null} value={verifyCode} onChange={(e) => setVerifyCode(e.target.value)} />
          </label>
          <div className="row">
            <Button type="submit" size="sm" disabled={busy !== null}>{busy === "verify" ? "Verifying..." : "Verify and enable"}</Button>
            <Button type="button" variant="ghost" size="sm" disabled={busy !== null} onClick={() => setSetup(null)}>Cancel</Button>
          </div>
        </form>
      ) : status?.enabled ? (
        <div className="stack">
          <p className="muted">Verified: {fmt(status.verifiedAt)}. Remaining backup codes: {status.remainingBackupCodes}.</p>
          <div className="row">
            <Button type="button" variant="outline" size="sm" disabled={busy !== null} onClick={() => setMode(mode === "regen" ? "idle" : "regen")}>Regenerate backup codes</Button>
            <Button type="button" variant="destructive" size="sm" disabled={busy !== null} onClick={() => setMode(mode === "disable" ? "idle" : "disable")}>Disable 2FA</Button>
          </div>
          {mode === "regen" && (
            <form className="stack" onSubmit={(e) => void handleRegenerate(e)} noValidate>
              <label className="field">
                Authenticator code (6 digits)
                <Input type="text" inputMode="numeric" autoComplete="one-time-code" maxLength={6} placeholder="123456" disabled={busy !== null} value={regenCode} onChange={(e) => setRegenCode(e.target.value)} />
              </label>
              <div className="row">
                <Button type="submit" size="sm" disabled={busy !== null}>{busy === "regen" ? "Regenerating..." : "Confirm regenerate"}</Button>
                <Button type="button" variant="ghost" size="sm" disabled={busy !== null} onClick={() => setMode("idle")}>Cancel</Button>
              </div>
            </form>
          )}
          {mode === "disable" && (
            <form className="stack" onSubmit={(e) => void handleDisable(e)} noValidate>
              <div className="dual">
                <label className="field">
                  Current password
                  <Input type="password" autoComplete="current-password" minLength={10} disabled={busy !== null} value={disablePassword} onChange={(e) => setDisablePassword(e.target.value)} />
                </label>
                <label className="field">
                  Authenticator or backup code
                  <Input type="text" autoComplete="one-time-code" placeholder="123456 or XXXX-XXXX" disabled={busy !== null} value={disableCode} onChange={(e) => setDisableCode(e.target.value)} />
                </label>
              </div>
              <div className="row">
                <Button type="submit" variant="destructive" size="sm" disabled={busy !== null}>{busy === "disable" ? "Disabling..." : "Confirm disable 2FA"}</Button>
                <Button type="button" variant="ghost" size="sm" disabled={busy !== null} onClick={() => setMode("idle")}>Cancel</Button>
              </div>
            </form>
          )}
        </div>
      ) : (
        <div className="stack">
          <p className="muted">Protect your account with a 6-digit authenticator app code and single-use backup codes.</p>
          <div><Button type="button" size="sm" disabled={busy !== null} onClick={() => void handleStartSetup()}>{busy === "setup" ? "Starting..." : "Enable 2FA"}</Button></div>
        </div>
      )}
    </section>
  )
}
