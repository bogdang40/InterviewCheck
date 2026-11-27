"use client"

import { Badge } from "@/components/ui/badge"
import { formatCompactTokens } from "@/lib/adminDiagnostics"
import { CAPABILITY_LABELS, PROVIDER_LABELS, type ModelCapability, type ModelProvider } from "@/lib/adminModels"
import {
  formatUsageDay,
  formatWhen,
  hasActivity,
  recordedCost,
  type UsageDay,
  type UsageEvent,
  type UsageModel,
  type UsagePerson,
} from "@/lib/adminUsage"

export function UsageDailyTable({ daily }: { daily: UsageDay[] }) {
  const active = daily.filter(hasActivity)
  return (
    <section className="panel stack" aria-label="Activity by day">
      <h3>Activity by day</h3>
      {!active.length ? (
        <p className="muted">No activity in this period.</p>
      ) : (
        <>
          <div className="admin-table-wrap">
            <table className="admin-table">
              <thead>
                <tr>
                  <th>Day</th>
                  <th>Visitors</th>
                  <th>Sample</th>
                  <th>Sign-ins</th>
                  <th>New accounts</th>
                  <th>Interviews</th>
                  <th>Answers</th>
                  <th>Reviews</th>
                  <th>AI requests</th>
                  <th>AI cost</th>
                </tr>
              </thead>
              <tbody>
                {active.map((d) => (
                  <tr key={d.day}>
                    <th scope="row" data-label="Day">{formatUsageDay(d.day)}</th>
                    <td data-label="Visitors" className="admin-mono">{d.visitors}</td>
                    <td data-label="Sample" className="admin-mono">{d.sample}</td>
                    <td data-label="Sign-ins" className="admin-mono">{d.signins}</td>
                    <td data-label="New accounts" className="admin-mono">{d.new_accounts}</td>
                    <td data-label="Interviews" className="admin-mono">{d.interviews}</td>
                    <td data-label="Answers" className="admin-mono">{d.answers}</td>
                    <td data-label="Reviews" className="admin-mono">{d.reviews}</td>
                    <td data-label="AI requests" className="admin-mono">{d.ai_requests}{d.ai_errors ? ` (${d.ai_errors} failed)` : ""}</td>
                    <td data-label="AI cost" className="admin-mono">{recordedCost(d.ai_requests, d.ai_cost_usd)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {active.length < daily.length && <p className="muted">Days with no activity are left out.</p>}
        </>
      )}
    </section>
  )
}

export function UsagePeopleTable({ people, period }: { people: UsagePerson[]; period: string }) {
  return (
    <section className="panel stack" aria-label="People">
      <h3>People</h3>
      <p className="muted">Every account on this site. Only the workspace operator can open interviews.</p>
      {!people.length ? (
        <p className="muted">No accounts yet.</p>
      ) : (
        <div className="admin-table-wrap">
          <table className="admin-table">
            <thead>
              <tr>
                <th>Email</th>
                <th>Role</th>
                <th>Created</th>
                <th>Last sign-in</th>
                <th>Sign-ins ({period.toLowerCase()})</th>
                <th>Signed-in browsers</th>
              </tr>
            </thead>
            <tbody>
              {people.map((p) => (
                <tr key={p.email}>
                  <th scope="row" data-label="Email">
                    <span className="admin-usage-person">
                      {p.email}
                      {p.operator && <Badge variant="default">Workspace operator</Badge>}
                      {p.disabled && <Badge variant="destructive">Disabled</Badge>}
                    </span>
                  </th>
                  <td data-label="Role"><Badge variant={p.role === "admin" ? "default" : "secondary"}>{p.role}</Badge></td>
                  <td data-label="Created">{formatWhen(p.created_at)}</td>
                  <td data-label="Last sign-in">{formatWhen(p.last_login_at)}</td>
                  <td data-label="Sign-ins" className="admin-mono">{p.signins}</td>
                  <td data-label="Signed-in browsers" className="admin-mono">{p.active_sessions}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}

const EVENT_LABELS: Record<string, string> = { "auth.login": "Signed in", "auth.signup": "Created an account" }

export function UsageRecentList({ recent }: { recent: UsageEvent[] }) {
  return (
    <section className="panel stack" aria-label="Recent sign-ins">
      <h3>Recent sign-ins and new accounts</h3>
      {!recent.length ? (
        <p className="muted">No sign-ins yet.</p>
      ) : (
        <ol className="admin-usage-recent">
          {recent.map((event, index) => (
            <li key={`${event.at}-${index}`}>
              <span className="admin-mono">{formatWhen(event.at)}</span>
              <span>{event.email ?? "Deleted account"}</span>
              <span className="muted">{EVENT_LABELS[event.action] ?? event.action}</span>
            </li>
          ))}
        </ol>
      )}
    </section>
  )
}

export function UsageModelsTable({ models, period }: { models: UsageModel[]; period: string }) {
  return (
    <section className="panel stack" aria-label="AI usage by model">
      <h3>AI usage by model</h3>
      <p className="muted">{period}. These counters record estimated charges. The AI cost log shows which calls had prices and usage data.</p>
      {!models.length ? (
        <p className="muted">No models connected yet.</p>
      ) : (
        <div className="admin-table-wrap">
          <table className="admin-table">
            <thead>
              <tr>
                <th>Model</th>
                <th>Used for</th>
                <th>Key</th>
                <th>Requests</th>
                <th>Tokens</th>
                <th>Estimated cost</th>
              </tr>
            </thead>
            <tbody>
              {models.map((m) => (
                <tr key={`${m.provider}-${m.model_id}-${m.name}`}>
                  <th scope="row" data-label="Model">
                    {m.name}
                    <span className="muted admin-mono"> {PROVIDER_LABELS[m.provider as ModelProvider] ?? m.provider} · {m.model_id}</span>
                  </th>
                  <td data-label="Used for">{CAPABILITY_LABELS[m.capability as ModelCapability] ?? m.capability}{m.enabled ? "" : " (off)"}</td>
                  <td data-label="Key">{m.has_key ? <Badge variant="success">Stored</Badge> : <Badge variant="outline">None</Badge>}</td>
                  <td data-label="Requests" className="admin-mono">{m.requests}{m.errors ? ` (${m.errors} failed)` : ""}</td>
                  <td data-label="Tokens" className="admin-mono">{formatCompactTokens(m.tokens)}</td>
                  <td data-label="Estimated cost" className="admin-mono">{recordedCost(m.requests, m.cost_usd)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}
