"""Secret-free runtime diagnostic bundle export for administrators."""
from datetime import datetime, timedelta, timezone
import json
import sqlite3
from typing import Any

from fastapi import APIRouter, Depends, Response

from . import health_probes, model_admin, model_budgets, model_circuit, model_registry, rate_limit, store
from .error_sanitizer import sanitize_error_text

router = APIRouter(prefix="/api/admin/diagnostics", tags=["admin-diagnostics"])
_READ = [Depends(model_admin.require_admin), Depends(rate_limit.limit(rate_limit.ADMIN_READ))]
_SECRET_KEYS = frozenset({
    "encrypted_api_key", "encrypted_signing_secret", "token_hash",
    "api_key", "signing_secret", "totp_secret", "password_hash",
})
_SLA_KEYS = (
    "total_checks", "ok_count", "error_count", "p50_latency_ms", "p95_latency_ms",
    "p99_latency_ms", "error_rate_pct", "sla_target_ms", "sla_compliant",
)


def _has_table(db: sqlite3.Connection, name: str) -> bool:
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def _parse_utc(raw: str | None) -> datetime | None:
    if not raw:
        return None
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00") if raw.endswith("Z") else raw)
    except ValueError:
        return None
    return dt.replace(tzinfo=timezone.utc) if (dt.tzinfo is None or dt.utcoffset() is None) else dt.astimezone(timezone.utc)


def _probes_report() -> dict[str, Any]:
    checks = {
        "review_db": health_probes._check_review_db(),
        "access_db": health_probes._check_access_db(),
        "secret_box": health_probes._check_secret_box(),
        "web_bundle": health_probes._check_web_bundle(),
    }
    ok = (
        checks["review_db"] == "ok"
        and checks["access_db"] in {"ok", "skipped"}
        and checks["secret_box"] == "ok"
        and checks["web_bundle"] == "ok"
    )
    return {"ok": ok, "checks": checks}


def _sanitize_opt(text: str | None, fallback: str) -> str | None:
    return sanitize_error_text(text, fallback, max_len=300) if text else None


def _collect_models(db: sqlite3.Connection) -> list[dict[str, Any]]:
    if not _has_table(db, "connected_models"):
        return []
    rows = db.execute(
        "SELECT * FROM connected_models ORDER BY capability ASC, is_default DESC, updated_at DESC, id ASC"
    ).fetchall()
    has_circuit, has_checks = _has_table(db, "model_circuit_state"), _has_table(db, "model_health_checks")
    has_usage = _has_table(db, "model_usage_daily")

    sla_models: dict[str, dict[str, Any]] = {}
    if has_circuit and has_checks:
        sla_models = model_circuit.compute_sla(db).get("models", {})
    elif has_circuit:
        for crow in db.execute("SELECT * FROM model_circuit_state").fetchall():
            sla_models[crow["model_id"]] = {"circuit": model_circuit._circuit_dict(crow, crow["model_id"])}

    usage_models = model_budgets.fleet_usage_summary(db).get("models", {}) if has_usage else {}
    checks_by_model: dict[str, list[dict[str, Any]]] = {}
    if has_checks:
        for row in rows:
            mid = row["id"]
            crows = db.execute(
                "SELECT source, ok, http_status, latency_ms, error, checked_at FROM model_health_checks "
                "WHERE model_id=? ORDER BY checked_at DESC, id DESC LIMIT 10",
                (mid,),
            ).fetchall()
            checks_by_model[mid] = [
                {
                    "source": c["source"], "ok": bool(c["ok"]), "http_status": c["http_status"],
                    "latency_ms": c["latency_ms"], "checked_at": c["checked_at"],
                    "error": _sanitize_opt(c["error"], "Provider check failed."),
                }
                for c in crows
            ]

    out: list[dict[str, Any]] = []
    for row in rows:
        mid = row["id"]
        dto = model_registry.public_model(row)
        dto["last_error"] = _sanitize_opt(dto.get("last_error"), "Provider call failed.")
        sla_entry = sla_models.get(mid)
        circuit = dict(sla_entry["circuit"]) if sla_entry and "circuit" in sla_entry else model_circuit._circuit_dict(None, mid)
        circuit["last_failure_reason"] = _sanitize_opt(circuit.get("last_failure_reason"), "Provider call failed.")
        dto["circuit"] = circuit
        dto["sla"] = {k: sla_entry[k] for k in _SLA_KEYS} if sla_entry and "total_checks" in sla_entry else None
        dto["usage"] = usage_models.get(mid)
        dto["recent_checks"] = checks_by_model.get(mid, [])
        out.append(dto)
    return out


def _collect_prompt_templates(db: sqlite3.Connection) -> dict[str, Any]:
    if not _has_table(db, "prompt_templates"):
        return {"table_present": False, "total_slots": 0, "slots": {}}
    version_counts: dict[str, int] = {}
    if _has_table(db, "prompt_template_versions"):
        for r in db.execute("SELECT template_id, COUNT(*) AS cnt FROM prompt_template_versions GROUP BY template_id"):
            version_counts[r["template_id"]] = int(r["cnt"])
    slots: dict[str, dict[str, Any]] = {}
    for row in db.execute("SELECT id, slot, active_version, updated_at FROM prompt_templates ORDER BY slot ASC").fetchall():
        slots[row["slot"]] = {
            "active_version": int(row["active_version"]),
            "version_count": version_counts.get(row["id"], 1),
            "updated_at": row["updated_at"],
        }
    return {"table_present": True, "total_slots": len(slots), "slots": slots}


def _collect_alerts(db: sqlite3.Connection, now_utc: datetime) -> dict[str, Any]:
    rule_count = enabled_rule_count = 0
    if _has_table(db, "alert_rules"):
        rule_count = int(db.execute("SELECT COUNT(*) FROM alert_rules").fetchone()[0])
        enabled_rule_count = int(db.execute("SELECT COUNT(*) FROM alert_rules WHERE enabled=1").fetchone()[0])
    d_total = d_ok = d_failed = 0
    if _has_table(db, "alert_deliveries"):
        cutoff = now_utc - timedelta(hours=24)
        for row in db.execute("SELECT ok, delivered_at FROM alert_deliveries"):
            dt = _parse_utc(row["delivered_at"])
            if dt is None or dt < cutoff:
                continue
            d_total += 1
            if row["ok"] == 1:
                d_ok += 1
            else:
                d_failed += 1
    return {
        "rule_count": rule_count, "enabled_rule_count": enabled_rule_count,
        "deliveries_24h_total": d_total, "deliveries_24h_ok": d_ok, "deliveries_24h_failed": d_failed,
    }


def _collect_csp_summary(db: sqlite3.Connection) -> dict[str, Any]:
    if not _has_table(db, "csp_violations"):
        return {"table_present": False, "total": 0, "top_directives": []}
    total = int(db.execute("SELECT COUNT(*) FROM csp_violations").fetchone()[0])
    rows = db.execute(
        "SELECT violated_directive, COUNT(*) AS cnt FROM csp_violations "
        "GROUP BY violated_directive ORDER BY cnt DESC, violated_directive ASC LIMIT 10"
    ).fetchall()
    return {
        "table_present": True,
        "total": total,
        "top_directives": [{"directive": r["violated_directive"], "count": int(r["cnt"])} for r in rows],
    }


def _scrub_secret_keys(value: Any) -> Any:
    if isinstance(value, dict):
        return {k: _scrub_secret_keys(v) for k, v in value.items() if k not in _SECRET_KEYS}
    if isinstance(value, list):
        return [_scrub_secret_keys(item) for item in value]
    return value


@router.get("/bundle", dependencies=_READ)
def export_diagnostics_bundle(actor: dict = Depends(model_admin.require_admin)):
    now_utc = datetime.now(timezone.utc)
    post_commit: list = []
    with store.connection(write=True) as db:
        bundle = _scrub_secret_keys({
            "generated_at": now_utc.isoformat(),
            "probes": _probes_report(),
            "models": _collect_models(db),
            "prompt_templates": _collect_prompt_templates(db),
            "alerts": _collect_alerts(db, now_utc),
            "csp_summary": _collect_csp_summary(db),
        })
        if _has_table(db, "model_audit") or model_admin.account_db.database().is_file():
            model_admin._record_audit(
                db, actor=actor, action="admin.diagnostics.bundle_export", model_uuid="diagnostics",
                details={"model_count": len(bundle["models"]), "alert_rule_count": bundle["alerts"]["rule_count"],
                         "csp_total": bundle["csp_summary"]["total"]},
                post_commit=post_commit,
            )
    model_admin._flush_account_audits(post_commit)
    return Response(
        content=json.dumps(bundle, indent=2, ensure_ascii=False),
        media_type="application/json; charset=utf-8",
        headers={"Cache-Control": "no-store", "Content-Disposition": 'attachment; filename="interviewcheck-diagnostics.json"'},
    )
