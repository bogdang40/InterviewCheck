"use client"

import { useState, type FormEvent } from "react"
import { KeyRound } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { rotateOwnPassword } from "@/lib/adminModels"
import { notifyAccountChanged } from "@/lib/useAccountStatus"

export function PasswordChangeForm({
  onRotated,
}: {
  onRotated?: (account: { email: string; active: boolean; admin?: boolean }) => void
}) {
  const [currentPassword, setCurrentPassword] = useState("")
  const [newPassword, setNewPassword] = useState("")
  const [confirmPassword, setConfirmPassword] = useState("")
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const [status, setStatus] = useState("")

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
    try {
      const next = await rotateOwnPassword(currentPassword, newPassword)
      setCurrentPassword("")
      setNewPassword("")
      setConfirmPassword("")
      setStatus("Password updated and session rotated.")
      notifyAccountChanged()
      onRotated?.(next)
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not update password.")
    } finally {
      setBusy(false)
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
