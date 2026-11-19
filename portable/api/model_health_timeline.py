"""Time-bucketed fleet model health-check timeline and CSV/JSON export API."""
from datetime import datetime, timedelta, timezone
import json
import math
import sqlite3
from typing import Any, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from fastapi.responses import JSONResponse

from . import exports, rate_limit, store
from .error_sanitizer import sanitize_error_text

ALLOWED_CAPABILITIES = frozenset({"reference", "question_planning", "transcription", "embedding", "judge"})
router = APIRouter(prefix="/api/admin/models", tags=["model-health-timeline"])


async def _require_admin(request: Request) -> dict[str, Any]:
    from . import model_admin
    return await model_admin.require_admin(request)


_ADMIN_READ = [Depends(_require_admin), Depends(rate_limit.limit(rate_limit.ADMIN_READ))]


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


def _iso_utc(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _nearest_rank(ordered: list[int], pct: float) -> int | None:
    if not ordered:
        return None
    idx = min(max(math.ceil((pct / 100.0) * len(ordered)) - 1, 0), len(ordered) - 1)
    return ordered[idx]


def _validate_capability(capability: str) -> str:
    if capability and capability not in ALLOWED_CAPABILITIES:
        raise HTTPException(422, "Invalid capability filter.")
    return capability


def _bucket_start(dt: datetime, bucket_minutes: int) -> str:
    bucket_sec = bucket_minutes * 60
    floored = (int(dt.timestamp()) // bucket_sec) * bucket_sec
    return _iso_utc(datetime.fromtimestamp(floored, tz=timezone.utc))


def _sanitize_opt(text: str | None) -> str | None:
    return sanitize_error_text(text, "Provider check failed.", max_len=300) if text else None


def _build_timeline(
    db: sqlite3.Connection,
    *,
    hours: int,
    bucket_minutes: int,
    model_id: UUID | None,
    capability: str,
    source: str,
    limit: int,
) -> dict[str, Any]:
    now_utc = datetime.now(timezone.utc)
    since_utc = now_utc - timedelta(hours=hours)
    window = {
        "hours": hours,
        "bucket_minutes": bucket_minutes,
        "since": _iso_utc(since_utc),
        "until": _iso_utc(now_utc),
    }

    rows: list[tuple[datetime, sqlite3.Row]] = []
    if _has_table(db, "connected_models") and _has_table(db, "model_health_checks"):
        clauses: list[str] = []
        params: list[Any] = []
        if model_id is not None:
            clauses.append("h.model_id = ?")
            params.append(str(model_id))
        if capability:
            clauses.append("m.capability = ?")
            params.append(capability)
        if source:
            clauses.append("h.source = ?")
            params.append(source)
        where_sql = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        sql = (
            "SELECT h.id, h.model_id, h.source, h.ok, h.http_status, h.latency_ms, h.error, h.checked_at, "
            "m.slug, m.display_name, m.provider, m.capability "
            "FROM model_health_checks h "
            "JOIN connected_models m ON m.id = h.model_id "
            f"{where_sql} "
            "ORDER BY h.checked_at DESC, h.id DESC"
        )
        for row in db.execute(sql, params).fetchall():
            dt = _parse_utc(row["checked_at"])
            if dt is not None and dt >= since_utc:
                rows.append((dt, row))

    rows.sort(key=lambda item: (item[0], int(item[1]["id"])), reverse=True)

    total = len(rows)
    ok_count = sum(1 for _, r in rows if r["ok"] == 1)
    error_count = total - ok_count
    all_latencies = sorted(int(r["latency_ms"]) for _, r in rows if r["latency_ms"] is not None)
    models_with_errors = len({r["model_id"] for _, r in rows if r["ok"] != 1})

    summary = {
        "total_checks": total,
        "ok_count": ok_count,
        "error_count": error_count,
        "uptime_pct": round(ok_count * 100.0 / total, 1) if total else None,
        "avg_latency_ms": round(sum(all_latencies) / len(all_latencies)) if all_latencies else None,
        "p50_latency_ms": _nearest_rank(all_latencies, 50),
        "p95_latency_ms": _nearest_rank(all_latencies, 95),
        "p99_latency_ms": _nearest_rank(all_latencies, 99),
        "models_with_errors": models_with_errors,
    }

    bucket_groups: dict[str, list[sqlite3.Row]] = {}
    for dt, row in rows:
        key = _bucket_start(dt, bucket_minutes)
        bucket_groups.setdefault(key, []).append(row)

    buckets: list[dict[str, Any]] = []
    for key in sorted(bucket_groups):
        group = bucket_groups[key]
        b_total = len(group)
        b_ok = sum(1 for r in group if r["ok"] == 1)
        b_lats = sorted(int(r["latency_ms"]) for r in group if r["latency_ms"] is not None)
        buckets.append({
            "bucket_start": key,
            "total_checks": b_total,
            "ok_count": b_ok,
            "error_count": b_total - b_ok,
            "uptime_pct": round(b_ok * 100.0 / b_total, 1) if b_total else None,
            "avg_latency_ms": round(sum(b_lats) / len(b_lats)) if b_lats else None,
            "p95_latency_ms": _nearest_rank(b_lats, 95),
        })

    recent_events = [
        {
            "id": int(row["id"]),
            "model_id": row["model_id"],
            "model_slug": row["slug"],
            "display_name": row["display_name"],
            "provider": row["provider"],
            "capability": row["capability"],
            "source": row["source"],
            "ok": bool(row["ok"]),
            "http_status": row["http_status"],
            "latency_ms": row["latency_ms"],
            "error": _sanitize_opt(row["error"]),
            "checked_at": row["checked_at"],
        }
        for _, row in rows[:limit]
    ]
    return {"window": window, "summary": summary, "buckets": buckets, "recent_events": recent_events}


@router.get("/health-timeline", dependencies=_ADMIN_READ)
def get_health_timeline(
    hours: int = Query(default=24, ge=1, le=720),
    bucket_minutes: int = Query(default=60, ge=5, le=1440),
    model_id: UUID | None = None,
    capability: str = Query(default="", max_length=40),
    source: Literal["", "probe", "live"] = "",
    limit: int = Query(default=50, ge=1, le=200),
):
    cap = _validate_capability(capability)
    with store.connection() as db:
        payload = _build_timeline(
            db, hours=hours, bucket_minutes=bucket_minutes,
            model_id=model_id, capability=cap, source=source, limit=limit,
        )
    return JSONResponse(content=payload, headers={"Cache-Control": "no-store"})


@router.get("/health-timeline/export", dependencies=_ADMIN_READ)
def export_health_timeline(
    hours: int = Query(default=24, ge=1, le=720),
    bucket_minutes: int = Query(default=60, ge=5, le=1440),
    model_id: UUID | None = None,
    capability: str = Query(default="", max_length=40),
    source: Literal["", "probe", "live"] = "",
    format: Literal["csv", "json"] = "csv",
    limit: int = Query(default=500, ge=1, le=2000),
):
    cap = _validate_capability(capability)
    with store.connection() as db:
        payload = _build_timeline(
            db, hours=hours, bucket_minutes=bucket_minutes,
            model_id=model_id, capability=cap, source=source, limit=limit,
        )
    if format == "csv":
        lines = [
            "\ufeff" + exports.csv_row([
                "Checked at", "Model ID", "Slug", "Display name", "Provider",
                "Capability", "Source", "Status", "HTTP status", "Latency ms", "Error",
            ])
        ]
        for ev in payload["recent_events"]:
            lines.append(exports.csv_row([
                ev["checked_at"], ev["model_id"], ev["model_slug"], ev["display_name"],
                ev["provider"], ev["capability"], ev["source"],
                "ok" if ev["ok"] else "error", ev["http_status"], ev["latency_ms"], ev["error"] or "",
            ]))
        return Response(
            content="".join(lines).encode("utf-8"),
            media_type="text/csv; charset=utf-8",
            headers={"Cache-Control": "no-store", "Content-Disposition": 'attachment; filename="model-health-timeline.csv"'},
        )
    doc = {
        "exported_at": payload["window"]["until"],
        "filters": {
            "hours": hours,
            "bucket_minutes": bucket_minutes,
            "model_id": str(model_id) if model_id else None,
            "capability": cap or None,
            "source": source or None,
            "limit": limit,
        },
        "window": payload["window"],
        "summary": payload["summary"],
        "buckets": payload["buckets"],
        "events": payload["recent_events"],
    }
    return Response(
        content=json.dumps(doc, indent=2, ensure_ascii=False),
        media_type="application/json; charset=utf-8",
        headers={"Cache-Control": "no-store", "Content-Disposition": 'attachment; filename="model-health-timeline.json"'},
    )
