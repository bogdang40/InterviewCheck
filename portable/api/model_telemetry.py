"""Persistent health-check history and telemetry aggregation for connected models."""
import math
import sqlite3
from typing import Any, Literal

from . import model_registry, sql_script, store
from .error_sanitizer import sanitize_error_text

MAX_HISTORY_PER_MODEL = 50

SCHEMA = """
CREATE TABLE IF NOT EXISTS model_health_checks (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 model_id TEXT NOT NULL REFERENCES connected_models(id) ON DELETE CASCADE,
 source TEXT NOT NULL CHECK(source IN ('probe','live')),
 ok INTEGER NOT NULL CHECK(ok IN (0,1)),
 http_status INTEGER,
 latency_ms INTEGER,
 error TEXT,
 checked_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_model_health_model_at
 ON model_health_checks(model_id, checked_at DESC, id DESC);
"""


def migrate(db: sqlite3.Connection) -> None:
    sql_script.execute(db, SCHEMA)


def record_check(
    db: sqlite3.Connection,
    model_uuid: str,
    *,
    source: Literal["probe", "live"],
    ok: bool,
    http_status: int | None,
    latency_ms: int | None,
    error: str | None,
    checked_at: str,
) -> None:
    safe_error = (
        sanitize_error_text(error, "Provider call failed.", max_len=500)[:500]
        if (not ok and error)
        else None
    )
    db.execute(
        """INSERT INTO model_health_checks(
               model_id, source, ok, http_status, latency_ms, error, checked_at
           ) VALUES (?,?,?,?,?,?,?)""",
        (model_uuid, source, 1 if ok else 0, http_status, latency_ms, safe_error, checked_at),
    )
    db.execute(
        """DELETE FROM model_health_checks
           WHERE model_id=?
             AND id NOT IN (
                 SELECT id FROM model_health_checks
                 WHERE model_id=?
                 ORDER BY checked_at DESC, id DESC
                 LIMIT ?
             )""",
        (model_uuid, model_uuid, MAX_HISTORY_PER_MODEL),
    )
    if source == "live":
        row = db.execute("SELECT enabled FROM connected_models WHERE id=?", (model_uuid,)).fetchone()
        if row is not None:
            now = store.timestamp()
            if row["enabled"] == 1:
                status = "connected" if ok else "error"
                last_error = None if ok else safe_error
                db.execute(
                    """UPDATE connected_models
                       SET status=?, last_error=?, last_latency_ms=?, last_checked_at=?, updated_at=?
                       WHERE id=?""",
                    (status, last_error, latency_ms, checked_at, now, model_uuid),
                )
            else:
                db.execute(
                    """UPDATE connected_models
                       SET status='disabled', last_latency_ms=?, last_checked_at=?, updated_at=?
                       WHERE id=?""",
                    (latency_ms, checked_at, now, model_uuid),
                )


def _nearest_rank_p95(latencies: list[int]) -> int | None:
    if not latencies:
        return None
    ordered = sorted(latencies)
    idx = min(max(math.ceil(0.95 * len(ordered)) - 1, 0), len(ordered) - 1)
    return ordered[idx]


def _summarize_rows(rows: list[sqlite3.Row]) -> dict[str, Any]:
    total = len(rows)
    ok_count = sum(1 for row in rows if row["ok"] == 1)
    latencies = [int(row["latency_ms"]) for row in rows if row["latency_ms"] is not None]
    return {
        "total_checks": total,
        "ok_count": ok_count,
        "error_count": total - ok_count,
        "uptime_pct": round(ok_count * 100.0 / total, 1) if total else None,
        "avg_latency_ms": round(sum(latencies) / len(latencies)) if latencies else None,
        "p95_latency_ms": _nearest_rank_p95(latencies),
        "last_checked_at": rows[0]["checked_at"] if rows else None,
        "last_source": rows[0]["source"] if rows else None,
    }


def summarize_model(db: sqlite3.Connection, model_uuid: str) -> dict[str, Any]:
    rows = db.execute(
        """SELECT source, ok, latency_ms, checked_at
           FROM model_health_checks
           WHERE model_id=?
           ORDER BY checked_at DESC, id DESC""",
        (model_uuid,),
    ).fetchall()
    return _summarize_rows(rows)


def get_model_health(db: sqlite3.Connection, model_uuid: str, *, limit: int = 25) -> dict[str, Any]:
    row = model_registry.get_row(db, model_uuid)
    bounded = max(1, min(int(limit), MAX_HISTORY_PER_MODEL))
    history_rows = db.execute(
        """SELECT id, model_id, source, ok, http_status, latency_ms, error, checked_at
           FROM model_health_checks
           WHERE model_id=?
           ORDER BY checked_at DESC, id DESC
           LIMIT ?""",
        (model_uuid, bounded),
    ).fetchall()
    history = [
        {
            "id": item["id"],
            "model_id": item["model_id"],
            "source": item["source"],
            "ok": bool(item["ok"]),
            "http_status": item["http_status"],
            "latency_ms": item["latency_ms"],
            "error": item["error"],
            "checked_at": item["checked_at"],
        }
        for item in history_rows
    ]
    return {
        "model": model_registry.public_model(row),
        "summary": summarize_model(db, model_uuid),
        "history": history,
    }


def fleet_telemetry(db: sqlite3.Connection) -> dict[str, Any]:
    models = db.execute("SELECT id, enabled, status FROM connected_models").fetchall()
    checks = db.execute(
        """SELECT model_id, source, ok, latency_ms, checked_at
           FROM model_health_checks
           ORDER BY checked_at DESC, id DESC"""
    ).fetchall()
    by_model: dict[str, list[sqlite3.Row]] = {}
    for check in checks:
        by_model.setdefault(check["model_id"], []).append(check)

    per_model = {model["id"]: _summarize_rows(by_model.get(model["id"], [])) for model in models}
    total_checks = len(checks)
    ok_checks = sum(1 for check in checks if check["ok"] == 1)
    latencies = [int(check["latency_ms"]) for check in checks if check["latency_ms"] is not None]
    return {
        "summary": {
            "total_models": len(models),
            "enabled_models": sum(1 for model in models if model["enabled"] == 1),
            "connected_models": sum(1 for model in models if model["status"] == "connected"),
            "error_models": sum(1 for model in models if model["status"] == "error"),
            "total_checks": total_checks,
            "ok_checks": ok_checks,
            "uptime_pct": round(ok_checks * 100.0 / total_checks, 1) if total_checks else None,
            "avg_latency_ms": round(sum(latencies) / len(latencies)) if latencies else None,
        },
        "models": per_model,
    }
