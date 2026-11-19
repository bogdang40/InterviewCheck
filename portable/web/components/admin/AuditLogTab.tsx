"use client"

import { useCallback, useEffect, useRef, useState } from "react"
import { Download, RefreshCw } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import {
  exportAdminAudit,
  listAdminAuditEntries,
  type AdminAuditFilters,
  type AuditCategory,
} from "@/lib/adminAudit"
import { AdminApiError, type AuditEntry } from "@/lib/adminModels"
import { AuditIntegrityBanner } from "./AuditIntegrityBanner"

const PAGE_SIZE_OPTIONS = [20, 50, 100, 200] as const

type FilterState = {
  category: AuditCategory
  q: string
  action: string
  actor: string
  since: string
  until: string
  limit: number
}

const DEFAULT_FILTERS: FilterState = {
  category: "all",
  q: "",
  action: "",
  actor: "",
  since: "",
  until: "",
  limit: 50,
}

export function AuditLogTab({ onAuthInvalid }: { onAuthInvalid: (msg: string) => void }) {
  const [entries, setEntries] = useState<AuditEntry[]>([])
  const [nextBeforeId, setNextBeforeId] = useState<number | null>(null)
  const [filters, setFilters] = useState<FilterState>(DEFAULT_FILTERS)
  const [loading, setLoading] = useState(true)
  const [loadingMore, setLoadingMore] = useState(false)
  const [exporting, setExporting] = useState<"csv" | "json" | null>(null)
  const [error, setError] = useState("")
  const [notice, setNotice] = useState("")
  const mountedRef = useRef(false)
  const requestSeqRef = useRef(0)
  const loadMoreAbortRef = useRef<AbortController | null>(null)

  const handleError = useCallback(
    (err: unknown, fallback: string) => {
      if (err instanceof DOMException && err.name === "AbortError") return
      if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) {
        onAuthInvalid(err.message)
        return
      }
      setError(err instanceof Error ? err.message : fallback)
    },
    [onAuthInvalid],
  )

  const fetchFirstPage = useCallback(
    async (query: AdminAuditFilters, signal?: AbortSignal) => {
      loadMoreAbortRef.current?.abort()
      loadMoreAbortRef.current = null
      setLoadingMore(false)
      if (query.since && query.until && query.since > query.until) {
        setLoading(false)
        setError("From date must be on or before To date.")
        return
      }
      const seq = ++requestSeqRef.current
      setLoading(true)
      setError("")
      try {
        const res = await listAdminAuditEntries(query, signal)
        if (seq !== requestSeqRef.current) return
        setEntries(res.entries)
        setNextBeforeId(res.nextBeforeId)
      } catch (err) {
        if (seq !== requestSeqRef.current) return
        handleError(err, "Could not load audit log.")
      } finally {
        if (seq === requestSeqRef.current) setLoading(false)
      }
    },
    [handleError],
  )

  useEffect(() => {
    loadMoreAbortRef.current?.abort()
    loadMoreAbortRef.current = null
    const controller = new AbortController()
    const hasText = Boolean(filters.q || filters.action || filters.actor)
    const delay = mountedRef.current && hasText ? 180 : 0
    mountedRef.current = true
    const timer = window.setTimeout(() => {
      void fetchFirstPage(filters, controller.signal)
    }, delay)
    return () => {
      window.clearTimeout(timer)
      controller.abort()
      loadMoreAbortRef.current?.abort()
      loadMoreAbortRef.current = null
    }
  }, [filters, fetchFirstPage])

  async function loadOlder() {
    if (loading || loadingMore || nextBeforeId === null) return
    const seq = requestSeqRef.current
    loadMoreAbortRef.current?.abort()
    const controller = new AbortController()
    loadMoreAbortRef.current = controller
    setLoadingMore(true)
    setError("")
    try {
      const res = await listAdminAuditEntries(
        { ...filters, before_id: nextBeforeId },
        controller.signal,
      )
      if (seq !== requestSeqRef.current || controller.signal.aborted) return
      setEntries((prev) => {
        const seen = new Set(prev.map((item) => item.id))
        return [...prev, ...res.entries.filter((item) => !seen.has(item.id))]
      })
      setNextBeforeId(res.nextBeforeId)
    } catch (err) {
      if (seq !== requestSeqRef.current || controller.signal.aborted) return
      handleError(err, "Could not load older audit events.")
    } finally {
      if (loadMoreAbortRef.current === controller) {
        loadMoreAbortRef.current = null
        setLoadingMore(false)
      }
    }
  }

  async function handleExport(format: "csv" | "json") {
    if (exporting) return
    if (filters.since && filters.until && filters.since > filters.until) {
      setError("From date must be on or before To date.")
      return
    }
    setExporting(format)
    setError("")
    setNotice("")
    try {
      const filename = await exportAdminAudit(format, { ...filters, limit: 200 })
      setNotice(
        nextBeforeId !== null
          ? `Exported ${filename} (capped at 200 events).`
          : `Exported ${filename}.`,
      )
    } catch (err) {
      handleError(err, `Could not export ${format.toUpperCase()} audit log.`)
    } finally {
      setExporting(null)
    }
  }

  const updateFilter = <K extends keyof FilterState>(key: K, value: FilterState[K]) =>
    setFilters((prev) => ({ ...prev, [key]: value }))

  const hasCustomFilters =
    filters.category !== "all" ||
    filters.q.trim() !== "" ||
    filters.action.trim() !== "" ||
    filters.actor.trim() !== "" ||
    filters.since !== "" ||
    filters.until !== "" ||
    filters.limit !== 50

  const term = filters.q.trim().toLowerCase()
  const actionTerm = filters.action.trim().toLowerCase()
  const actorTerm = filters.actor.trim().toLowerCase()
  const filtered = entries.filter((entry) => {
    if (filters.category === "models" && !entry.action.startsWith("admin.model.")) return false
    if (filters.category === "accounts" && entry.action.startsWith("admin.model.")) return false
    if (actionTerm && !entry.action.toLowerCase().includes(actionTerm)) return false
    if (actorTerm && !(entry.actorUserId ?? "").toLowerCase().includes(actorTerm)) return false
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
            Filter and export administrative audit events. In embedded mode, model and account events appear together.
          </p>
        </div>
        <div className="admin-header-actions">
          <Button type="button" variant="outline" size="sm" disabled={loading || exporting !== null} onClick={() => void handleExport("csv")}>
            <Download size={14} aria-hidden="true" />
            {exporting === "csv" ? "Exporting CSV…" : "Export CSV"}
          </Button>
          <Button type="button" variant="outline" size="sm" disabled={loading || exporting !== null} onClick={() => void handleExport("json")}>
            <Download size={14} aria-hidden="true" />
            {exporting === "json" ? "Exporting JSON…" : "Export JSON"}
          </Button>
          <Button type="button" variant="outline" size="sm" disabled={loading || exporting !== null} onClick={() => void fetchFirstPage(filters)}>
            <RefreshCw size={14} aria-hidden="true" />
            Refresh
          </Button>
        </div>
      </div>

      <AuditIntegrityBanner onAuthInvalid={onAuthInvalid} />

      <div className="dual">
        <label className="field">
          Category
          <select value={filters.category} onChange={(e) => updateFilter("category", e.target.value as AuditCategory)}>
            <option value="all">All events</option>
            <option value="models">Models</option>
            <option value="accounts">Accounts & Auth</option>
          </select>
        </label>
        <label className="field">
          Filter events
          <Input
            type="search"
            value={filters.q}
            placeholder="Action, actor ID, target ID, or details"
            onChange={(e) => updateFilter("q", e.target.value)}
          />
        </label>
      </div>

      <div className="admin-filters">
        <label className="field">
          Action
          <Input type="text" value={filters.action} placeholder="e.g. admin.model.create" onChange={(e) => updateFilter("action", e.target.value)} />
        </label>
        <label className="field">
          Actor ID
          <Input type="text" value={filters.actor} placeholder="Actor user ID" onChange={(e) => updateFilter("actor", e.target.value)} />
        </label>
        <label className="field">
          From date
          <Input type="date" value={filters.since} onChange={(e) => updateFilter("since", e.target.value)} />
        </label>
        <label className="field">
          To date
          <Input type="date" value={filters.until} onChange={(e) => updateFilter("until", e.target.value)} />
        </label>
      </div>

      <div className="spread">
        <label className="field">
          Page size
          <select value={String(filters.limit)} onChange={(e) => updateFilter("limit", Number(e.target.value))}>
            {PAGE_SIZE_OPTIONS.map((size) => (
              <option key={size} value={String(size)}>
                {size} events
              </option>
            ))}
          </select>
        </label>
        {hasCustomFilters && (
          <Button type="button" variant="ghost" size="sm" onClick={() => { setFilters(DEFAULT_FILTERS); setNotice("") }}>
            Clear filters
          </Button>
        )}
      </div>

      {error && (
        <p role="alert" className="error">
          {error}
        </p>
      )}
      {notice && (
        <p role="status" className="notice">
          {notice}
        </p>
      )}

      {loading && entries.length === 0 ? (
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
                    {entry.targetUserId ? entry.targetUserId.slice(0, 8) : "n/a"}
                  </td>
                  <td className="admin-mono">{entry.details ? JSON.stringify(entry.details) : "n/a"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div className="spread">
        <span className="muted">
          Showing {filtered.length} {filtered.length === 1 ? "event" : "events"}
          {loading ? " (updating…)" : ""}
        </span>
        {nextBeforeId !== null && (
          <Button type="button" variant="outline" size="sm" disabled={loading || loadingMore} onClick={() => void loadOlder()}>
            {loadingMore ? "Loading older…" : "Load older"}
          </Button>
        )}
      </div>
    </section>
  )
}
