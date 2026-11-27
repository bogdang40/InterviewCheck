"use client"

import { useEffect, useRef, useState, type FormEvent } from "react"
import { KeyRound } from "lucide-react"
import { setPasswordChangeUnconfirmed } from "./PasswordChangeNotice"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { AdminApiError, rotateOwnPassword } from "@/lib/adminModels"
import { cancelPreRotationStatusRead, notifyAccountChanged } from "@/lib/useAccountStatus"

export function PasswordChangeForm({
  onStart,
  onRotated,
  onUnconfirmed,
}: {
  onStart?: () => void
  onUnconfirmed?: (uncertain: boolean) => void
  onRotated?: (account: { email: string; active: boolean; admin?: boolean }) => void
}) {
  const [currentPassword, setCurrentPassword] = useState("")
  const [newPassword, setNewPassword] = useState("")
  const [confirmPassword, setConfirmPassword] = useState("")
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const [status, setStatus] = useState("")

  const mounted = useRef(true)
  useEffect(() => {
    mounted.current = true
    return () => { mounted.current = false }
  }, [])

  async function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    setError("")
    setStatus("")
    if (!currentPassword) {
      setError("Current password is required.")
      return
    }
    if (newPassword.length < 10) {
      setError("New password must be at least 10 characters.")
      return
    }
    if (newPassword !== confirmPassword) {
      setError("New password and confirmation do not match.")
      return
    }
    setBusy(true)
    onStart?.()
    cancelPreRotationStatusRead()
    try {
      const next = await rotateOwnPassword(currentPassword, newPassword)
      setPasswordChangeUnconfirmed(false)
      if (mounted.current) {
        setCurrentPassword("")
        setNewPassword("")
        setConfirmPassword("")
        setStatus("Password updated and session rotated.")
        onRotated?.(next)
      }
      notifyAccountChanged("rotation")
    } catch (err) {
      const uncertain = !(err instanceof AdminApiError) || err.status >= 500
      if (uncertain) setPasswordChangeUnconfirmed(true)
      if (mounted.current) {
        const detail = err instanceof Error ? err.message : "Could not update password."
        setError(uncertain ? `The change was not confirmed. Checking access. ${detail}` : detail)
        onUnconfirmed?.(uncertain)
      }
      notifyAccountChanged(uncertain ? "rotation" : "refresh")
    } finally {
      if (mounted.current) setBusy(false)
    }
  }

  return (
    <form className="panel stack" onSubmit={submit} aria-label="Change password" noValidate>
      <h3 className="row">
        <KeyRound size={16} aria-hidden="true" />
        <span>Change password</span>
      </h3>
      <p className="muted">
        Rotating your password revokes older sessions for your account and issues a fresh cookie.
      </p>
      <div className="dual">
        <label className="field">
          Current password
          <Input
            type="password"
            autoComplete="current-password"
            required
            disabled={busy}
            value={currentPassword}
            onChange={(e) => setCurrentPassword(e.target.value)}
          />
        </label>
        <label className="field">
          New password
          <Input
            type="password"
            autoComplete="new-password"
            required
            minLength={10}
            disabled={busy}
            value={newPassword}
            onChange={(e) => setNewPassword(e.target.value)}
          />
        </label>
      </div>
      <label className="field">
        Confirm new password
        <Input
          type="password"
          autoComplete="new-password"
          required
          minLength={10}
          disabled={busy}
          value={confirmPassword}
          onChange={(e) => setConfirmPassword(e.target.value)}
        />
      </label>
      {error && (
        <p role="alert" className="error">
          {error}
        </p>
      )}
      {status && (
        <p role="status" className="notice">
          {status}
        </p>
      )}
      <div>
        <Button type="submit" variant="outline" disabled={busy}>
          {busy ? "Updating password…" : "Update password"}
        </Button>
      </div>
    </form>
  )
}
