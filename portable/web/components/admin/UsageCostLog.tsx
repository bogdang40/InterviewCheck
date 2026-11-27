"use client"

import { useEffect, useState } from "react"
import { Download } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { formatCompactTokens, formatUsd } from "@/lib/adminDiagnostics"
import { AdminApiError, CAPABILITY_LABELS, PROVIDER_LABELS, type ModelCapability, type ModelProvider } from "@/lib/adminModels"
import { aiCostCsvUrl, costQuery, formatWhen, getAiCosts, type AiCostResponse, type AiCostRow, type AiCostSums, type EstimateStatus } from "@/lib/adminUsage"

const provider = (p?: string) => (p ? PROVIDER_LABELS[p as ModelProvider] ?? p : "")
const task = (c?: string) => c === "playground" ? "Playground" : (c ? CAPABILITY_LABELS[c as ModelCapability] ?? c : "")
const tokens = (r: { input_tokens: number; output_tokens: number; unsplit_tokens: number }) => {
  const known = `${formatCompactTokens(r.input_tokens)} in · ${formatCompactTokens(r.output_tokens)} out`
  if (!r.unsplit_tokens) return known
  const unsplit = `${formatCompactTokens(r.unsplit_tokens)} without breakdown`
  return r.input_tokens || r.output_tokens ? `${known} · ${unsplit}` : unsplit
}
const requests = (r: AiCostRow) => `${r.requests}${r.errors ? ` (${r.errors} failed)` : ""}`
const monthLabel = (m?: string) =>
  m ? new Date(`${m}-15T12:00:00Z`).toLocaleDateString(undefined, { month: "long", year: "numeric", timeZone: "UTC" }) : ""

const estimateLabels: Record<EstimateStatus, string> = {
  estimated: "Estimated",
  missing_rates: "Missing price",
  missing_usage: "Token usage incomplete",
  unknown: "Historical estimate unverified",
}

function costTotal(row: AiCostSums) {
  if (row.estimated_requests === row.requests) return formatUsd(row.cost_usd)
  if (row.estimated_requests || row.cost_usd > 0) return `${formatUsd(row.cost_usd)} (partial)`
  return "Unknown"
}

type Props = { days: number; refreshKey: number; onAuthInvalid: (msg: string) => void; onOpenModels: () => void }
export function UsageCostLog({ days, refreshKey, onAuthInvalid, onOpenModels }: Props) {
  const [company, setCompany] = useState("")
  const [failedOnly, setFailedOnly] = useState(false)
  const query = costQuery(days, company, failedOnly)
  const [report, setReport] = useState<{ query: string; data: AiCostResponse } | null>(null)
  const [failure, setFailure] = useState<{ query: string; message: string } | null>(null)

  useEffect(() => {
    let active = true
    setFailure(null)
    getAiCosts(query).then((data) => {
      if (active) setReport({ query, data })
    }).catch((err) => {
      if (!active) return
      if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) {
        onAuthInvalid(err.message)
        return
      }
      setFailure({ query, message: err instanceof Error ? err.message : "Could not load the AI cost log." })
    })
    return () => { active = false }
  }, [query, onAuthInvalid, refreshKey])

  const error = failure?.query === query ? failure.message : ""
  const data = report?.query === query && !error ? report.data : null
  const companies = report?.data.days === days ? report.data.companies : []
  const t = data?.totals
  return (
    <section className="panel stack" aria-label="AI cost log">
      <div className="spread">
        <div>
          <h3>AI cost log</h3>
          <p className="muted">
            Provider calls grouped by the account&apos;s email domain. The log excludes interview text.
          </p>
        </div>
        {data && <Button asChild variant="outline" size="sm">
          <a href={aiCostCsvUrl(query, data)} download>
            <Download size={14} aria-hidden="true" />
            Download CSV
          </a>
        </Button>}
      </div>
      <div className="admin-header-actions">
        <div className="field">
          <label htmlFor="cost-company">Company</label>
          <select id="cost-company" value={company} onChange={(event) => setCompany(event.target.value)}>
            <option value="">All companies</option>
            {company && !companies.includes(company) && <option value={company}>{company}</option>}
            {companies.map((name) => <option key={name} value={name}>{name}</option>)}
          </select>
        </div>
        <div className="field">
          <label htmlFor="cost-outcome">Outcome</label>
          <select id="cost-outcome" value={failedOnly ? "failed" : "all"} onChange={(event) => setFailedOnly(event.target.value === "failed")}>
            <option value="all">All requests</option>
            <option value="failed">Failed requests</option>
          </select>
        </div>
      </div>
      {error && <p role="alert" className="error">{error}</p>}
      {!data && !error && <p role="status" className="muted">Loading the AI cost log...</p>}
      {data && t && (
        !t.requests ? <p className="muted">No AI requests match this period and these filters.</p> : (
          <>
            <p className="admin-mono">
              {t.requests} {t.requests === 1 ? "request" : "requests"}{t.errors ? ` (${t.errors} failed)` : ""} · {tokens(t)} · Estimated cost: {costTotal(t)}
            </p>

            {t.estimated_requests < t.requests && (
              <div className="notice" role="note">
                <p>Complete estimates for {t.estimated_requests} of {t.requests} calls.
                  {t.missing_rate_requests > 0 && ` Missing prices: ${t.missing_rate_requests}.`}
                  {t.missing_usage_requests > 0 && ` Incomplete token usage: ${t.missing_usage_requests}.`}
                  {t.unknown_requests > 0 && ` Historical calls with unverified estimates: ${t.unknown_requests}.`}
                </p>
                {t.missing_rate_requests > 0 && (
                  <Button type="button" variant="outline" size="sm" onClick={onOpenModels}>Manage model prices</Button>
                )}
              </div>
            )}

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
                      <td data-label="Estimated cost" className="admin-mono"><span className="whitespace-nowrap">{costTotal(r)}</span></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <h4>By company, account, provider and model</h4>
            {data.by_company_model.length === 500 && <p className="muted">This table shows up to 500 groups. Download the CSV for all matching calls.</p>}
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
                      <td data-label="Cost" className="admin-mono"><span className="whitespace-nowrap">{costTotal(r)}</span></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <h4>By month</h4>
            {data.by_month.length === 240 && <p className="muted">This table shows up to 240 month and company groups. Download the CSV for all matching calls.</p>}
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
                      <td data-label="Estimated cost" className="admin-mono"><span className="whitespace-nowrap">{costTotal(r)}</span></td>
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
                  <span className="admin-mono">{tokens(c)} · {c.estimate_status === "estimated" || c.cost_usd > 0 ? `${formatUsd(c.cost_usd)} · ` : ""}{estimateLabels[c.estimate_status]}</span>
                </li>
              ))}
            </ol>
          </>
        )
      )}
    </section>
  )
}
