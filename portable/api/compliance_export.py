"""Zero-secret compliance posture report, session audit export, and edge header checks."""
from contextlib import closing
from pathlib import Path
import os
import sqlite3
import stat
from typing import Any, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import JSONResponse, Response

from . import access, account_db, audit_integrity, exports, model_admin, origin, rate_limit, secret_box, store
from .security_headers import SecurityHeadersMiddleware

router = APIRouter(
    prefix="/api/admin/compliance",
    tags=["admin-compliance"],
    dependencies=[Depends(model_admin.require_admin), Depends(rate_limit.limit(rate_limit.ADMIN_READ))],
)

_NO_STORE = {"Cache-Control": "no-store"}
_EMPTY_CHAIN = {"ok": True, "verifiedCount": 0, "legacyUnchainedCount": 0, "firstBrokenId": None, "headHash": None}


def _has_table(db: sqlite3.Connection, name: str, *, include_views: bool = False) -> bool:
    kind = "type IN ('table','view')" if include_views else "type='table'"
    return db.execute(f"SELECT 1 FROM sqlite_master WHERE {kind} AND name=?", (name,)).fetchone() is not None


def _count(db: sqlite3.Connection, sql: str, params: tuple[Any, ...] = ()) -> int:
    row = db.execute(sql, params).fetchone()
    return int(row[0]) if row else 0


def _collect_runtime_flags() -> dict[str, Any]:
    mode = os.getenv("INTERVIEWCHECK_ACCESS_MODE", "").strip().lower() or "none"
    try:
        acct_on = bool(access.account_enabled())
    except HTTPException:
        acct_on = False
    return {
        "access_mode": mode, "account_enabled": acct_on, "embedded_enabled": bool(access.embedded_enabled()),
        "production_mode": bool(access.production_mode()),
        "public_origin_configured": bool(os.getenv("INTERVIEWCHECK_PUBLIC_ORIGIN", "").strip()),
        "trust_proxy_client_ip": os.getenv("INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP", "").strip() == "1",
        "model_secret_source": secret_box.key_source(), "previous_keys_configured": secret_box.previous_key_count(),
    }


def _collect_review_posture(db: sqlite3.Connection) -> dict[str, Any]:
    model_audit = audit_integrity.verify_model_audit_chain(db) if _has_table(db, "model_audit") else dict(_EMPTY_CHAIN)
    csp_has = _has_table(db, "csp_violations")
    csp_total = _count(db, "SELECT COUNT(*) FROM csp_violations") if csp_has else 0
    csp_row = db.execute("SELECT received_at FROM csp_violations ORDER BY id DESC LIMIT 1").fetchone() if csp_has and csp_total else None
    rules_has, deliv_has = _has_table(db, "alert_rules"), _has_table(db, "alert_deliveries")
    ret_pol_has, ret_runs_has = _has_table(db, "retention_policies"), _has_table(db, "retention_runs")
    prow = db.execute(
        "SELECT anonymize_after_days, purge_trashed_after_days, preserve_scorecard_aggregates, enabled, updated_at "
        "FROM retention_policies WHERE id='default'"
    ).fetchone() if ret_pol_has else None
    ret_policy = {
        "anonymize_after_days": int(prow["anonymize_after_days"]), "purge_trashed_after_days": int(prow["purge_trashed_after_days"]),
        "preserve_scorecard_aggregates": bool(prow["preserve_scorecard_aggregates"]), "enabled": bool(prow["enabled"]), "updated_at": prow["updated_at"],
    } if prow is not None else None
    total_runs = _count(db, "SELECT COUNT(*) FROM retention_runs") if ret_runs_has else 0
    rrow = db.execute(
        "SELECT id, dry_run, anonymized_sessions, purged_sessions, cutoff_anonymize_at, cutoff_purge_at, executed_at "
        "FROM retention_runs ORDER BY executed_at DESC LIMIT 1"
    ).fetchone() if ret_runs_has else None
    latest_run = {
        "id": rrow["id"], "dry_run": bool(rrow["dry_run"]), "anonymized_sessions": int(rrow["anonymized_sessions"]),
        "purged_sessions": int(rrow["purged_sessions"]), "cutoff_anonymize_at": rrow["cutoff_anonymize_at"],
        "cutoff_purge_at": rrow["cutoff_purge_at"], "executed_at": rrow["executed_at"],
    } if rrow is not None else None
    envelopes = {"v1": 0, "v2": 0, "none": 0, "other": 0}
    models_total = models_enabled = 0
    if _has_table(db, "connected_models"):
        for mrow in db.execute("SELECT enabled, encrypted_api_key FROM connected_models"):
            models_total += 1
            models_enabled += int(bool(mrow["enabled"]))
            token = mrow["encrypted_api_key"]
            if not token:
                envelopes["none"] += 1
            else:
                try:
                    ver, _ = secret_box.token_key_info(token)
                    envelopes[ver if ver in ("v1", "v2") else "other"] += 1
                except secret_box.SecretBoxError:
                    envelopes["other"] += 1
    anon_has = _has_table(db, "session_anonymizations")
    return {
        "model_audit": model_audit,
        "csp_violations": {"total": csp_total, "latest_received_at": csp_row[0] if csp_row else None},
        "alert_rules": {
            "total": _count(db, "SELECT COUNT(*) FROM alert_rules") if rules_has else 0,
            "enabled": _count(db, "SELECT COUNT(*) FROM alert_rules WHERE enabled=1") if rules_has else 0,
            "deliveries_total": _count(db, "SELECT COUNT(*) FROM alert_deliveries") if deliv_has else 0,
            "deliveries_failed": _count(db, "SELECT COUNT(*) FROM alert_deliveries WHERE ok=0") if deliv_has else 0,
        },
        "retention": {"policy_table_present": ret_pol_has, "runs_table_present": ret_runs_has,
                      "policy": ret_policy, "total_runs": total_runs, "latest_run": latest_run},
        "models": {"total": models_total, "enabled": models_enabled, "encryption_envelopes": envelopes},
        "sessions": {
            "total": _count(db, "SELECT COUNT(*) FROM sessions") if _has_table(db, "sessions") else 0,
            "active": _count(db, "SELECT COUNT(*) FROM active_sessions") if _has_table(db, "active_sessions", include_views=True) else 0,
            "trashed": _count(db, "SELECT COUNT(*) FROM session_trash") if _has_table(db, "session_trash") else 0,
            "anonymized": _count(db, "SELECT COUNT(*) FROM session_anonymizations") if anon_has else 0,
            "anonymization_table_present": anon_has,
        },
    }


def _collect_access_posture() -> dict[str, Any]:
    empty = {
        "available": False, "schema_version": None, "audit_chain": {"available": False, **_EMPTY_CHAIN},
        "users": {"total": 0, "admins": 0, "disabled": 0}, "totp_enrolled": 0, "api_tokens": {"total": 0, "active": 0}, "active_sessions": 0,
    }
    try:
        path = account_db.database()
    except HTTPException:
        return empty
    if not path.is_file():
        return empty
    try:
        with closing(sqlite3.connect(f"file:{path.resolve()}?mode=ro", uri=True, timeout=2)) as adb:
            adb.row_factory = sqlite3.Row
            now_ms, chain = account_db.now(), dict(empty["audit_chain"])
            if _has_table(adb, "audit_log"):
                cols = {r[1] for r in adb.execute("PRAGMA table_info(audit_log)")}
                chain = {"available": True, **account_db.verify_audit_chain(adb)} if {"prev_hash", "entry_hash"}.issubset(cols) else {
                    "available": True, "ok": True, "verifiedCount": 0,
                    "legacyUnchainedCount": _count(adb, "SELECT COUNT(*) FROM audit_log"), "firstBrokenId": None, "headHash": None,
                }
            users = {
                "total": _count(adb, "SELECT COUNT(*) FROM users"), "admins": _count(adb, "SELECT COUNT(*) FROM users WHERE role='admin'"),
                "disabled": _count(adb, "SELECT COUNT(*) FROM users WHERE disabled=1"),
            } if _has_table(adb, "users") else empty["users"]
            tok_has = _has_table(adb, "api_tokens")
            return {
                "available": True, "schema_version": _count(adb, "PRAGMA user_version"), "audit_chain": chain, "users": users,
                "totp_enrolled": _count(adb, "SELECT COUNT(*) FROM user_totp WHERE enabled=1") if _has_table(adb, "user_totp") else 0,
                "api_tokens": {
                    "total": _count(adb, "SELECT COUNT(*) FROM api_tokens") if tok_has else 0,
                    "active": _count(adb, "SELECT COUNT(*) FROM api_tokens WHERE revoked_at IS NULL AND (expires_at IS NULL OR expires_at>?)", (now_ms,)) if tok_has else 0,
                },
                "active_sessions": _count(adb, "SELECT COUNT(*) FROM sessions WHERE revoked_at IS NULL AND expires_at>?", (now_ms,)) if _has_table(adb, "sessions") else 0,
            }
    except sqlite3.Error:
        return empty


def _render_report_markdown(report: dict[str, Any]) -> str:
    rt, ac, rev = report["runtime"], report["access_db"], report["sessions"]
    env_c, ret = report["models"]["encryption_envelopes"], report["retention"]
    latest = ret["latest_run"]
    return "\n".join([
        "# InterviewCheck Compliance Report", "", f"Generated at: {report['generated_at']}", "", "## Runtime Boundary",
        f"- Access mode: {rt['access_mode']} (account_enabled={rt['account_enabled']}, production_mode={rt['production_mode']})",
        f"- Public origin configured: {rt['public_origin_configured']} (trust_proxy_client_ip={rt['trust_proxy_client_ip']})",
        f"- Model secret key source: {rt['model_secret_source']} (previous_keys_configured={rt['previous_keys_configured']})", "", "## Audit Hash Chains",
        f"- Fallback model_audit ok: {report['audit_chains']['model_fallback']['ok']} (verified={report['audit_chains']['model_fallback']['verifiedCount']}, legacy={report['audit_chains']['model_fallback']['legacyUnchainedCount']})",
        f"- Access audit_log available: {report['audit_chains']['access']['available']}, ok: {report['audit_chains']['access']['ok']} (verified={report['audit_chains']['access']['verifiedCount']}, legacy={report['audit_chains']['access']['legacyUnchainedCount']})", "",
        "## Security Signals and Credentials",
        f"- CSP violations stored: {report['csp_violations']['total']}",
        f"- Alert rules: {report['alert_rules']['enabled']}/{report['alert_rules']['total']} enabled (deliveries={report['alert_rules']['deliveries_total']}, failed={report['alert_rules']['deliveries_failed']})",
        f"- Connected models: {report['models']['enabled']}/{report['models']['total']} enabled (envelopes v1={env_c['v1']}, v2={env_c['v2']}, none={env_c['none']}, other={env_c['other']})",
        f"- Access DB (schema v{ac['schema_version']}): users={ac['users']['total']} (admins={ac['users']['admins']}, disabled={ac['users']['disabled']}), TOTP enrolled={ac['totp_enrolled']}, active API tokens={ac['api_tokens']['active']}/{ac['api_tokens']['total']}", "",
        "## Retention and Sessions",
        f"- Sessions: total={rev['total']}, active={rev['active']}, anonymized={rev['anonymized']}, trashed={rev['trashed']}",
        f"- Retention policy configured: {ret['policy'] is not None} (runs={ret['total_runs']}, latest={latest['executed_at'] if latest else 'none'})", "",
    ])


@router.get("/report")
def compliance_report(format: Literal["json", "markdown"] = Query(default="json")):
    review = {
        "model_audit": dict(_EMPTY_CHAIN), "csp_violations": {"total": 0, "latest_received_at": None},
        "alert_rules": {"total": 0, "enabled": 0, "deliveries_total": 0, "deliveries_failed": 0},
        "retention": {"policy_table_present": False, "runs_table_present": False, "policy": None, "total_runs": 0, "latest_run": None},
        "models": {"total": 0, "enabled": 0, "encryption_envelopes": {"v1": 0, "v2": 0, "none": 0, "other": 0}},
        "sessions": {"total": 0, "active": 0, "trashed": 0, "anonymized": 0, "anonymization_table_present": False},
    }
    if store.db_path().is_file():
        with store.connection() as db:
            review = _collect_review_posture(db)
    access_posture = _collect_access_posture()
    payload = {
        "format": "interviewcheck.compliance_report", "generated_at": store.timestamp(), "runtime": _collect_runtime_flags(),
        "audit_chains": {"model_fallback": review["model_audit"], "access": access_posture["audit_chain"]},
        "csp_violations": review["csp_violations"], "alert_rules": review["alert_rules"], "retention": review["retention"],
        "models": review["models"], "sessions": review["sessions"],
        "access_db": {k: v for k, v in access_posture.items() if k != "audit_chain"},
    }
    if format == "markdown":
        return Response(content=_render_report_markdown(payload), media_type="text/markdown; charset=utf-8",
                        headers={**_NO_STORE, "Content-Disposition": 'attachment; filename="compliance-report.md"'})
    return JSONResponse(content=payload, headers=_NO_STORE)


@router.get("/sessions/{sid}/audit")
def session_audit_export(sid: UUID, format: Literal["json", "csv"] = Query(default="json")):
    sid_str = str(sid)
    with store.connection() as db:
        summary = store.get_summary(db, sid_str, include_trashed=True)
        trow = db.execute("SELECT trashed_at, operation_version FROM session_trash WHERE session_id=?", (sid_str,)).fetchone() if _has_table(db, "session_trash") else None
        trashed = {"trashed_at": trow["trashed_at"], "operation_version": trow["operation_version"]} if trow else None
        arow = db.execute("SELECT anonymized_at, anonymized_by FROM session_anonymizations WHERE session_id=?", (sid_str,)).fetchone() if _has_table(db, "session_anonymizations") else None
        anon = {"anonymized": True, "anonymized_at": arow["anonymized_at"], "anonymized_by": arow["anonymized_by"]} if arow else {"anonymized": False, "anonymized_at": None, "anonymized_by": None}
        timeline: list[dict[str, str]] = [{"timestamp": summary["created_at"], "event_type": "session.created", "actor": "", "target_id": sid_str,
                                           "detail": f"role={summary['role']} consent={summary['consent']}"}]
        if summary.get("ended_at"):
            timeline.append({"timestamp": summary["ended_at"], "event_type": "session.finished", "actor": "", "target_id": sid_str, "detail": "Interview finished"})
        if trashed:
            timeline.append({"timestamp": trashed["trashed_at"], "event_type": "session.trashed", "actor": "", "target_id": sid_str, "detail": f"operation_version={trashed['operation_version']}"})
        if anon["anonymized"]:
            timeline.append({"timestamp": str(anon["anonymized_at"]), "event_type": "session.anonymized", "actor": str(anon["anonymized_by"]), "target_id": sid_str, "detail": "PII redacted"})
        counts = {"review_events": 0, "handoff_notes": 0, "note_exports": 0, "scorecards": 0}
        if _has_table(db, "answer_review_events"):
            for r in db.execute("SELECT answer_id, reviewer_email, previous_disposition, disposition, created_at FROM answer_review_events WHERE session_id=? ORDER BY created_at ASC, id ASC", (sid_str,)):
                counts["review_events"] += 1
                timeline.append({"timestamp": r["created_at"], "event_type": "answer.review", "actor": r["reviewer_email"], "target_id": r["answer_id"], "detail": f"{r['previous_disposition']} -> {r['disposition']}"})
        if _has_table(db, "session_handoff_notes"):
            for r in db.execute("SELECT id, author_email, category, created_at FROM session_handoff_notes WHERE session_id=? ORDER BY created_at ASC, id ASC", (sid_str,)):
                counts["handoff_notes"] += 1
                timeline.append({"timestamp": r["created_at"], "event_type": "handoff_note.created", "actor": r["author_email"], "target_id": r["id"], "detail": f"category={r['category']}"})
        if _has_table(db, "note_exports"):
            for r in db.execute("SELECT id, provider, remote_id, state, created_at FROM note_exports WHERE session_id=? ORDER BY created_at ASC, id ASC", (sid_str,)):
                counts["note_exports"] += 1
                timeline.append({"timestamp": r["created_at"], "event_type": "note.export", "actor": "", "target_id": r["id"], "detail": f"provider={r['provider']} state={r['state']} remote_id={r['remote_id']}"})
        if _has_table(db, "session_scorecards"):
            for r in db.execute("SELECT criterion_id, weight, rating, updated_by, updated_at FROM session_scorecards WHERE session_id=? ORDER BY updated_at ASC, criterion_id ASC", (sid_str,)):
                counts["scorecards"] += 1
                timeline.append({"timestamp": r["updated_at"], "event_type": "scorecard.updated", "actor": r["updated_by"], "target_id": r["criterion_id"], "detail": f"rating={r['rating']}/5 weight={r['weight']}"})
    timeline.sort(key=lambda item: (item["timestamp"], item["event_type"], item["target_id"]))
    counts["timeline_events"] = len(timeline)
    if format == "csv":
        rows = ["\ufeff" + exports.csv_row(["session_id", "timestamp", "event_type", "actor", "target_id", "detail"])]
        rows.extend(exports.csv_row([sid_str, ev["timestamp"], ev["event_type"], ev["actor"], ev["target_id"], ev["detail"]]) for ev in timeline)
        return Response(content="".join(rows), media_type="text/csv; charset=utf-8",
                        headers={**_NO_STORE, "Content-Disposition": f'attachment; filename="session-audit-{sid_str}.csv"'})
    return JSONResponse(
        content={"format": "interviewcheck.session_audit", "generated_at": store.timestamp(),
                 "session": {"id": summary["id"], "candidate": summary["candidate"], "role": summary["role"], "role_id": summary.get("role_id"),
                             "consent": summary["consent"], "created_at": summary["created_at"], "ended_at": summary.get("ended_at"),
                             "answer_count": summary["answer_count"], "trashed": trashed, "anonymization": anon},
                 "counts": counts, "timeline": timeline},
        headers=_NO_STORE,
    )


@router.get("/headers-check")
def compliance_headers_check(request: Request) -> JSONResponse:
    checks: list[dict[str, str]] = []
    headers = request.headers
    expected_origin = origin.browser_origin(headers, request.url.scheme)
    host_ok = origin.authority(headers.get("host", "").lower()) is not None and expected_origin is not None
    checks.append({"id": "host_header", "status": "pass" if host_ok else "fail",
                   "detail": f"Resolved browser origin: {expected_origin}" if host_ok else "Host or forwarded origin failed boundary check."})
    fwd_hosts, client_ips = headers.getlist("x-forwarded-host"), headers.getlist("x-interviewcheck-client-ip")
    dup_proxy = len(fwd_hosts) > 1 or any("," in v for v in fwd_hosts) or len(client_ips) > 1 or any("," in v for v in client_ips)
    checks.append({"id": "duplicate_proxy_headers", "status": "fail" if dup_proxy else "pass",
                   "detail": "Multiple or comma-joined proxy headers detected." if dup_proxy else "No duplicate proxy headers present."})
    trust_ip = os.getenv("INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP", "").strip() == "1"
    pub_raw = os.getenv("INTERVIEWCHECK_PUBLIC_ORIGIN", "").strip()
    checks.append({"id": "client_ip_trust_boundary", "status": "warn" if (trust_ip and not pub_raw) else "pass",
                   "detail": "INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP=1 without INTERVIEWCHECK_PUBLIC_ORIGIN." if (trust_ip and not pub_raw) else "Proxy client IP trust matches public origin configuration."})
    try:
        pub = origin.validate_runtime_exposure()
        checks.append({"id": "runtime_exposure", "status": "pass", "detail": f"Public origin: {pub}" if pub else "Loopback-only runtime exposure validated."})
    except ValueError as exc:
        checks.append({"id": "runtime_exposure", "status": "fail", "detail": str(exc)})
    src = secret_box.key_source()
    key_status, key_detail = "pass", f"Model encryption key source: {src}."
    if src == "file":
        kpath = Path(os.getenv("INTERVIEWCHECK_MODEL_SECRET_FILE", "").strip() or store.db_path().with_name(".model_secret.key"))
        if os.name != "nt" and kpath.is_file() and (stat.S_IMODE(kpath.stat().st_mode) & 0o077) != 0:
            key_status, key_detail = "fail", "Model secret key file permissions exceed 0600."
    checks.append({"id": "model_secret_key", "status": key_status, "detail": key_detail})
    has_sec_mw = SecurityHeadersMiddleware in [getattr(m, "cls", None) for m in getattr(request.app, "user_middleware", [])]
    checks.append({"id": "security_headers_middleware", "status": "pass" if has_sec_mw else "warn",
                   "detail": "SecurityHeadersMiddleware active on FastAPI app." if has_sec_mw else "SecurityHeadersMiddleware not detected on app wrapper."})
    return JSONResponse(content={"ok": all(c["status"] != "fail" for c in checks), "checked_at": store.timestamp(), "checks": checks}, headers=_NO_STORE)
