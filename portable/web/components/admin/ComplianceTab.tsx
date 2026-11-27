"use client"

import { useCallback, useEffect, useState, type FormEvent } from "react"
import { Download, FileCheck2, Play, RefreshCw, ShieldCheck } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { AdminApiError, parseOptionalInt } from "@/lib/adminModels"
import {
  downloadComplianceReport, downloadSessionAudit, getComplianceReport, getRetentionState,
  getSessionAuditPreview, runHeadersCheck, runRetentionJob, updateRetentionPolicy,
  type ComplianceReport, type HeadersCheckResponse, type RetentionRun,
  type RetentionRunResult, type SessionAuditResponse,
} from "@/lib/adminCompliance"
import styles from "./ComplianceTab.module.css"

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const fmtDate = (iso: string | null | undefined) => (!iso ? "none" : Number.isNaN(new Date(iso).getTime()) ? iso : new Date(iso).toLocaleString())
const statusVariant = (status: string): "success" | "warning" | "destructive" =>
  status === "pass" ? "success" : status === "warn" ? "warning" : "destructive"

export function ComplianceTab({ onAuthInvalid }: { onAuthInvalid: (msg: string) => void }) {
  const [report, setReport] = useState<ComplianceReport | null>(null)
  const [headersResult, setHeadersResult] = useState<HeadersCheckResponse | null>(null)
  const [runs, setRuns] = useState<RetentionRun[]>([])
  const [withheld, setWithheld] = useState(0)
  const [loading, setLoading] = useState(true)
  const [errorMsg, setErrorMsg] = useState("")
  const [statusMsg, setStatusMsg] = useState("")
  const [busyKey, setBusyKey] = useState<string | null>(null)
  const [anonDays, setAnonDays] = useState("90")
  const [purgeDays, setPurgeDays] = useState("30")
  const [preserveScorecards, setPreserveScorecards] = useState(true)
  const [policyEnabled, setPolicyEnabled] = useState(false)
  const [confirmLive, setConfirmLive] = useState("")
  const [lastRunResult, setLastRunResult] = useState<RetentionRunResult | null>(null)
  const [sessionId, setSessionId] = useState("")
  const [auditPreview, setAuditPreview] = useState<SessionAuditResponse | null>(null)

  const checkAuth = useCallback((err: unknown): boolean => {
    if (err instanceof AdminApiError && (err.status === 401 || err.status === 403)) {
      onAuthInvalid(err.message); return true
    }
    return false
  }, [onAuthInvalid])

  const loadAll = useCallback(async () => {
    setLoading(true); setErrorMsg("")
    const [repRes, retRes, hdrRes] = await Promise.allSettled([getComplianceReport(), getRetentionState(), runHeadersCheck()])
    const errors: string[] = []
    for (const r of [repRes, retRes, hdrRes]) {
      if (r.status === "rejected") {
        if (checkAuth(r.reason)) { setLoading(false); return }
        errors.push(r.reason instanceof Error ? r.reason.message : "Failed to load compliance data.")
      }
    }
    if (repRes.status === "fulfilled") setReport(repRes.value)
    if (retRes.status === "fulfilled") {
      const { policy, runs: nextRuns } = retRes.value
      setWithheld(retRes.value.withheld_interviews ?? 0)
      setRuns(nextRuns); setAnonDays(String(policy.anonymize_after_days))
      setPurgeDays(String(policy.purge_trashed_after_days))
      setPreserveScorecards(policy.preserve_scorecard_aggregates); setPolicyEnabled(policy.enabled)
    }
    if (hdrRes.status === "fulfilled") setHeadersResult(hdrRes.value)
    if (errors.length > 0) setErrorMsg(errors[0])
    setLoading(false)
  }, [checkAuth])

  useEffect(() => { void loadAll() }, [loadAll])

  async function runAction(key: string, fn: () => Promise<void>, fallbackErr: string) {
    setBusyKey(key); setErrorMsg(""); setStatusMsg("")
    try { await fn() }
    catch (err) { if (!checkAuth(err)) setErrorMsg(err instanceof Error ? err.message : fallbackErr) }
    finally { setBusyKey(null) }
  }

  async function handleSavePolicy(e: FormEvent<HTMLFormElement>) {
    e.preventDefault(); setErrorMsg(""); setStatusMsg("")
    let anonVal: number | null, purgeVal: number | null
    try {
      anonVal = parseOptionalInt(anonDays, "Anonymize after days", 0, 3650)
      purgeVal = parseOptionalInt(purgeDays, "Purge trashed after days", 0, 3650)
      if (anonVal === null || purgeVal === null) throw new Error("Both retention day thresholds are required.")
    } catch (err) { setErrorMsg(err instanceof Error ? err.message : "Invalid retention thresholds."); return }
    await runAction("save-policy", async () => {
      const saved = await updateRetentionPolicy({
        anonymize_after_days: anonVal!, purge_trashed_after_days: purgeVal!,
        preserve_scorecard_aggregates: preserveScorecards, enabled: policyEnabled,
      })
      setAnonDays(String(saved.anonymize_after_days)); setPurgeDays(String(saved.purge_trashed_after_days))
      setPreserveScorecards(saved.preserve_scorecard_aggregates); setPolicyEnabled(saved.enabled)
      setStatusMsg("Retention policy saved.")
      setReport(await getComplianceReport())
    }, "Could not save retention policy.")
  }

  function handleRunRetention(dryRun: boolean) {
    if (!dryRun && confirmLive.trim() !== "RUN") { setErrorMsg('Type "RUN" to confirm live retention execution.'); return }
    void runAction(dryRun ? "dry-run" : "live-run", async () => {
      const res = await runRetentionJob(dryRun)
      setLastRunResult(res)
      if (!dryRun) setConfirmLive("")
      setStatusMsg(`${dryRun ? "Dry-run preview" : "Live retention"} complete: ${res.anonymized_sessions} anonymized, ${res.purged_sessions} purged.`)
      const [ret, rep] = await Promise.all([getRetentionState(), getComplianceReport()])
      setRuns(ret.runs); setWithheld(ret.withheld_interviews ?? 0); setReport(rep)
    }, "Retention run failed.")
  }

  function validatedSid(): string | null {
    const trimmed = sessionId.trim()
    if (!UUID_RE.test(trimmed)) { setErrorMsg("Enter a valid session UUID before exporting or previewing its audit timeline."); return null }
    return trimmed
  }

  const chainsOk = Boolean(report && report.audit_chains.model_fallback.ok && (!report.audit_chains.access.available || report.audit_chains.access.ok))
  const verifiedCount = report ? report.audit_chains.model_fallback.verifiedCount + report.audit_chains.access.verifiedCount : 0
  const postureCards = report ? [
    { label: "Audit hash chains", value: chainsOk ? "Intact" : "Broken", note: `${verifiedCount} verified entries` },
    { label: "Sessions and PII", value: `${report.sessions.anonymized} anonymized`, note: `${report.sessions.active} active, ${report.sessions.trashed} trashed` },
    { label: "Model encryption", value: `${report.models.enabled}/${report.models.total} active`, note: `v2: ${report.models.encryption_envelopes.v2}, v1: ${report.models.encryption_envelopes.v1}` },
    { label: "Signals and access", value: `${report.csp_violations.total} CSP events`, note: `TOTP: ${report.access_db.totp_enrolled}, tokens: ${report.access_db.api_tokens.active}` },
  ] : []

  return (
    <div className={styles.tabRoot}>
      {errorMsg && <p role="alert" className="error">{errorMsg}</p>}
      {statusMsg && <p role="status" className="notice">{statusMsg}</p>}

      <section className="panel stack" aria-label="Compliance posture and reports">
        <div className={styles.sectionHead}>
          <div>
            <h2 className="admin-sim-heading"><ShieldCheck size={18} aria-hidden="true" />Compliance posture &amp; reports</h2>
            <p className="muted">Zero-secret security posture across audit chains, encryption envelopes, retention, and access controls.</p>
          </div>
          <div className={styles.actionsRow}>
            <Button type="button" variant="outline" size="sm" disabled={loading || busyKey !== null} onClick={() => void loadAll()}>
              <RefreshCw size={14} aria-hidden="true" />Refresh
            </Button>
            <Button type="button" variant="outline" size="sm" disabled={busyKey !== null} onClick={() => void runAction("report:json", async () => setStatusMsg(`Downloaded ${await downloadComplianceReport("json")}.`), "Could not download compliance report.")}>
              <Download size={14} aria-hidden="true" />{busyKey === "report:json" ? "Downloading..." : "Report JSON"}
            </Button>
            <Button type="button" variant="outline" size="sm" disabled={busyKey !== null} onClick={() => void runAction("report:markdown", async () => setStatusMsg(`Downloaded ${await downloadComplianceReport("markdown")}.`), "Could not download compliance report.")}>
              <Download size={14} aria-hidden="true" />{busyKey === "report:markdown" ? "Downloading..." : "Report Markdown"}
            </Button>
          </div>
        </div>
        {loading && !report ? <p role="status" className="panel inset muted">Loading compliance posture...</p> : report ? (
          <>
            <div className={styles.summaryRow}>
              {postureCards.map((c) => (
                <div key={c.label} className={`panel inset ${styles.summaryCell}`}>
                  <span className="muted">{c.label}</span><strong>{c.value}</strong><small className="muted">{c.note}</small>
                </div>
              ))}
            </div>
            <div className={styles.kvStrip}>
              <span>Mode: {report.runtime.access_mode}</span>
              <span>Production: {report.runtime.production_mode ? "yes" : "no"}</span>
              <span>Key source: {report.runtime.model_secret_source}</span>
              <span>Access DB: {report.access_db.available ? `v${report.access_db.schema_version}` : "unavailable"}</span>
              <span>Alerts: {report.alert_rules.enabled}/{report.alert_rules.total}</span>
            </div>
          </>
        ) : null}
      </section>

      <section className="panel stack" aria-label="Edge header and boundary checks">
        <div className={styles.sectionHead}>
          <div>
            <h2 className="admin-sim-heading"><FileCheck2 size={18} aria-hidden="true" />Edge headers &amp; boundary checks</h2>
            <p className="muted">Validate Host, Origin, proxy trust, secret permissions, and security header middleware.</p>
          </div>
          <div className={styles.actionsRow}>
            {headersResult && <Badge variant={headersResult.ok ? "success" : "destructive"}>{headersResult.ok ? "Boundary OK" : "Check failed"}</Badge>}
            <Button type="button" variant="outline" size="sm" disabled={busyKey !== null} onClick={() => void runAction("headers", async () => {
              const res = await runHeadersCheck(); setHeadersResult(res)
              setStatusMsg(res.ok ? "Edge header and boundary checks passed." : "Edge header check flagged one or more issues.")
            }, "Header check failed.")}>
              <Play size={14} aria-hidden="true" />{busyKey === "headers" ? "Checking..." : "Run header check"}
            </Button>
          </div>
        </div>
        {headersResult && (
          <div className={styles.checkList}>
            {headersResult.checks.map((chk) => (
              <div key={chk.id} className={`panel inset ${styles.checkItem}`}>
                <div className={styles.checkMeta}><strong className={styles.monoDetail}>{chk.id}</strong><span className="muted">{chk.detail}</span></div>
                <Badge variant={statusVariant(chk.status)}>{chk.status}</Badge>
              </div>
            ))}
          </div>
        )}
      </section>

      <section className="panel stack" aria-label="Data retention and PII anonymization">
        <div><h2>Data retention &amp; PII anonymization</h2><p className="muted">Configure retention cutoffs, preview impact with a dry run, or execute permanent redaction and purge.</p></div>
        {withheld > 0 && <p role="alert">Interviews withheld by erasure checks: {withheld}. Inspect a consistent SQLite backup before sharing affected records.</p>}
        <form className={`panel inset ${styles.policyForm}`} onSubmit={handleSavePolicy}>
          <div className={styles.policyGrid}>
            <label className="field"><span>Anonymize finished sessions after (days, 0 disables)</span><Input type="number" min={0} max={3650} value={anonDays} onChange={(e) => setAnonDays(e.target.value)} /></label>
            <label className="field"><span>Purge trashed sessions after (days, 0 disables)</span><Input type="number" min={0} max={3650} value={purgeDays} onChange={(e) => setPurgeDays(e.target.value)} /></label>
          </div>
          <div className={styles.checkRow}>
            <label className="check"><input type="checkbox" checked={preserveScorecards} onChange={(e) => setPreserveScorecards(e.target.checked)} /><span>Preserve scorecard aggregates and handoff notes</span></label>
            <label className="check"><input type="checkbox" checked={policyEnabled} onChange={(e) => setPolicyEnabled(e.target.checked)} /><span>Policy enabled</span></label>
          </div>
          <div className={styles.actionsRow}>
            <Button type="submit" size="sm" disabled={busyKey !== null}>{busyKey === "save-policy" ? "Saving..." : "Save policy"}</Button>
            <Button type="button" variant="outline" size="sm" disabled={busyKey !== null} onClick={() => handleRunRetention(true)}>{busyKey === "dry-run" ? "Running preview..." : "Dry-run preview"}</Button>
          </div>
        </form>
        <div className={styles.liveConfirmBox}>
          <p><strong>Live retention execution</strong>: permanently redacts eligible candidate PII and purges expired trashed sessions.</p>
          <div className={styles.liveConfirmRow}>
            <label className="field"><span>Type RUN to enable live execution</span><Input value={confirmLive} onChange={(e) => setConfirmLive(e.target.value)} placeholder="RUN" autoComplete="off" /></label>
            <Button type="button" variant="destructive" size="sm" disabled={busyKey !== null || confirmLive.trim() !== "RUN"} onClick={() => handleRunRetention(false)}>{busyKey === "live-run" ? "Executing..." : "Run live retention"}</Button>
          </div>
        </div>
        {lastRunResult && (
          <div className="panel inset stack" role="region" aria-label="Latest retention execution result">
            <div className={styles.sectionHead}>
              <strong>{lastRunResult.dry_run ? "Dry-run preview" : "Live execution"} ({fmtDate(lastRunResult.executed_at)})</strong>
              <Badge variant={lastRunResult.dry_run ? "secondary" : "warning"}>{lastRunResult.anonymized_sessions} anonymized, {lastRunResult.purged_sessions} purged</Badge>
            </div>
            <p className={styles.monoDetail}>Anonymize cutoff: {lastRunResult.cutoff_anonymize_at ?? "disabled"} | Purge cutoff: {lastRunResult.cutoff_purge_at ?? "disabled"}</p>
            {lastRunResult.anonymized_session_ids.length > 0 && (
              <p className={styles.monoDetail}>Anonymized IDs: {lastRunResult.anonymized_session_ids.slice(0, 10).join(", ")}{lastRunResult.anonymized_session_ids.length > 10 ? ` (+${lastRunResult.anonymized_session_ids.length - 10} more)` : ""}</p>
            )}
          </div>
        )}
        {runs.length === 0 ? <p className="muted">No retention runs recorded yet.</p> : (
          <div className="admin-table-wrap">
            <table className="admin-table">
              <thead><tr><th>Executed</th><th>Mode</th><th>Actor</th><th>Anonymized</th><th>Purged</th><th>Cutoffs</th></tr></thead>
              <tbody>
                {runs.map((r) => (
                  <tr key={r.id}>
                    <td>{fmtDate(r.executed_at)}</td>
                    <td><Badge variant={r.dry_run ? "secondary" : "warning"}>{r.dry_run ? "Dry run" : "Live"}</Badge></td>
                    <td className={styles.monoDetail}>{r.actor_email}</td><td>{r.anonymized_sessions}</td><td>{r.purged_sessions}</td>
                    <td className={styles.monoDetail}>A: {r.cutoff_anonymize_at ?? "off"} / P: {r.cutoff_purge_at ?? "off"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <section className="panel stack" aria-label="Single-session audit export">
        <div><h2>Session audit export</h2><p className="muted">Inspect or download the lifecycle audit timeline for a single interview session UUID.</p></div>
        <div className={styles.auditToolbar}>
          <label className="field"><span>Session UUID</span><Input value={sessionId} onChange={(e) => setSessionId(e.target.value)} placeholder="e.g. 550e8400-e29b-41d4-a716-446655440000" /></label>
          <div className={styles.actionsRow}>
            <Button type="button" variant="outline" size="sm" disabled={busyKey !== null} onClick={() => { const sid = validatedSid(); if (sid) void runAction("audit-preview", async () => { const d = await getSessionAuditPreview(sid); setAuditPreview(d); setStatusMsg(`Loaded ${d.counts.timeline_events} audit events for session ${sid.slice(0, 8)}.`) }, "Could not load session audit.") }}>{busyKey === "audit-preview" ? "Loading..." : "Preview"}</Button>
            <Button type="button" variant="outline" size="sm" disabled={busyKey !== null} onClick={() => { const sid = validatedSid(); if (sid) void runAction("audit:json", async () => setStatusMsg(`Downloaded ${await downloadSessionAudit(sid, "json")}.`), "Could not export session audit.") }}><Download size={14} aria-hidden="true" />Export JSON</Button>
            <Button type="button" variant="outline" size="sm" disabled={busyKey !== null} onClick={() => { const sid = validatedSid(); if (sid) void runAction("audit:csv", async () => setStatusMsg(`Downloaded ${await downloadSessionAudit(sid, "csv")}.`), "Could not export session audit.") }}><Download size={14} aria-hidden="true" />Export CSV</Button>
          </div>
        </div>
        {auditPreview && (
          <div className="panel inset stack">
            <div className={styles.sectionHead}>
              <strong>{auditPreview.session.candidate} ({auditPreview.session.role})</strong>
              <Badge variant={auditPreview.session.anonymization.anonymized ? "warning" : "secondary"}>{auditPreview.session.anonymization.anonymized ? "Anonymized" : "Active PII"}</Badge>
            </div>
            <p className={styles.monoDetail}>Events: {auditPreview.counts.timeline_events} (reviews {auditPreview.counts.review_events}, notes {auditPreview.counts.handoff_notes}, exports {auditPreview.counts.note_exports}, scorecards {auditPreview.counts.scorecards})</p>
            {auditPreview.timeline.length > 0 && (
              <div className="admin-table-wrap">
                <table className="admin-table">
                  <thead><tr><th>Time</th><th>Event</th><th>Actor</th><th>Detail</th></tr></thead>
                  <tbody>
                    {auditPreview.timeline.slice(0, 12).map((ev, i) => (
                      <tr key={`${ev.timestamp}-${ev.event_type}-${i}`}>
                        <td>{fmtDate(ev.timestamp)}</td><td className={styles.monoDetail}>{ev.event_type}</td>
                        <td className={styles.monoDetail}>{ev.actor || "system"}</td><td className={styles.monoDetail}>{ev.detail}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        )}
      </section>
    </div>
  )
}
