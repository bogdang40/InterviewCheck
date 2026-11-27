import { AdminApiError, adminRequest } from "./adminModels"
import { downloadResponse } from "./download"
import { send } from "./http"

export type AuditChainSummary = {
  available?: boolean; ok: boolean; verifiedCount: number; legacyUnchainedCount: number
  firstBrokenId: string | number | null; headHash: string | null
}

export type RetentionPolicy = {
  id?: string; anonymize_after_days: number; purge_trashed_after_days: number
  preserve_scorecard_aggregates: boolean; enabled: boolean; updated_by?: string; updated_at: string
}

export type RetentionRun = {
  id: string; dry_run: boolean; actor_email: string; anonymized_sessions: number; purged_sessions: number
  cutoff_anonymize_at: string | null; cutoff_purge_at: string | null; executed_at: string
}

export type RetentionState = { policy: RetentionPolicy; runs: RetentionRun[]; withheld_interviews?: number }

export type RetentionRunResult = {
  dry_run: boolean; anonymized_sessions: number; purged_sessions: number
  anonymized_session_ids: string[]; purged_session_ids: string[]
  cutoff_anonymize_at: string | null; cutoff_purge_at: string | null
  executed_at: string; run: RetentionRun; policy: RetentionPolicy
}

export type ComplianceReport = {
  format: string; generated_at: string
  runtime: {
    access_mode: string; account_enabled: boolean; embedded_enabled: boolean; production_mode: boolean
    public_origin_configured: boolean; trust_proxy_client_ip: boolean
    model_secret_source: string; previous_keys_configured: number
  }
  audit_chains: { model_fallback: AuditChainSummary; access: AuditChainSummary }
  csp_violations: { total: number; latest_received_at: string | null }
  alert_rules: { total: number; enabled: number; deliveries_total: number; deliveries_failed: number }
  retention: {
    policy_table_present: boolean; runs_table_present: boolean; policy: RetentionPolicy | null
    total_runs: number; latest_run: Omit<RetentionRun, "actor_email"> | null
  }
  models: { total: number; enabled: number; encryption_envelopes: { v1: number; v2: number; none: number; other: number } }
  sessions: { total: number; active: number; trashed: number; anonymized: number; anonymization_table_present: boolean }
  access_db: {
    available: boolean; schema_version: number | null; users: { total: number; admins: number; disabled: number }
    totp_enrolled: number; api_tokens: { total: number; active: number }; active_sessions: number
  }
}

export type HeaderCheckItem = { id: string; status: string; detail: string }
export type HeadersCheckResponse = { ok: boolean; checked_at: string; checks: HeaderCheckItem[] }
export type SessionAuditEvent = { timestamp: string; event_type: string; actor: string; target_id: string; detail: string }

export type SessionAuditResponse = {
  format: string; generated_at: string
  session: {
    id: string; candidate: string; role: string; role_id: string | null; consent: number | boolean
    created_at: string; ended_at: string | null; answer_count: number
    trashed: { trashed_at: string; operation_version: string } | null
    anonymization: { anonymized: boolean; anonymized_at: string | null; anonymized_by: string | null }
  }
  counts: { review_events: number; handoff_notes: number; note_exports: number; scorecards: number; timeline_events: number }
  timeline: SessionAuditEvent[]
}

async function downloadComplianceFile(url: string, fallback: string): Promise<string> {
  return downloadResponse(await send(url, { errorType: AdminApiError }), fallback)
}

export const getComplianceReport = () => adminRequest<ComplianceReport>("/api/admin/compliance/report?format=json")
export const downloadComplianceReport = (format: "json" | "markdown") => {
  const ext = format === "markdown" ? "md" : "json"
  return downloadComplianceFile(`/api/admin/compliance/report?format=${format}`, `compliance-report.${ext}`)
}
export const runHeadersCheck = () => adminRequest<HeadersCheckResponse>("/api/admin/compliance/headers-check")
export const getRetentionState = () => adminRequest<RetentionState>("/api/admin/compliance/retention")

export async function updateRetentionPolicy(payload: {
  anonymize_after_days: number; purge_trashed_after_days: number
  preserve_scorecard_aggregates: boolean; enabled: boolean
}): Promise<RetentionPolicy> {
  const res = await adminRequest<{ policy: RetentionPolicy }>("/api/admin/compliance/retention", {
    method: "PUT", body: JSON.stringify(payload),
  })
  return res.policy
}

export const runRetentionJob = (dryRun: boolean) =>
  adminRequest<RetentionRunResult>("/api/admin/compliance/retention/run", {
    method: "POST", body: JSON.stringify({ dry_run: dryRun }),
  })

export const getSessionAuditPreview = (sid: string) =>
  adminRequest<SessionAuditResponse>(`/api/admin/compliance/sessions/${encodeURIComponent(sid)}/audit?format=json`)

export const downloadSessionAudit = (sid: string, format: "json" | "csv") =>
  downloadComplianceFile(
    `/api/admin/compliance/sessions/${encodeURIComponent(sid)}/audit?format=${format}`,
    `session-audit-${sid}.${format}`,
  )
