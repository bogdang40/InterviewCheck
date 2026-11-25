"use client"

import { useCallback, useEffect, useRef, useState } from "react"
import { KeyRound, RefreshCw } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { formatCompactTokens, formatUsd } from "@/lib/adminDiagnostics"
import { AdminApiError } from "@/lib/adminModels"
import { formatUsageDay, getAdminUsage, USAGE_PERIODS, type UsageResponse } from "@/lib/adminUsage"
import { UsageCostLog } from "./UsageCostLog"
import { UsageDailyTable, UsageModelsTable, UsagePeopleTable, UsageRecentList } from "./UsageTables"

function count(n: number, one: string, many = `${one}s`): string {
  return `${n} ${n === 1 ? one : many}`
}

function periodLabel(days: number): string {
  return days === 365 ? "Last 12 months" : `Last ${days} days`
}

function AiSetup({ data, onOpenModels }: { data: UsageResponse; onOpenModels: () => void }) {
  const setup = data.ai_setup
  const ready = setup.with_key > 0 || setup.env_fallbacks.length > 0
  return (
    <section className={`panel stack${ready ? "" : " attention"}`} aria-label="AI keys">
      <div className="spread">
        <div className="admin-model-title">
          <KeyRound size={16} aria-hidden="true" />
          <h3>AI keys</h3>
          <Badge variant={ready ? "success" : "warning"}>{ready ? "Set" : "None set"}</Badge>
        </div>
        <Button type="button" variant="outline" size="sm" onClick={onOpenModels}>
          {setup.connected ? "Manage models" : "Connect a model"}
        </Button>
      </div>
      {ready ? (
        <p className="muted">
          {setup.with_key} of {count(setup.connected, "connected model")} {setup.with_key === 1 ? "has" : "have"} a stored key ({setup.enabled} enabled).
          {setup.env_fallbacks.length > 0 &&
            ` Server settings also provide: ${setup.env_fallbacks.map((f) => `${f.provider} ${f.capability}`).join(", ")}.`}
        </p>
      ) : (
        <p className="muted">
          Reference answers, transcription and the AI judge stay off until a key is added. Keys are stored encrypted on
          this server and are never shown again after saving.
        </p>
      )}
    </section>
  )
}

export function UsageTab({ onAuthInvalid, onOpenModels }: { onAuthInvalid: (msg: string) => void; onOpenModels: () => void }) {
  const [days, setDays] = useState<number>(30)
  const [data, setData] = useState<UsageResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState("")
  const [refreshKey, setRefreshKey] = useState(0)
  const requestRef = useRef(0)

  const load = useCallback(async (period: number) => {
    const id = ++requestRef.current
    setLoading(true)
    setError("")
    try {
      const next = await getAdminUsage(period)
      if (id === requestRef.current) setData(next)
    } catch (err) {
      if (id !== requestRef.current) return
      if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) {
        onAuthInvalid(err.message)
        return
      }
      setError(err instanceof Error ? err.message : "Could not load usage.")
    } finally {
      if (id === requestRef.current) setLoading(false)
    }
  }, [onAuthInvalid])

  useEffect(() => {
    void load(days)
  }, [days, load])

  const totals = data?.totals
  const partial = data && (!data.tracking_since || data.tracking_since > data.first_day)

  return (
    <section className="stack" aria-label="Usage">
      <div className="panel inset spread">
        <div>
          <h2>Usage</h2>
          <p className="muted">Who visited, who signed in, and how the workspace and AI were used. Days are in UTC.</p>
        </div>
        <div className="admin-header-actions">
          <label className="field">
            Period
            <select value={String(days)} onChange={(e) => setDays(Number(e.target.value))}>
              {USAGE_PERIODS.map((period) => (
                <option key={period} value={String(period)}>{periodLabel(period)}</option>
              ))}
            </select>
          </label>
          <Button type="button" variant="outline" size="sm" disabled={loading} onClick={() => { void load(days); setRefreshKey((n) => n + 1) }}>
            <RefreshCw size={14} aria-hidden="true" />
            {loading ? "Refreshing..." : "Refresh usage"}
          </Button>
        </div>
      </div>

      {error && <p role="alert" className="error">{error}</p>}
      {loading && !data && <p role="status" className="muted">Loading usage...</p>}

      {data && totals && (
        <>
          <AiSetup data={data} onOpenModels={onOpenModels} />

          <div className="admin-summary-grid" aria-label="Usage summary">
            <article className="panel admin-metric">
              <div className="admin-metric-label"><span>Visitors</span></div>
              <strong>{totals.visitors}</strong>
              <small>Signed-out people, counted once a day · {count(totals.sample, "opened", "opened")} the sample</small>
            </article>
            <article className="panel admin-metric">
              <div className="admin-metric-label"><span>Sign-ins</span></div>
              <strong>{data.accounts_available ? totals.signins : "Not available"}</strong>
              <small>
                {data.accounts_available
                  ? `${count(totals.new_accounts, "new account")} · ${count(data.accounts_total ?? 0, "account")} in all`
                  : "Accounts are kept by a separate account service."}
              </small>
            </article>
            <article className="panel admin-metric">
              <div className="admin-metric-label"><span>Interviews</span></div>
              <strong>{totals.interviews}</strong>
              <small>{count(totals.answers, "answer")} checked · {count(totals.reviews, "review")} saved</small>
            </article>
            <article className={`panel admin-metric${totals.ai_errors > 0 ? " attention" : ""}`}>
              <div className="admin-metric-label"><span>AI requests</span></div>
              <strong>{totals.ai_requests}</strong>
              <small>{formatUsd(totals.ai_cost_usd)} estimated · {formatCompactTokens(totals.ai_tokens)} tokens · {count(totals.ai_errors, "error")}</small>
            </article>
          </div>

          {partial && (
            <p role="note" className="notice">
              Visitor and answer counts started {formatUsageDay(data.tracking_since ?? data.last_day)}. Interviews,
              reviews, sign-ins and AI requests include earlier days.
            </p>
          )}

          <UsageCostLog days={days} refreshKey={refreshKey} onAuthInvalid={onAuthInvalid} />
          <UsageDailyTable daily={data.daily} />
          {data.accounts_available && <UsagePeopleTable people={data.people} period={periodLabel(data.days)} />}
          {data.accounts_available && <UsageRecentList recent={data.recent} />}
          <UsageModelsTable models={data.models} period={periodLabel(data.days)} />
        </>
      )}
    </section>
  )
}
