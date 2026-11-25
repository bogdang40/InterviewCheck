"""Admin Usage tab: public visits, sign-ins, accounts, workspace activity and AI usage.

`POST /api/usage/visit` is public: the signed-out home, sample and sign-in pages report one view.
`GET /api/admin/usage` is for administrators and reads both the review and the account database.
"""
import csv
from datetime import datetime, timedelta, timezone
import io
import os
from typing import Any, Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from fastapi.responses import StreamingResponse

from . import access, account_db, ai_cost_log, model_resolver, rate_limit, store, usage_events
from .exports import csv_cell
from .models import Input
from .origin import workspace_client

router = APIRouter(prefix="/api/admin/usage", tags=["usage-admin"])
visit_router = APIRouter(prefix="/api/usage", dependencies=[Depends(rate_limit.limit(rate_limit.SITE_VISIT))])

RECENT_LIMIT = 30
PEOPLE_LIMIT = 200


class Visit(Input):
    page: Literal["home", "sample", "signin"]


@visit_router.post("/visit", status_code=204)
def visit(item: Visit, request: Request) -> Response:
    with store.connection(write=True) as db:
        usage_events.record_visit(db, item.page, workspace_client(request), request.headers.get("user-agent", ""))
    return Response(status_code=204)


async def require_admin(request: Request) -> dict[str, Any]:
    user, _ = await access.require_admin_session(request)
    return user


@router.get("", dependencies=[Depends(require_admin), Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
def usage(days: int = Query(default=30, ge=1, le=365)) -> dict[str, Any]:
    return summary(days)


@router.get("/ai-costs", dependencies=[Depends(require_admin), Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
def ai_costs(days: int = Query(default=30, ge=1, le=365)) -> dict[str, Any]:
    first = usage_events.since(days)
    with store.connection() as db:
        return {"days": days, "first_day": first, "last_day": usage_events.today(), **ai_cost_log.summary(db, first)}


@router.get("/ai-costs.csv", dependencies=[Depends(require_admin), Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
def ai_costs_csv(days: int = Query(default=30, ge=1, le=365)) -> StreamingResponse:
    first = usage_events.since(days)
    with store.connection() as db:
        rows = ai_cost_log.csv_rows(db, first)
    buffer = io.StringIO()
    writer = csv.writer(buffer)
    writer.writerow(ai_cost_log.CSV_COLUMNS)
    for row in rows:
        writer.writerow([csv_cell(value) for value in row])
    name = f"ai-costs-{first}-to-{usage_events.today()}.csv"
    return StreamingResponse(iter([buffer.getvalue()]), media_type="text/csv; charset=utf-8",
                             headers={"Content-Disposition": f'attachment; filename="{name}"', "Cache-Control": "no-store"})


def _iso(ms: int | None) -> str | None:
    if not ms:
        return None
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).isoformat().replace("+00:00", "Z")


def _day_list(days: int) -> list[str]:
    end = datetime.now(timezone.utc).date()
    return [(end - timedelta(days=offset)).isoformat() for offset in range(days)]


def _per_day(db, sql: str, first: str) -> dict[str, int]:
    return {row[0]: int(row[1]) for row in db.execute(sql, (first,)).fetchall() if row[0]}


def _workspace(first: str) -> dict[str, Any]:
    with store.connection() as db:
        counts = usage_events.daily_counts(db, first)
        interviews = _per_day(db, """SELECT substr(created_at,1,10) AS d, COUNT(*) FROM sessions
                                     WHERE substr(created_at,1,10)>=? GROUP BY d""", first)
        reviews = _per_day(db, """SELECT substr(created_at,1,10) AS d, COUNT(*) FROM answer_review_events
                                  WHERE substr(created_at,1,10)>=? GROUP BY d""", first)
        ai = {row[0]: row for row in db.execute(
            """SELECT usage_date, SUM(request_count), SUM(error_count), SUM(input_tokens+output_tokens),
                      SUM(estimated_cost_usd) FROM model_usage_daily WHERE usage_date>=? GROUP BY usage_date""",
            (first,)).fetchall()}
        models = [dict(row) for row in db.execute(
            """SELECT m.display_name AS name, m.provider, m.capability, m.model_id, m.enabled,
                      m.encrypted_api_key IS NOT NULL AS has_key,
                      COALESCE(SUM(u.request_count),0) AS requests, COALESCE(SUM(u.error_count),0) AS errors,
                      COALESCE(SUM(u.input_tokens+u.output_tokens),0) AS tokens,
                      COALESCE(SUM(u.estimated_cost_usd),0) AS cost_usd
               FROM connected_models m LEFT JOIN model_usage_daily u ON u.model_id=m.id AND u.usage_date>=?
               GROUP BY m.id ORDER BY requests DESC, m.display_name""", (first,)).fetchall()]
        tracking = usage_events.tracking_since(db)
    for model in models:
        model["enabled"] = bool(model["enabled"])
        model["has_key"] = bool(model["has_key"])
        model["cost_usd"] = round(float(model["cost_usd"]), 4)
    return {"counts": counts, "interviews": interviews, "reviews": reviews, "ai": ai, "models": models, "tracking": tracking}


def _accounts(first: str) -> dict[str, Any] | None:
    try:
        path = account_db.database()
    except HTTPException:
        return None
    if not path.is_file():
        return None  # Accounts live on a remote service, or no one has signed up yet.
    first_ms = int(datetime.fromisoformat(first).replace(tzinfo=timezone.utc).timestamp() * 1000)
    now_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
    operator = os.getenv("INTERVIEWCHECK_OPERATOR_EMAIL", "").strip().casefold()  # unset on multi-admin sites
    with account_db.connection() as db:
        signins = _per_day(db, """SELECT strftime('%Y-%m-%d', at/1000, 'unixepoch') AS d, COUNT(*) FROM audit_log
                                  WHERE action='auth.login' AND at>=? GROUP BY d""", first_ms)
        signups = _per_day(db, """SELECT strftime('%Y-%m-%d', created_at/1000, 'unixepoch') AS d, COUNT(*) FROM users
                                  WHERE created_at>=? GROUP BY d""", first_ms)
        people = [{
            "email": row["email"],
            "role": row["role"],
            "disabled": bool(row["disabled"]),
            "operator": bool(operator) and row["email"].casefold() == operator,
            "created_at": _iso(row["created_at"]),
            "last_login_at": _iso(row["last_login_at"]),
            "signins": int(row["signins"]),
            "active_sessions": int(row["active_sessions"]),
        } for row in db.execute(
            """SELECT u.email, u.role, u.disabled, u.created_at, u.last_login_at,
                      (SELECT COUNT(*) FROM audit_log a WHERE a.action='auth.login' AND a.actor_user_id=u.id AND a.at>=?) AS signins,
                      (SELECT COUNT(*) FROM sessions s WHERE s.user_id=u.id AND s.revoked_at IS NULL AND s.expires_at>?) AS active_sessions
               FROM users u ORDER BY COALESCE(u.last_login_at, u.created_at) DESC LIMIT ?""",
            (first_ms, now_ms, PEOPLE_LIMIT)).fetchall()]
        recent = [{"at": _iso(row["at"]), "email": row["email"], "action": row["action"]} for row in db.execute(
            """SELECT a.at, a.action, u.email FROM audit_log a LEFT JOIN users u ON u.id=a.actor_user_id
               WHERE a.action IN ('auth.login','auth.signup') ORDER BY a.at DESC, a.id DESC LIMIT ?""",
            (RECENT_LIMIT,)).fetchall()]
        total_accounts = db.execute("SELECT COUNT(*) FROM users").fetchone()[0]
    return {"signins": signins, "signups": signups, "people": people, "recent": recent, "total": int(total_accounts)}


def summary(days: int) -> dict[str, Any]:
    first = usage_events.since(days)
    work = _workspace(first)
    accounts = _accounts(first)
    daily = []
    for day in _day_list(days):
        counts = work["counts"].get(day, {})
        ai = work["ai"].get(day)
        daily.append({
            "day": day,
            "visitors": counts.get("visitors", 0),
            "home": counts.get("visit:home", 0),
            "sample": counts.get("visit:sample", 0),
            "signin_page": counts.get("visit:signin", 0),
            "signins": (accounts or {}).get("signins", {}).get(day, 0),
            "new_accounts": (accounts or {}).get("signups", {}).get(day, 0),
            "interviews": work["interviews"].get(day, 0),
            "answers": counts.get("answer", 0),
            "reviews": work["reviews"].get(day, 0),
            "ai_requests": int(ai[1] or 0) if ai else 0,
            "ai_errors": int(ai[2] or 0) if ai else 0,
            "ai_tokens": int(ai[3] or 0) if ai else 0,
            "ai_cost_usd": round(float(ai[4] or 0), 4) if ai else 0.0,
        })
    keys = ("visitors", "home", "sample", "signin_page", "signins", "new_accounts", "interviews", "answers",
            "reviews", "ai_requests", "ai_errors", "ai_tokens")
    totals: dict[str, Any] = {key: sum(row[key] for row in daily) for key in keys}
    totals["ai_cost_usd"] = round(sum(row["ai_cost_usd"] for row in daily), 4)
    fallbacks = [item for item in model_resolver.env_fallback_summaries() if item["configured"]]
    return {
        "days": days,
        "first_day": first,
        "last_day": usage_events.today(),
        "timezone": "UTC",
        "tracking_since": work["tracking"],
        "totals": totals,
        "daily": daily,
        "accounts_available": accounts is not None,
        "accounts_total": accounts["total"] if accounts else None,
        "people": accounts["people"] if accounts else [],
        "recent": accounts["recent"] if accounts else [],
        "models": work["models"],
        "ai_setup": {
            "connected": len(work["models"]),
            "enabled": sum(1 for m in work["models"] if m["enabled"]),
            "with_key": sum(1 for m in work["models"] if m["has_key"]),
            "env_fallbacks": [{"provider": f["provider"], "capability": f["capability"]} for f in fallbacks],
        },
    }
