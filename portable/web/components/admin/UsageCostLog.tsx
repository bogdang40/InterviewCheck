"use client"

import { useCallback, useEffect, useRef, useState } from "react"
import { Download } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { formatCompactTokens, formatUsd } from "@/lib/adminDiagnostics"
import { AdminApiError, CAPABILITY_LABELS, PROVIDER_LABELS, type ModelCapability, type ModelProvider } from "@/lib/adminModels"
import { aiCostCsvUrl, formatWhen, getAiCosts, type AiCostResponse, type AiCostRow } from "@/lib/adminUsage"

const provider = (p?: string) => (p ? PROVIDER_LABELS[p as ModelProvider] ?? p : "")
const task = (c?: string) => (c ? CAPABILITY_LABELS[c as ModelCapability] ?? c : "")
const tokens = (r: { input_tokens: number; output_tokens: number }) =>
  `${formatCompactTokens(r.input_tokens)} in · ${formatCompactTokens(r.output_tokens)} out`
const requests = (r: AiCostRow) => `${r.requests}${r.errors ? ` (${r.errors} failed)` : ""}`
const monthLabel = (m?: string) =>
  m ? new Date(`${m}-15T12:00:00Z`).toLocaleDateString(undefined, { month: "long", year: "numeric", timeZone: "UTC" }) : ""

export function UsageCostLog({ days, refreshKey, onAuthInvalid }: { days: number; refreshKey: number; onAuthInvalid: (msg: string) => void }) {
  const [data, setData] = useState<AiCostResponse | null>(null)
  const [error, setError] = useState("")
  const requestRef = useRef(0)

  const load = useCallback(async () => {
    const id = ++requestRef.current
    setError("")
    try {
      const next = await getAiCosts(days)
      if (id === requestRef.current) setData(next)
    } catch (err) {
      if (id !== requestRef.current) return
      if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) {
        onAuthInvalid(err.message)
        return
      }
      setError(err instanceof Error ? err.message : "Could not load the AI cost log.")
    }
  }, [days, onAuthInvalid])

  useEffect(() => {
    void load()
  }, [load, refreshKey])

  const t = data?.totals
  return (
    <section className="panel stack" aria-label="AI cost log">
      <div className="spread">
        <div>
          <h3>AI cost log</h3>
          <p className="muted">
            Every AI request with who asked, the provider, the model and its estimated cost. No question or answer text is
            kept. Company is the account&apos;s email domain.
          </p>
        </div>
        <Button asChild variant="outline" size="sm">
          <a href={aiCostCsvUrl(days)} download>
            <Download size={14} aria-hidden="true" />
            Download CSV
          </a>
        </Button>
      </div>
      {error && <p role="alert" className="error">{error}</p>}
      {!data && !error && <p role="status" className="muted">Loading the AI cost log...</p>}
      {data && t && (
        !t.requests ? <p className="muted">No AI requests in this period.</p> : (
          <>
            <p className="admin-mono">
              {t.requests} requests{t.errors ? ` (${t.errors} failed)` : ""} · {tokens(t)} · {formatUsd(t.cost_usd)} estimated
            </p>

            <h4>By company</h4>
            <div className="admin-table-wrap">
              <table className="admin-table">
                <thead><tr><th>Company</th><th>Accounts</th><th>Requests</th><th>Tokens</th><th>Estimated cost</th></tr></thead>
                <tbody>
                  {data.by_company.map((r) => (
                    <tr key={r.company}>
                      <th scope="row" data-label="Company">{r.company}</th>
                      <td data-label="Accounts" className="admin-mono">{r.accounts}</td>
                      <td data-label="Requests" className="admin-mono">{requests(r)}</td>
                      <td data-label="Tokens" className="admin-mono">{tokens(r)}</td>
                      <td data-label="Estimated cost" className="admin-mono">{formatUsd(r.cost_usd)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <h4>By company, account, provider and model</h4>
            <div className="admin-table-wrap">
              <table className="admin-table">
                <thead><tr><th>Company</th><th>Account</th><th>Provider</th><th>Model</th><th>Used for</th><th>Calls</th><th>Tokens</th><th>Cost</th></tr></thead>
                <tbody>
                  {data.by_company_model.map((r) => (
                    <tr key={`${r.company}|${r.account_email}|${r.provider}|${r.model_id}|${r.capability}`}>
                      <th scope="row" data-label="Company">{r.company}</th>
                      <td data-label="Account">{r.account_email ?? "Signed-out or system"}</td>
                      <td data-label="Provider">{provider(r.provider)}</td>
                      <td data-label="Model">{r.model_name || r.model_id}<span className="muted admin-mono"> {r.model_id}</span></td>
                      <td data-label="Used for">{task(r.capability)}</td>
                      <td data-label="Calls" className="admin-mono">{requests(r)}</td>
                      <td data-label="Tokens" className="admin-mono">{tokens(r)}</td>
                      <td data-label="Cost" className="admin-mono">{formatUsd(r.cost_usd)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <h4>By month</h4>
            <div className="admin-table-wrap">
              <table className="admin-table">
                <thead><tr><th>Month</th><th>Company</th><th>Requests</th><th>Tokens</th><th>Estimated cost</th></tr></thead>
                <tbody>
                  {data.by_month.map((r) => (
                    <tr key={`${r.month}|${r.company}`}>
                      <th scope="row" data-label="Month">{monthLabel(r.month)}</th>
                      <td data-label="Company">{r.company}</td>
                      <td data-label="Requests" className="admin-mono">{requests(r)}</td>
                      <td data-label="Tokens" className="admin-mono">{tokens(r)}</td>
                      <td data-label="Estimated cost" className="admin-mono">{formatUsd(r.cost_usd)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <h4>Latest requests</h4>
            <ol className="admin-usage-recent">
              {data.recent.map((c, i) => (
                <li key={`${c.at}-${i}`}>
                  <span className="admin-mono">{formatWhen(c.at)}</span>
                  <span>
                    {c.account_email ?? "Signed-out or system"} · {task(c.capability)} · {provider(c.provider)} {c.model_name || c.model_id}
                    {!c.ok && <> <Badge variant="destructive">Failed{c.http_status ? ` ${c.http_status}` : ""}</Badge></>}
                  </span>
                  <span className="admin-mono">{tokens(c)} · {formatUsd(c.cost_usd)}</span>
                </li>
              ))}
            </ol>
          </>
        )
      )}
    </section>
  )
}
