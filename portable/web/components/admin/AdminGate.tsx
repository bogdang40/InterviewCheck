"use client"

import Link from "next/link"
import { useState, type FormEvent } from "react"
import { ShieldAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { submit, type ProviderStatus } from "@/lib/integrations"
import { submitAccessAuth } from "@/lib/totpApi"
import { notifyAccountChanged, type AccountSnapshot } from "@/lib/useAccountStatus"

export function AdminGate({
  loading,
  status,
  account,
  error,
  onSignedIn,
  onSignedOut,
  onError,
}: {
  loading: boolean
  status: ProviderStatus | null
  account: AccountSnapshot | null
  error: string
  onSignedIn: (account: AccountSnapshot) => void
  onSignedOut: () => void
  onError: (msg: string) => void
}) {
  const [email, setEmail] = useState("")
  const [password, setPassword] = useState("")
  const [totpCode, setTotpCode] = useState("")
  const [totpRequired, setTotpRequired] = useState(false)
  const [busy, setBusy] = useState(false)

  async function handleSignIn(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    if (busy) return
    const trimmedTotp = totpCode.trim()
    if (totpRequired && !trimmedTotp) {
      onError("Enter your 6-digit authenticator code or backup code.")
      return
    }
    setBusy(true)
    onError("")
    try {
      const res = await submitAccessAuth<AccountSnapshot>("login", {
        email,
        password,
        ...(totpRequired && trimmedTotp ? { totpCode: trimmedTotp } : {}),
      })
      if (!res.ok) {
        setTotpRequired(true)
        setTotpCode("")
        return
      }
      setPassword("")
      setTotpCode("")
      setTotpRequired(false)
      notifyAccountChanged()
      onSignedIn(res.account)
    } catch (err) {
      onError(err instanceof Error ? err.message : "Sign in failed.")
    } finally {
      setBusy(false)
    }
  }

  async function handleSignOut() {
    setBusy(true)
    try {
      await submit("logout")
      setPassword("")
      setTotpCode("")
      setTotpRequired(false)
      notifyAccountChanged()
      onSignedOut()
    } finally {
      setBusy(false)
    }
  }

  if (loading) {
    return (
      <section className="panel stack" role="status">
        <h1>Model administration</h1>
        <p className="muted">Checking administrator access…</p>
      </section>
    )
  }

  if (!status?.access) {
    return (
      <section className="panel stack admin-gate-card">
        <span className="eyebrow">ADMINISTRATION</span>
        <h1>Model administration</h1>
        <h2>Account authentication inactive</h2>
        <p className="muted">
          Model administration requires an authenticated administrator session in embedded or remote account mode.
        </p>
        <div className="row">
          <Button asChild variant="outline">
            <Link href="/account/">Open Account settings</Link>
          </Button>
        </div>
      </section>
    )
  }

  if (!account) {
    return (
      <section className="panel stack admin-gate-card">
        <span className="eyebrow">ADMINISTRATION</span>
        <h1>Model administration</h1>
        <h2>Administrator sign in required</h2>
        <p className="muted">Sign in with an administrator account to manage connected models and users.</p>
        {error && (
          <p role="alert" className="error">
            {error}
          </p>
        )}
        <form className="stack" onSubmit={handleSignIn}>
          <label className="field">
            Operator email
            <Input
              type="email"
              autoComplete="username"
              required
              disabled={busy}
              value={email}
              onChange={(e) => {
                setEmail(e.target.value)
                if (totpRequired) {
                  setTotpRequired(false)
                  setTotpCode("")
                }
              }}
            />
          </label>
          <label className="field">
            Password
            <Input
              type="password"
              autoComplete="current-password"
              required
              minLength={10}
              disabled={busy}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
            />
          </label>
          {totpRequired && (
            <div className="panel inset stack">
              <p role="status" className="notice">
                Two-factor authentication is required. Enter a 6-digit authenticator code or a single-use backup code.
              </p>
              <label className="field">
                Authenticator or backup code
                <Input
                  type="text"
                  autoComplete="one-time-code"
                  required
                  disabled={busy}
                  placeholder="123456 or XXXX-XXXX"
                  value={totpCode}
                  onChange={(e) => setTotpCode(e.target.value)}
                />
              </label>
            </div>
          )}
          <div className="row">
            <Button type="submit" disabled={busy}>
              {busy ? "Signing in\u2026" : totpRequired ? "Verify and sign in" : "Sign in"}
            </Button>
            <Button asChild variant="outline">
              <Link href="/account/">Open Account settings</Link>
            </Button>
          </div>
        </form>
      </section>
    )
  }

  return (
    <section className="panel stack admin-gate-card">
      <span className="eyebrow">ADMINISTRATION</span>
      <h1>Model administration</h1>
      <h2>
        <ShieldAlert size={18} aria-hidden="true" /> Administrator access required
      </h2>
      <p className="muted">
        Signed in as <strong>{account.email}</strong>. An administrator role is required to open this console.
      </p>
      <div className="row">
        <Button type="button" variant="outline" disabled={busy} onClick={() => void handleSignOut()}>
          Sign out
        </Button>
        <Button asChild variant="ghost">
          <Link href="/account/">Return to Account</Link>
        </Button>
      </div>
    </section>
  )
}
