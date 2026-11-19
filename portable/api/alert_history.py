"""Filterable alert delivery history, CSV/JSON export, and SSRF-checked retry API."""
from datetime import datetime, timezone
import json
import sqlite3
from typing import Any, Literal
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, Path, Query, Response

from . import alert_rules, exports, model_admin, rate_limit, store

router = APIRouter(prefix="/api/admin/alerts/deliveries", tags=["admin-alerts"])
_READ = [Depends(model_admin.require_admin), Depends(rate_limit.limit(rate_limit.ADMIN_READ))]
_RETRY = [
    Depends(model_admin.require_admin),
    Depends(rate_limit.limit(rate_limit.ADMIN_WRITE)),
    Depends(rate_limit.limit(rate_limit.ADMIN_PROBE)),
]
_NO_STORE = {"Cache-Control": "no-store"}


def _has_table(db: sqlite3.Connection, name: str) -> bool:
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def _require_tz(dt: datetime | None, field: str) -> datetime | None:
    if dt is None:
        return None
    if dt.tzinfo is None or dt.utcoffset() is None:
        raise HTTPException(422, f"{field} must include a timezone offset.")
    return dt.astimezone(timezone.utc)


def _parse_utc(raw: str | None) -> datetime | None:
    if not raw:
        return None
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00") if raw.endswith("Z") else raw)
    except ValueError:
        return None
    return dt.replace(tzinfo=timezone.utc) if (dt.tzinfo is None or dt.utcoffset() is None) else dt.astimezone(timezone.utc)


def _public_item(row: sqlite3.Row) -> dict[str, Any]:
    return alert_rules.public_delivery(row) | {
        "rule_name": row["rule_name"],
        "trigger_type": row["trigger_type"],
    }


def _query_deliveries(
    db: sqlite3.Connection,
    *,
    rule_id: UUID | None,
    status: Literal["", "ok", "failed"],
    since: datetime | None,
    until: datetime | None,
    before_id: int | None,
    limit: int,
) -> dict[str, Any]:
    since_utc = _require_tz(since, "since")
    until_utc = _require_tz(until, "until")
    if since_utc is not None and until_utc is not None and since_utc > until_utc:
        raise HTTPException(422, "since must be earlier than or equal to until.")

    empty_summary = {"total": 0, "ok_count": 0, "failed_count": 0, "success_rate_pct": 0.0, "failing_rules": 0}
    if not (_has_table(db, "alert_deliveries") and _has_table(db, "alert_rules")):
        return {"summary": empty_summary, "items": [], "next_before_id": None}

    clauses: list[str] = []
    params: list[Any] = []
    if rule_id is not None:
        clauses.append("d.rule_id = ?")
        params.append(str(rule_id))
    if status == "ok":
        clauses.append("d.ok = 1")
    elif status == "failed":
        clauses.append("d.ok = 0")

    where_sql = ("WHERE " + " AND ".join(clauses)) if clauses else ""
    rows = db.execute(
        f"""SELECT d.id, d.rule_id, d.event_key, d.ok, d.http_status, d.error, d.delivered_at,
                   r.name AS rule_name, r.trigger_type AS trigger_type
            FROM alert_deliveries d
            JOIN alert_rules r ON r.id = d.rule_id
            {where_sql}
            ORDER BY d.id DESC""",
        tuple(params),
    ).fetchall()

    filtered: list[dict[str, Any]] = []
    for row in rows:
        if since_utc is not None or until_utc is not None:
            dt = _parse_utc(row["delivered_at"])
            if dt is None:
                continue
            if since_utc is not None and dt < since_utc:
                continue
            if until_utc is not None and dt > until_utc:
                continue
        filtered.append(_public_item(row))

    total = len(filtered)
    ok_count = sum(1 for item in filtered if item["ok"])
    failed_count = total - ok_count
    failing_rules = len({item["rule_id"] for item in filtered if not item["ok"]})
    summary = {
        "total": total,
        "ok_count": ok_count,
        "failed_count": failed_count,
        "success_rate_pct": round(ok_count * 100.0 / total, 1) if total else 0.0,
        "failing_rules": failing_rules,
    }
    paged = [item for item in filtered if before_id is None or item["id"] < before_id]
    items = paged[:limit]
    next_before_id = items[-1]["id"] if len(paged) > limit and items else None
    return {"summary": summary, "items": items, "next_before_id": next_before_id}


@router.get("", dependencies=_READ)
def list_deliveries(
    response: Response,
    rule_id: UUID | None = None,
    status: Literal["", "ok", "failed"] = "",
    since: datetime | None = None,
    until: datetime | None = None,
    before_id: int | None = Query(default=None, ge=1, le=2**63 - 1),
    limit: int = Query(default=50, ge=1, le=100),
):
    with store.connection() as db:
        result = _query_deliveries(
            db, rule_id=rule_id, status=status, since=since, until=until, before_id=before_id, limit=limit
        )
    response.headers["Cache-Control"] = "no-store"
    return result


@router.get("/export", dependencies=_READ)
def export_deliveries(
    rule_id: UUID | None = None,
    status: Literal["", "ok", "failed"] = "",
    since: datetime | None = None,
    until: datetime | None = None,
    before_id: int | None = Query(default=None, ge=1, le=2**63 - 1),
    format: Literal["csv", "json"] = "csv",
    limit: int = Query(default=500, ge=1, le=2000),
):
    with store.connection() as db:
        result = _query_deliveries(
            db, rule_id=rule_id, status=status, since=since, until=until, before_id=before_id, limit=limit
        )
    if format == "json":
        payload = {
            "exported_at": store.timestamp(),
            "filters": {
                "rule_id": str(rule_id) if rule_id else None,
                "status": status or "all",
                "since": since.isoformat() if since else None,
                "until": until.isoformat() if until else None,
            },
            "summary": result["summary"],
            "items": result["items"],
        }
        return Response(
            json.dumps(payload, indent=2, ensure_ascii=False),
            media_type="application/json; charset=utf-8",
            headers={"Content-Disposition": 'attachment; filename="alert-deliveries.json"', **_NO_STORE},
        )

    lines = ["\ufeff" + exports.csv_row([
        "Delivery ID", "Rule ID", "Rule Name", "Trigger Type", "Event Key", "Outcome", "HTTP Status", "Error", "Delivered At",
    ])]
    for item in result["items"]:
        lines.append(exports.csv_row([
            item["id"], item["rule_id"], item["rule_name"], item["trigger_type"], item["event_key"],
            "ok" if item["ok"] else "failed", item["http_status"], item["error"], item["delivered_at"],
        ]))
    return Response(
        "".join(lines),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": 'attachment; filename="alert-deliveries.csv"', **_NO_STORE},
    )


@router.post("/{delivery_id}/retry", dependencies=_RETRY)
async def retry_delivery(delivery_id: int = Path(..., ge=1, le=2**63 - 1), actor: dict = Depends(model_admin.require_admin)):
    with store.connection() as db:
        if not (_has_table(db, "alert_deliveries") and _has_table(db, "alert_rules")):
            raise HTTPException(404, "Alert delivery not found.")
        prior = db.execute("SELECT * FROM alert_deliveries WHERE id=?", (delivery_id,)).fetchone()
        if prior is None:
            raise HTTPException(404, "Alert delivery not found.")
        rule = db.execute("SELECT * FROM alert_rules WHERE id=?", (prior["rule_id"],)).fetchone()
        if rule is None:
            raise HTTPException(404, "Alert rule not found.")
        if not rule["enabled"]:
            raise HTTPException(409, "Cannot retry delivery for a disabled alert rule.")

    event_key = f"retry:{delivery_id}:{uuid4().hex[:8]}"
    payload = alert_rules._event_payload(rule, "alert.retry", event_key, store.timestamp(), []) | {"retried_delivery_id": delivery_id}
    ok, http_status, err = await alert_rules._deliver(rule, payload, "alert.retry", event_key)
    post_commit: list = []
    with store.connection(write=True) as db:
        if db.execute("SELECT 1 FROM alert_rules WHERE id=?", (rule["id"],)).fetchone() is None:
            raise HTTPException(404, "Alert rule not found.")
        try:
            delivery = alert_rules._record_delivery(db, rule["id"], event_key, ok, http_status, err, store.timestamp())
        except sqlite3.IntegrityError as exc:
            raise HTTPException(404, "Alert rule not found.") from exc
        delivery["rule_name"] = rule["name"]
        delivery["trigger_type"] = rule["trigger_type"]
        model_admin._record_audit(
            db, actor=actor, action="admin.alert.retry", model_uuid=rule["id"],
            details={"retried_delivery_id": delivery_id, "new_delivery_id": delivery["id"], "ok": ok, "http_status": http_status},
            post_commit=post_commit,
        )
    model_admin._flush_account_audits(post_commit)
    return {"ok": ok, "delivery": delivery}
