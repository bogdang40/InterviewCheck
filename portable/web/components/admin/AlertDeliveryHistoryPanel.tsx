"use client"

import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { Download, RefreshCw, RotateCw } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  exportAlertDeliveries, listAlertDeliveries, retryAlertDelivery,
  type AlertDeliveryItem, type AlertDeliveryStatusFilter, type AlertDeliverySummary,
} from "@/lib/adminAlertHistory"
import { AdminApiError } from "@/lib/adminModels"
import { type AlertRule } from "@/lib/adminSecurityAlerts"
import styles from "./SecurityAlertsTab.module.css"

type Props = {
  rules: AlertRule[]
  refreshTick: number
  onAuthInvalid: (msg: string) => void
}

const EMPTY_SUMMARY: AlertDeliverySummary = {
  total: 0, ok_count: 0, failed_count: 0, success_rate_pct: 0, failing_rules: 0,
}
const fmt = (iso: string | null | undefined) =>
  !iso ? "Never" : Number.isNaN(new Date(iso).getTime()) ? iso : new Date(iso).toLocaleString()

export function AlertDeliveryHistoryPanel({ rules, refreshTick, onAuthInvalid }: Props) {
  const [ruleId, setRuleId] = useState("")
  const [status, setStatus] = useState<AlertDeliveryStatusFilter>("")
  const [summary, setSummary] = useState<AlertDeliverySummary>(EMPTY_SUMMARY)
  const [items, setItems] = useState<AlertDeliveryItem[]>([])
  const [nextBeforeId, setNextBeforeId] = useState<number | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadingMore, setLoadingMore] = useState(false)
  const [retryingId, setRetryingId] = useState<number | null>(null)
  const [exporting, setExporting] = useState<"csv" | "json" | null>(null)
  const [error, setError] = useState("")
  const [notice, setNotice] = useState("")
  const seqRef = useRef(0)
  const moreAbortRef = useRef<AbortController | null>(null)

  const ruleNameById = useMemo(() => new Map(rules.map((r) => [r.id, r.name])), [rules])

  useEffect(() => {
    if (ruleId && rules.length > 0 && !rules.some((r) => r.id === ruleId)) setRuleId("")
  }, [ruleId, rules])

  const handleErr = useCallback((err: unknown, fallback: string) => {
    if (err instanceof DOMException && err.name === "AbortError") return
    if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) {
      onAuthInvalid(err.message)
      return
    }
    setError(err instanceof Error ? err.message : fallback)
  }, [onAuthInvalid])

  const loadFirstPage = useCallback(async (
    nextRuleId: string,
    nextStatus: AlertDeliveryStatusFilter,
    signal?: AbortSignal,
    preserveError = false,
  ) => {
    moreAbortRef.current?.abort()
    moreAbortRef.current = null
    setLoadingMore(false)
    const seq = ++seqRef.current
    setLoading(true)
    if (!preserveError) setError("")
    try {
      const page = await listAlertDeliveries({ rule_id: nextRuleId, status: nextStatus, limit: 50 }, signal)
      if (seq !== seqRef.current) return
      setSummary(page.summary); setItems(page.items); setNextBeforeId(page.next_before_id)
    } catch (err) {
      if (seq !== seqRef.current) return
      handleErr(err, "Could not load alert delivery history.")
    } finally {
      if (seq === seqRef.current) setLoading(false)
    }
  }, [handleErr])

  useEffect(() => {
    const controller = new AbortController()
    void loadFirstPage(ruleId, status, controller.signal)
    return () => { controller.abort(); moreAbortRef.current?.abort(); moreAbortRef.current = null }
  }, [ruleId, status, refreshTick, loadFirstPage])

  async function handleLoadOlder() {
    if (loading || loadingMore || nextBeforeId === null) return
    const seq = seqRef.current
    moreAbortRef.current?.abort()
    const controller = new AbortController()
    moreAbortRef.current = controller
    setLoadingMore(true); setError("")
    try {
      const page = await listAlertDeliveries({ rule_id: ruleId, status, before_id: nextBeforeId, limit: 50 }, controller.signal)
      if (seq !== seqRef.current || controller.signal.aborted) return
      setSummary(page.summary)
      setItems((prev) => {
        const seen = new Set(prev.map((d) => d.id))
        return [...prev, ...page.items.filter((d) => !seen.has(d.id))]
      })
      setNextBeforeId(page.next_before_id)
    } catch (err) {
      if (seq !== seqRef.current || controller.signal.aborted) return
      handleErr(err, "Could not load older alert deliveries.")
    } finally {
      if (moreAbortRef.current === controller) { moreAbortRef.current = null; setLoadingMore(false) }
    }
  }

  async function handleRetry(item: AlertDeliveryItem) {
    if (retryingId !== null || exporting !== null) return
    const ruleLabel = item.rule_name || ruleNameById.get(item.rule_id) || item.rule_id
    setRetryingId(item.id)
    setError("")
    setNotice("")
    try {
      const res = await retryAlertDelivery(item.id)
      if (res.ok) {
        setNotice(`Retried delivery #${item.id} for ${ruleLabel} (HTTP ${res.delivery.http_status ?? 200}).`)
      } else {
        setError(res.delivery.error || `Webhook retry failed for ${ruleLabel}.`)
      }
      await loadFirstPage(ruleId, status, undefined, !res.ok)
    } catch (err) {
      handleErr(err, `Could not retry delivery #${item.id}.`)
    } finally {
      setRetryingId(null)
    }
  }

  async function handleExport(format: "csv" | "json") {
    if (exporting !== null || retryingId !== null) return
    setExporting(format)
    setError("")
    setNotice("")
    try {
      const filename = await exportAlertDeliveries(format, { rule_id: ruleId, status })
      setNotice(`Exported ${filename}.`)
    } catch (err) {
      handleErr(err, `Could not export alert deliveries as ${format.toUpperCase()}.`)
    } finally {
      setExporting(null)
    }
  }

  const busy = loading || loadingMore || retryingId !== null || exporting !== null
  const rateLabel = `${Number.isFinite(summary.success_rate_pct) ? summary.success_rate_pct.toFixed(1) : "0.0"}%`

  return (
    <div className="stack" aria-label="Webhook delivery history">
      <div className={styles.sectionHead}>
        <div>
          <h3>Webhook delivery history</h3>
          <p className="muted">Filter delivery outcomes, retry failed webhooks, and export history.</p>
        </div>
        <div className={styles.actionsRow}>
          <Button type="button" variant="outline" size="sm" className="min-h-11 sm:min-h-8" disabled={busy} onClick={() => void handleExport("csv")}>
            <Download size={14} aria-hidden="true" />{exporting === "csv" ? "Exporting CSV..." : "Export CSV"}
          </Button>
          <Button type="button" variant="outline" size="sm" className="min-h-11 sm:min-h-8" disabled={busy} onClick={() => void handleExport("json")}>
            <Download size={14} aria-hidden="true" />{exporting === "json" ? "Exporting JSON..." : "Export JSON"}
          </Button>
          <Button type="button" variant="outline" size="sm" className="min-h-11 sm:min-h-8" disabled={busy} onClick={() => void loadFirstPage(ruleId, status)}>
            <RefreshCw size={14} aria-hidden="true" />Refresh
          </Button>
        </div>
      </div>

      <div className="admin-summary-grid" aria-label="Alert delivery summary">
        <div className="panel inset admin-metric">
          <span className="admin-metric-label">Total</span>
          <strong>{summary.total}</strong>
          <small>{summary.failing_rules} failing {summary.failing_rules === 1 ? "rule" : "rules"}</small>
        </div>
        <div className="panel inset admin-metric">
          <span className="admin-metric-label">Delivered</span>
          <strong>{summary.ok_count}</strong>
          <small>Successful deliveries</small>
        </div>
        <div className={`panel inset admin-metric${summary.failed_count > 0 ? " attention" : ""}`}>
          <span className="admin-metric-label">Failed</span>
          <strong>{summary.failed_count}</strong>
          <small>Failed attempts</small>
        </div>
        <div className="panel inset admin-metric">
          <span className="admin-metric-label">Success rate</span>
          <strong>{rateLabel}</strong>
          <small>Matching filter</small>
        </div>
      </div>

      <div className="dual">
        <label className="field">
          Rule
          <select aria-label="Filter deliveries by rule" className="min-h-11 sm:min-h-9" value={ruleId} onChange={(e) => setRuleId(e.target.value)}>
            <option value="">All rules</option>
            {rules.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
          </select>
        </label>
        <label className="field">
          Status
          <select aria-label="Filter deliveries by status" className="min-h-11 sm:min-h-9" value={status} onChange={(e) => setStatus(e.target.value as AlertDeliveryStatusFilter)}>
            <option value="">All</option>
            <option value="ok">Delivered</option>
            <option value="failed">Failed</option>
          </select>
        </label>
      </div>

      {error && <p role="alert" className="error">{error}</p>}
      {notice && <p role="status" className="notice">{notice}</p>}

      {loading && items.length === 0 ? (
        <p role="status" className="muted">Loading webhook deliveries...</p>
      ) : !items.length ? (
        <p className="muted">No webhook deliveries match the selected filters.</p>
      ) : (
        <div className="admin-table-wrap">
          <table className="admin-table">
            <thead>
              <tr><th>Delivered at</th><th>Rule</th><th>Event</th><th>Status</th><th>HTTP</th><th>Error</th><th>Action</th></tr>
            </thead>
            <tbody>
              {items.map((d) => (
                <tr key={d.id}>
                  <td className="admin-mono">{fmt(d.delivered_at)}</td>
                  <td>{d.rule_name || ruleNameById.get(d.rule_id) || d.rule_id}</td>
                  <td className={`admin-mono ${styles.urlCell}`}>{d.event_key}</td>
                  <td><Badge variant={d.ok ? "success" : "destructive"}>{d.ok ? "Delivered" : "Failed"}</Badge></td>
                  <td className="admin-mono">{d.http_status ?? "n/a"}</td>
                  <td className={styles.urlCell}>{d.error || "-"}</td>
                  <td>
                    <Button type="button" variant="outline" size="xs" className="min-h-11 sm:min-h-6" disabled={busy} onClick={() => void handleRetry(d)}>
                      <RotateCw size={12} aria-hidden="true" />{retryingId === d.id ? "Retrying..." : "Retry"}
                    </Button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div className="spread">
        <span className="muted">Showing {items.length} of {summary.total} {summary.total === 1 ? "delivery" : "deliveries"}</span>
        {nextBeforeId !== null && (
          <Button type="button" variant="outline" size="sm" className="min-h-11 sm:min-h-8" disabled={busy} onClick={() => void handleLoadOlder()}>
            {loadingMore ? "Loading older..." : "Load older"}
          </Button>
        )}
      </div>
    </div>
  )
}
