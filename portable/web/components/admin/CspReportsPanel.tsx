"use client"

import { useCallback, useEffect, useState } from "react"
import { FileWarning, RefreshCw, Trash2 } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { AdminApiError, adminRequest } from "@/lib/adminModels"

export type CspViolationReport = {
  id: number
  received_at: string
  document_uri: string
  violated_directive: string
  effective_directive: string
  blocked_uri: string
  source_file: string
  line_number: number | null
  column_number: number | null
  disposition: string
  status_code: number | null
}

const fmt = (iso: string) => {
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString()
}

export function CspReportsPanel({ onAuthInvalid }: { onAuthInvalid: (msg: string) => void }) {
  const [reports, setReports] = useState<CspViolationReport[]>([])
  const [total, setTotal] = useState(0)
  const [loading, setLoading] = useState(true)
  const [clearing, setClearing] = useState(false)
  const [unsupported, setUnsupported] = useState(false)
  const [error, setError] = useState("")
  const [notice, setNotice] = useState("")

  const handleErr = useCallback((err: unknown, fallback: string) => {
    if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) { onAuthInvalid(err.message); return }
    if (err instanceof AdminApiError && (err.status === 404 || err.status === 501)) { setUnsupported(true); setReports([]); setTotal(0); return }
    setError(err instanceof Error ? err.message : fallback)
  }, [onAuthInvalid])

  const loadReports = useCallback(async () => {
    setLoading(true); setError(""); setUnsupported(false)
    try {
      const data = await adminRequest<{ reports?: CspViolationReport[]; total?: number }>("/api/admin/security/csp-reports?limit=100")
      setReports(Array.isArray(data?.reports) ? data.reports : [])
      setTotal(typeof data?.total === "number" ? data.total : 0)
    } catch (err) { handleErr(err, "Could not load CSP violation reports.") }
    finally { setLoading(false) }
  }, [handleErr])

  useEffect(() => { void loadReports() }, [loadReports])

  async function handleClear() {
    setClearing(true); setError(""); setNotice("")
    try {
      const res = await adminRequest<{ ok?: boolean; cleared?: number }>("/api/admin/security/csp-reports", { method: "DELETE" })
      setReports([]); setTotal(0)
      setNotice(`Cleared ${res.cleared ?? 0} CSP violation report(s).`)
    } catch (err) { handleErr(err, "Could not clear CSP violation reports.") }
    finally { setClearing(false) }
  }

  return (
    <section className="panel stack" aria-label="CSP violation reports">
      <div className="spread">
        <div>
          <h2 className="admin-sim-heading">
            <FileWarning size={18} aria-hidden="true" />
            CSP violation reports
            <Badge variant={total > 0 ? "warning" : "secondary"}>{total} recorded</Badge>
          </h2>
          <p className="muted">Sanitized Content-Security-Policy browser violation reports (query strings stripped).</p>
        </div>
        <div className="admin-header-actions">
          <Button type="button" variant="outline" size="sm" disabled={loading || clearing} onClick={() => void loadReports()}>
            <RefreshCw size={14} aria-hidden="true" />Refresh
          </Button>
          <Button type="button" variant="outline" size="sm" disabled={loading || clearing || unsupported || total === 0} onClick={() => void handleClear()}>
            <Trash2 size={14} aria-hidden="true" />{clearing ? "Clearing..." : "Clear reports"}
          </Button>
        </div>
      </div>
      {error && <p role="alert" className="error">{error}</p>}
      {notice && <p role="status" className="notice">{notice}</p>}
      {loading ? (
        <p role="status" className="muted">Loading CSP violation reports...</p>
      ) : unsupported ? (
        <p className="muted">CSP violation reporting is not enabled on this server.</p>
      ) : !reports.length ? (
        <p className="muted">No CSP violation reports recorded.</p>
      ) : (
        <div className="admin-table-wrap">
          <table className="admin-table">
            <thead><tr><th>Received</th><th>Directive</th><th>Document URI</th><th>Blocked URI</th><th>Source</th></tr></thead>
            <tbody>
              {reports.map((r) => (
                <tr key={r.id}>
                  <td className="admin-mono">{fmt(r.received_at)}</td>
                  <td><div className="admin-model-title"><Badge variant="outline">{r.effective_directive || r.violated_directive || "n/a"}</Badge><Badge variant="secondary">{r.disposition}</Badge></div></td>
                  <td className="admin-mono">{r.document_uri || "n/a"}</td>
                  <td className="admin-mono">{r.blocked_uri || "n/a"}</td>
                  <td className="admin-mono">{r.source_file ? `${r.source_file}${r.line_number !== null ? `:${r.line_number}` : ""}` : "n/a"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}
