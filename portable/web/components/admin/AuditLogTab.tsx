"use client"

import { useCallback, useEffect, useState } from "react"
import { RefreshCw } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { AdminApiError, listAdminAudit, type AuditEntry } from "@/lib/adminModels"

type Category = "all" | "models" | "accounts"

export function AuditLogTab({ onAuthInvalid }: { onAuthInvalid: (msg: string) => void }) {
  const [entries, setEntries] = useState<AuditEntry[]>([])
  const [category, setCategory] = useState<Category>("all")
  const [filterText, setFilterText] = useState("")
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState("")

  const load = useCallback(async () => {
    setLoading(true)
    setError("")
    try {
      const res = await listAdminAudit()
      setEntries(res.entries)
    } catch (err) {
      if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) {
        onAuthInvalid(err.message)
        return
      }
      setError(err instanceof Error ? err.message : "Could not load audit log.")
    } finally {
      setLoading(false)
    }
  }, [onAuthInvalid])

  useEffect(() => {
    void load()
  }, [load])

  const term = filterText.trim().toLowerCase()
  const filtered = entries.filter((entry) => {
    if (category === "models" && !entry.action.startsWith("admin.model.")) return false
    if (category === "accounts" && entry.action.startsWith("admin.model.")) return false
    if (term) {
      const hay = `${entry.action} ${entry.actorUserId ?? ""} ${entry.targetUserId ?? ""} ${JSON.stringify(entry.details ?? {})}`.toLowerCase()
      if (!hay.includes(term)) return false
    }
    return true
  })

  return (
    <section className="panel stack" aria-label="Audit log">
      <div className="spread">
        <div>
          <h2>Audit log</h2>
          <p className="muted">
            Showing the 20 most recent access-service audit events. In embedded mode, model and account events appear together.
          </p>
        </div>
        <Button type="button" variant="outline" size="sm" disabled={loading} onClick={() => void load()}>
          <RefreshCw size={14} />
          Refresh
        </Button>
      </div>

      <div className="dual">
        <label className="field">
          Category
          <select value={category} onChange={(e) => setCategory(e.target.value as Category)}>
            <option value="all">All events</option>
            <option value="models">Models</option>
            <option value="accounts">Accounts & Auth</option>
          </select>
        </label>
        <label className="field">
          Filter events
          <Input
            type="search"
            value={filterText}
            placeholder="Action, actor ID, target ID, or details"
            onChange={(e) => setFilterText(e.target.value)}
          />
        </label>
      </div>

      {error && (
        <p role="alert" className="error">
          {error}
        </p>
      )}

      {loading ? (
        <p role="status" className="muted">
          Loading audit events…
        </p>
      ) : !filtered.length ? (
        <p className="muted">No audit events match the selected filter.</p>
      ) : (
        <div className="admin-table-wrap">
          <table className="admin-table">
            <thead>
              <tr>
                <th>Timestamp</th>
                <th>Action</th>
                <th>Actor</th>
                <th>Target</th>
                <th>Details</th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((entry) => (
                <tr key={entry.id}>
                  <td className="admin-mono">{new Date(entry.at).toLocaleString()}</td>
                  <td>
                    <Badge variant={entry.action.startsWith("admin.model.") ? "default" : "secondary"}>
                      {entry.action}
                    </Badge>
                  </td>
                  <td className="admin-mono" title={entry.actorUserId ?? ""}>
                    {entry.actorUserId ? entry.actorUserId.slice(0, 8) : "system"}
                  </td>
                  <td className="admin-mono" title={entry.targetUserId ?? ""}>
                    {entry.targetUserId ? entry.targetUserId.slice(0, 8) : "—"}
                  </td>
                  <td className="admin-mono">
                    {entry.details ? JSON.stringify(entry.details) : "—"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}
