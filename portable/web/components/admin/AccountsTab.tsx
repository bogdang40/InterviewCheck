"use client"

import { useCallback, useEffect, useState, type FormEvent } from "react"
import { Search, UserCog } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { PasswordChangeForm } from "@/components/PasswordChangeForm"
import {
  AdminApiError,
  listAdminUsers,
  updateAdminUser,
  type AdminMember,
} from "@/lib/adminModels"

export function AccountsTab({ onAuthInvalid }: { onAuthInvalid: (msg: string) => void }) {
  const [query, setQuery] = useState("")
  const [users, setUsers] = useState<AdminMember[]>([])
  const [nextCursor, setNextCursor] = useState<string | null>(null)
  const [selected, setSelected] = useState<AdminMember | null>(null)
  const [role, setRole] = useState<"user" | "admin">("user")
  const [disabled, setDisabled] = useState(false)
  const [grant, setGrant] = useState("")
  const [confirm, setConfirm] = useState(false)
  const [busy, setBusy] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState("")
  const [status, setStatus] = useState("")

  const load = useCallback(
    async (searchTerm: string, cursor?: string) => {
      setError("")
      try {
        const res = await listAdminUsers(searchTerm || undefined, cursor)
        setUsers((prev) => (cursor ? [...prev, ...res.users] : res.users))
        setNextCursor(res.nextCursor)
      } catch (err) {
        if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) {
          onAuthInvalid(err.message)
          return
        }
        setError(err instanceof Error ? err.message : "Could not load accounts.")
      } finally {
        setLoading(false)
      }
    },
    [onAuthInvalid],
  )

  useEffect(() => {
    void load("")
  }, [load])

  function choose(member: AdminMember) {
    setSelected(member)
    setRole(member.user.role)
    setDisabled(member.user.disabled)
    setGrant(member.user.complimentaryUntil?.slice(0, 10) || "")
    setConfirm(false)
    setError("")
    setStatus("")
  }

  async function applyChanges(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    if (!selected || !confirm || busy) return
    const patch: { role?: "user" | "admin"; disabled?: boolean; complimentaryUntil?: string | null } = {}
    if (role !== selected.user.role) patch.role = role
    if (disabled !== selected.user.disabled) patch.disabled = disabled
    if (grant !== (selected.user.complimentaryUntil?.slice(0, 10) || "")) {
      patch.complimentaryUntil = grant ? `${grant}T23:59:59.999Z` : null
    }
    if (!Object.keys(patch).length) {
      setStatus("No account changes to apply.")
      return
    }
    setBusy(true)
    setError("")
    setStatus("")
    try {
      const updated = await updateAdminUser(selected.user.id, patch)
      setUsers((prev) => prev.map((m) => (m.user.id === updated.user.id ? updated : m)))
      choose(updated)
      setStatus(`Updated account ${updated.user.email}.`)
    } catch (err) {
      if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) {
        onAuthInvalid(err.message)
        return
      }
      setError(err instanceof Error ? err.message : "Could not update account.")
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="stack">
      <section className="panel stack" aria-label="Account directory">
        <div className="spread">
          <div>
            <h2>Account directory</h2>
            <p className="muted">Manage administrator roles, account status, and complimentary access.</p>
          </div>
        </div>
        <form
          className="row"
          onSubmit={(e) => {
            e.preventDefault()
            setLoading(true)
            setSelected(null)
            void load(query)
          }}
        >
          <label className="field">
            Search accounts
            <Input
              type="search"
              value={query}
              placeholder="Email address"
              onChange={(e) => setQuery(e.target.value)}
            />
          </label>
          <Button type="submit" variant="outline" disabled={loading || busy}>
            <Search size={14} />
            Search
          </Button>
        </form>

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

        {loading ? (
          <p role="status" className="muted">
            Loading accounts…
          </p>
        ) : !users.length ? (
          <p className="muted">No matching accounts found.</p>
        ) : (
          <div className="admin-table-wrap">
            <table className="admin-table">
              <thead>
                <tr>
                  <th>Email</th>
                  <th>Role</th>
                  <th>Status</th>
                  <th>Source</th>
                  <th>Last sign-in</th>
                  <th>Action</th>
                </tr>
              </thead>
              <tbody>
                {users.map((m) => (
                  <tr key={m.user.id}>
                    <td>{m.user.email}</td>
                    <td>
                      <Badge variant={m.user.role === "admin" ? "default" : "secondary"}>
                        {m.user.role}
                      </Badge>
                    </td>
                    <td>
                      {m.user.disabled ? (
                        <Badge variant="destructive">Disabled</Badge>
                      ) : m.entitlement.active ? (
                        <Badge variant="success">Active</Badge>
                      ) : (
                        <Badge variant="outline">Inactive</Badge>
                      )}
                    </td>
                    <td>{m.entitlement.source}</td>
                    <td className="admin-mono">
                      {m.lastLoginAt ? new Date(m.lastLoginAt).toLocaleString() : "Never"}
                    </td>
                    <td>
                      <Button type="button" variant="outline" size="sm" onClick={() => choose(m)}>
                        <UserCog size={14} />
                        Manage
                      </Button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {nextCursor && (
          <div>
            <Button
              type="button"
              variant="outline"
              size="sm"
              disabled={busy}
              onClick={() => void load(query, nextCursor)}
            >
              Load more
            </Button>
          </div>
        )}

        {selected && (
          <form className="panel inset stack" onSubmit={applyChanges}>
            <h3>Edit {selected.user.email}</h3>
            <div className="dual">
              <label className="field">
                Role
                <select
                  value={role}
                  disabled={busy}
                  onChange={(e) => {
                    setConfirm(false)
                    setRole(e.target.value as "user" | "admin")
                  }}
                >
                  <option value="user">User</option>
                  <option value="admin">Administrator</option>
                </select>
              </label>
              <label className="field">
                Complimentary access through (UTC)
                <Input
                  type="date"
                  value={grant}
                  disabled={busy}
                  onChange={(e) => {
                    setConfirm(false)
                    setGrant(e.target.value)
                  }}
                />
              </label>
            </div>
            <label className="check">
              <input
                type="checkbox"
                checked={disabled}
                disabled={busy}
                onChange={(e) => {
                  setConfirm(false)
                  setDisabled(e.target.checked)
                }}
              />
              Disable account and revoke sessions
            </label>
            <label className="check">
              <input
                type="checkbox"
                checked={confirm}
                disabled={busy}
                onChange={(e) => setConfirm(e.target.checked)}
              />
              Confirm changes for {selected.user.email}
            </label>
            <div className="row">
              <Button type="submit" disabled={busy || !confirm}>
                {busy ? "Applying…" : "Apply account changes"}
              </Button>
              <Button type="button" variant="ghost" disabled={busy} onClick={() => setSelected(null)}>
                Close
              </Button>
            </div>
          </form>
        )}
      </section>

      <PasswordChangeForm />
    </div>
  )
}
