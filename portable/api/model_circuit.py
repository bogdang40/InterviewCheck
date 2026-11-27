"""Per-model consecutive-failure circuit breaker state machine and SLA percentile analytics."""
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
import math
import sqlite3
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, Request
from pydantic import Field, model_validator

from . import model_registry, rate_limit, secret_box, sql_script, store
from .error_sanitizer import sanitize_error_text
from .models import Input

DEFAULT_CONSECUTIVE_THRESHOLD = 3
DEFAULT_COOLDOWN_SECONDS = 60
DEFAULT_SLA_TARGET_MS = 2500

SCHEMA = """
CREATE TABLE IF NOT EXISTS model_circuit_state (
 model_id TEXT PRIMARY KEY REFERENCES connected_models(id) ON DELETE CASCADE,
 state TEXT NOT NULL DEFAULT 'closed' CHECK(state IN ('closed','open','half_open')),
 failure_streak INTEGER NOT NULL DEFAULT 0,
 consecutive_threshold INTEGER NOT NULL DEFAULT 3,
 cooldown_seconds INTEGER NOT NULL DEFAULT 60,
 sla_target_ms INTEGER NOT NULL DEFAULT 2500,
 opened_at TEXT, next_retry_at TEXT, half_open_probe_until TEXT, last_failure_reason TEXT, updated_at TEXT NOT NULL
);
"""

router = APIRouter(prefix="/api/admin/models", tags=["model-circuit"])


@dataclass(frozen=True)
class CircuitDecision:
    allowed: bool
    state: str
    retry_after_s: int = 0
    probe_until: str | None = field(default=None, compare=False)


class CircuitPolicyInput(Input):
    consecutive_threshold: int | None = Field(default=None, ge=1, le=20)
    cooldown_seconds: int | None = Field(default=None, ge=5, le=3600)
    sla_target_ms: int | None = Field(default=None, ge=100, le=60000)

    @model_validator(mode="after")
    def validate_patch(self):
        if not self.model_fields_set:
            raise ValueError("Specify at least one circuit policy field to update.")
        for field in ("consecutive_threshold", "cooldown_seconds", "sla_target_ms"):
            if field in self.model_fields_set and getattr(self, field) is None:
                raise ValueError(f"{field} cannot be null.")
        return self


def migrate(db: sqlite3.Connection) -> None:
    sql_script.execute(db, SCHEMA)
    columns = {row[1] for row in db.execute("PRAGMA table_info(model_circuit_state)")}
    if "half_open_probe_until" not in columns:
        db.execute("ALTER TABLE model_circuit_state ADD COLUMN half_open_probe_until TEXT")


def _to_utc(value: datetime | str | None, *, default_now: bool = False) -> datetime | None:
    if value is None:
        return datetime.now(timezone.utc) if default_now else None
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value)
        except ValueError:
            return datetime.now(timezone.utc) if default_now else None
    else:
        parsed = value
    return parsed.replace(tzinfo=timezone.utc) if parsed.tzinfo is None else parsed.astimezone(timezone.utc)


def _circuit_dict(row: sqlite3.Row | None, model_uuid: str, *, updated_at: str | None = None) -> dict[str, Any]:
    if row is None:
        return {
            "model_id": model_uuid, "state": "closed", "failure_streak": 0,
            "consecutive_threshold": DEFAULT_CONSECUTIVE_THRESHOLD,
            "cooldown_seconds": DEFAULT_COOLDOWN_SECONDS, "sla_target_ms": DEFAULT_SLA_TARGET_MS,
            "opened_at": None, "next_retry_at": None, "half_open_probe_until": None,
            "last_failure_reason": None, "updated_at": updated_at,
        }
    return {
        "model_id": row["model_id"], "state": row["state"], "failure_streak": int(row["failure_streak"]),
        "consecutive_threshold": int(row["consecutive_threshold"]),
        "cooldown_seconds": int(row["cooldown_seconds"]), "sla_target_ms": int(row["sla_target_ms"]),
        "opened_at": row["opened_at"], "next_retry_at": row["next_retry_at"],
        "half_open_probe_until": row["half_open_probe_until"],
        "last_failure_reason": row["last_failure_reason"], "updated_at": row["updated_at"],
    }


def _ensure_row(db: sqlite3.Connection, model_uuid: str, now_iso: str) -> sqlite3.Row | None:
    row = db.execute("SELECT * FROM model_circuit_state WHERE model_id=?", (model_uuid,)).fetchone()
    if row is not None:
        return row
    if db.execute("SELECT 1 FROM connected_models WHERE id=?", (model_uuid,)).fetchone() is None:
        return None
    db.execute(
        "INSERT OR IGNORE INTO model_circuit_state(model_id,state,failure_streak,consecutive_threshold,"
        "cooldown_seconds,sla_target_ms,updated_at) VALUES (?,'closed',0,?,?,?,?)",
        (model_uuid, DEFAULT_CONSECUTIVE_THRESHOLD, DEFAULT_COOLDOWN_SECONDS, DEFAULT_SLA_TARGET_MS, now_iso),
    )
    return db.execute("SELECT * FROM model_circuit_state WHERE model_id=?", (model_uuid,)).fetchone()


def _half_open_lease_seconds(cooldown_seconds: int | None) -> int:
    return min(max(int(cooldown_seconds or DEFAULT_COOLDOWN_SECONDS), 5), 30)


def _redact_model_secret(db: sqlite3.Connection, model_uuid: str, text: str, *, secret: str | None = None) -> str:
    cleaned = text
    candidates: list[str] = []
    if isinstance(secret, str) and len(secret) >= 4:
        candidates.append(secret)
    try:
        m_row = db.execute("SELECT encrypted_api_key FROM connected_models WHERE id=?", (model_uuid,)).fetchone()
        enc = m_row["encrypted_api_key"] if m_row is not None else None
        if enc:
            raw_key = secret_box.decrypt_secret(enc, aad=model_uuid)
            if isinstance(raw_key, str) and len(raw_key) >= 4:
                candidates.append(raw_key)
    except (sqlite3.Error, secret_box.SecretBoxError):
        pass
    for value in candidates:
        if value in cleaned:
            cleaned = cleaned.replace(value, "[REDACTED]")
    return cleaned


def can_execute(db: sqlite3.Connection, model_uuid: str, *, now: datetime | str | None = None, claim: bool = True) -> CircuitDecision:
    row = db.execute(
        "SELECT state, cooldown_seconds, next_retry_at, half_open_probe_until FROM model_circuit_state WHERE model_id=?",
        (model_uuid,),
    ).fetchone()
    if row is None or row["state"] == "closed":
        return CircuitDecision(allowed=True, state="closed", retry_after_s=0)
    now_dt = _to_utc(now, default_now=True)
    assert now_dt is not None
    probe_until = (now_dt + timedelta(seconds=_half_open_lease_seconds(row["cooldown_seconds"]))).isoformat()
    if row["state"] == "half_open":
        lease_dt = _to_utc(row["half_open_probe_until"])
        if lease_dt is not None and now_dt < lease_dt:
            return CircuitDecision(
                allowed=False,
                state="half_open",
                retry_after_s=max(1, math.ceil((lease_dt - now_dt).total_seconds())),
            )
        if not claim:
            return CircuitDecision(True, "half_open")
        cur = db.execute(
            "UPDATE model_circuit_state SET half_open_probe_until=?, updated_at=? "
            "WHERE model_id=? AND state='half_open' AND (half_open_probe_until IS NULL OR half_open_probe_until=?)",
            (probe_until, now_dt.isoformat(), model_uuid, row["half_open_probe_until"]),
        )
        if cur.rowcount == 1:
            return CircuitDecision(allowed=True, state="half_open", retry_after_s=0, probe_until=probe_until)
        return CircuitDecision(allowed=False, state="half_open", retry_after_s=1)
    retry_dt = _to_utc(row["next_retry_at"])
    if retry_dt is not None and now_dt < retry_dt:
        return CircuitDecision(allowed=False, state="open", retry_after_s=max(1, math.ceil((retry_dt - now_dt).total_seconds())))
    if not claim:
        return CircuitDecision(True, "half_open")
    cur = db.execute(
        "UPDATE model_circuit_state SET state='half_open', half_open_probe_until=?, updated_at=? "
        "WHERE model_id=? AND state='open'",
        (probe_until, now_dt.isoformat(), model_uuid),
    )
    if cur.rowcount == 1:
        return CircuitDecision(allowed=True, state="half_open", retry_after_s=0, probe_until=probe_until)
    return CircuitDecision(allowed=False, state="half_open", retry_after_s=1)


def check_target(model_uuid: str | None, *, now: datetime | str | None = None, claim: bool = True) -> CircuitDecision | None:
    if model_uuid is None:
        return None
    try:
        with store.connection(write=claim) as db:
            return can_execute(db, model_uuid, now=now, claim=claim)
    except sqlite3.Error:
        return None


def return_probe(db, model_id: str, probe_until: str) -> None:
    db.execute("""UPDATE model_circuit_state SET half_open_probe_until=NULL
                  WHERE model_id=? AND state='half_open' AND half_open_probe_until=?""", (model_id, probe_until))


def return_target_probe(model_id: str, probe_until: str) -> None:
    with store.connection(write=True) as db:
        return_probe(db, model_id, probe_until)


def record_outcome(
    db: sqlite3.Connection,
    model_uuid: str,
    *,
    ok: bool,
    error: str | None = None,
    now: datetime | str | None = None,
    secret: str | None = None,
) -> dict[str, Any]:
    now_dt = _to_utc(now, default_now=True)
    assert now_dt is not None
    now_iso = now_dt.isoformat()
    row = _ensure_row(db, model_uuid, now_iso)
    if row is None:
        return _circuit_dict(None, model_uuid, updated_at=now_iso)
    if ok:
        db.execute(
            "UPDATE model_circuit_state SET state='closed', failure_streak=0, opened_at=NULL, "
            "next_retry_at=NULL, half_open_probe_until=NULL, last_failure_reason=NULL, updated_at=? WHERE model_id=?",
            (now_iso, model_uuid),
        )
    else:
        prior = row["state"]
        streak = int(row["failure_streak"]) + 1
        threshold = max(1, int(row["consecutive_threshold"]))
        cooldown = max(5, int(row["cooldown_seconds"]))
        redacted = _redact_model_secret(db, model_uuid, error, secret=secret) if error else None
        reason = sanitize_error_text(redacted, "Provider call failed.", max_len=500)[:500] if redacted else None
        should_open = prior in ("half_open", "open") or streak >= threshold
        opened_at = (row["opened_at"] if (prior == "open" and row["opened_at"]) else now_iso) if should_open else None
        next_retry_at = (now_dt + timedelta(seconds=cooldown)).isoformat() if should_open else None
        db.execute(
            "UPDATE model_circuit_state SET state=?, failure_streak=?, opened_at=?, next_retry_at=?, "
            "half_open_probe_until=NULL, last_failure_reason=?, updated_at=? WHERE model_id=?",
            ("open" if should_open else "closed", streak, opened_at, next_retry_at, reason, now_iso, model_uuid),
        )
    return _circuit_dict(db.execute("SELECT * FROM model_circuit_state WHERE model_id=?", (model_uuid,)).fetchone(), model_uuid)


def _nearest_rank(ordered: list[int], pct: float) -> int | None:
    if not ordered:
        return None
    return ordered[min(max(math.ceil((pct / 100.0) * len(ordered)) - 1, 0), len(ordered) - 1)]


def _model_sla_entry(model_row: sqlite3.Row, checks: list[sqlite3.Row], circuit: dict[str, Any]) -> dict[str, Any]:
    total = len(checks)
    ok_count = sum(1 for row in checks if row["ok"] == 1)
    error_count = total - ok_count
    ordered = sorted(int(row["latency_ms"]) for row in checks if row["latency_ms"] is not None)
    p50, p95, p99 = _nearest_rank(ordered, 50), _nearest_rank(ordered, 95), _nearest_rank(ordered, 99)
    sla_target_ms = int(circuit["sla_target_ms"])
    return {
        "model_id": model_row["id"], "slug": model_row["slug"], "display_name": model_row["display_name"],
        "provider": model_row["provider"], "capability": model_row["capability"],
        "enabled": bool(model_row["enabled"]), "status": model_row["status"],
        "total_checks": total, "ok_count": ok_count, "error_count": error_count,
        "p50_latency_ms": p50, "p95_latency_ms": p95, "p99_latency_ms": p99,
        "error_rate_pct": round(error_count * 100.0 / total, 1) if total else 0.0,
        "sla_target_ms": sla_target_ms,
        "sla_compliant": (p95 is None or p95 <= sla_target_ms) and circuit["state"] != "open",
        "circuit": circuit,
    }


def compute_sla(db: sqlite3.Connection, model_uuid: str | None = None) -> dict[str, Any]:
    if model_uuid is not None:
        row = model_registry.get_row(db, model_uuid)
        checks = db.execute("SELECT ok, latency_ms FROM model_health_checks WHERE model_id=? ORDER BY checked_at DESC, id DESC", (model_uuid,)).fetchall()
        c_row = db.execute("SELECT * FROM model_circuit_state WHERE model_id=?", (model_uuid,)).fetchone()
        return _model_sla_entry(row, checks, _circuit_dict(c_row, model_uuid))

    models = db.execute("SELECT * FROM connected_models ORDER BY capability ASC, is_default DESC, updated_at DESC, id ASC").fetchall()
    checks = db.execute("SELECT model_id, ok, latency_ms FROM model_health_checks").fetchall()
    by_model: dict[str, list[sqlite3.Row]] = {}
    for check in checks:
        by_model.setdefault(check["model_id"], []).append(check)
    circuit_rows = {r["model_id"]: r for r in db.execute("SELECT * FROM model_circuit_state").fetchall()}
    per_model = {m["id"]: _model_sla_entry(m, by_model.get(m["id"], []), _circuit_dict(circuit_rows.get(m["id"]), m["id"])) for m in models}

    all_latencies = sorted(int(c["latency_ms"]) for c in checks if c["latency_ms"] is not None)
    total_checks = len(checks)
    total_errors = sum(1 for c in checks if c["ok"] != 1)
    entries = list(per_model.values())
    return {
        "summary": {
            "total_models": len(entries),
            "closed_circuits": sum(1 for e in entries if e["circuit"]["state"] == "closed"),
            "open_circuits": sum(1 for e in entries if e["circuit"]["state"] == "open"),
            "half_open_circuits": sum(1 for e in entries if e["circuit"]["state"] == "half_open"),
            "sla_compliant_models": sum(1 for e in entries if e["sla_compliant"]),
            "sla_violating_models": sum(1 for e in entries if not e["sla_compliant"]),
            "total_checks": total_checks, "error_count": total_errors,
            "error_rate_pct": round(total_errors * 100.0 / total_checks, 1) if total_checks else 0.0,
            "p50_latency_ms": _nearest_rank(all_latencies, 50),
            "p95_latency_ms": _nearest_rank(all_latencies, 95),
            "p99_latency_ms": _nearest_rank(all_latencies, 99),
        },
        "models": per_model,
    }


async def _require_admin(request: Request) -> dict[str, Any]:
    from . import model_admin
    return await model_admin.require_admin(request)


@router.get("/sla", dependencies=[Depends(_require_admin), Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
def get_fleet_sla():
    with store.connection() as db:
        return compute_sla(db)


@router.post("/{model_id}/circuit/reset", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
def reset_circuit(model_id: UUID, actor: dict = Depends(_require_admin)):
    from . import model_admin
    model_uuid, post_commit = str(model_id), []
    with store.connection(write=True) as db:
        model = model_registry.get_row(db, model_uuid)
        prev = db.execute("SELECT state, failure_streak FROM model_circuit_state WHERE model_id=?", (model_uuid,)).fetchone()
        circuit = record_outcome(db, model_uuid, ok=True)
        model_admin._record_audit(
            db, actor=actor, action="admin.model.circuit_reset", model_uuid=model_uuid,
            details={"slug": model["slug"], "previous_state": prev["state"] if prev else "closed",
                     "previous_failure_streak": int(prev["failure_streak"]) if prev else 0},
            post_commit=post_commit,
        )
    model_admin._flush_account_audits(post_commit)
    return {"circuit": circuit}


@router.patch("/{model_id}/circuit", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
def update_circuit_policy(model_id: UUID, item: CircuitPolicyInput, actor: dict = Depends(_require_admin)):
    from . import model_admin
    model_uuid, post_commit = str(model_id), []
    with store.connection(write=True) as db:
        model = model_registry.get_row(db, model_uuid)
        now_iso = store.timestamp()
        row = _ensure_row(db, model_uuid, now_iso)
        assert row is not None
        threshold = item.consecutive_threshold if item.consecutive_threshold is not None else int(row["consecutive_threshold"])
        cooldown = item.cooldown_seconds if item.cooldown_seconds is not None else int(row["cooldown_seconds"])
        sla_target = item.sla_target_ms if item.sla_target_ms is not None else int(row["sla_target_ms"])
        db.execute(
            "UPDATE model_circuit_state SET consecutive_threshold=?, cooldown_seconds=?, sla_target_ms=?, updated_at=? WHERE model_id=?",
            (threshold, cooldown, sla_target, now_iso, model_uuid),
        )
        circuit = _circuit_dict(db.execute("SELECT * FROM model_circuit_state WHERE model_id=?", (model_uuid,)).fetchone(), model_uuid)
        model_admin._record_audit(
            db, actor=actor, action="admin.model.circuit_policy", model_uuid=model_uuid,
            details={"slug": model["slug"], "changed": sorted(item.model_fields_set),
                     "consecutive_threshold": threshold, "cooldown_seconds": cooldown, "sla_target_ms": sla_target},
            post_commit=post_commit,
        )
    model_admin._flush_account_audits(post_commit)
    return {"circuit": circuit}
