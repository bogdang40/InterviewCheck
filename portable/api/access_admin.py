"""Cookie-authenticated admin controls for an embedded or remote access service."""
from datetime import datetime
import json
from typing import Any, Literal
from urllib.parse import urlencode
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import JSONResponse, Response

from . import access, exports, rate_limit
from .account_admin import Update


async def admin_token(request: Request) -> str:
    _, token = await access.require_admin_session(request)
    if not access.account_enabled():
        raise HTTPException(503, "Account administration requires embedded or remote access mode.")
    return token


router = APIRouter(prefix="/admin", dependencies=[Depends(admin_token)])


def _require_tz(value: datetime | None, field: str) -> str | None:
    if value is None:
        return None
    if value.tzinfo is None or value.utcoffset() is None:
        raise HTTPException(422, f"{field} must include a timezone.")
    return value.isoformat()


def _matches_category(entry: dict[str, Any], category: Literal["all", "models", "accounts"]) -> bool:
    is_model = str(entry.get("action") or "").startswith("admin.model.")
    if category == "models":
        return is_model
    if category == "accounts":
        return not is_model
    return True


async def _fetch_audit(
    token: str,
    *,
    q: str,
    category: Literal["all", "models", "accounts"],
    action: str,
    actor: str,
    since: datetime | None,
    until: datetime | None,
    before_id: int | None,
    limit: int,
) -> dict[str, Any]:
    since_iso = _require_tz(since, "since")
    until_iso = _require_tz(until, "until")
    base_params: dict[str, str | int] = {}
    if q_clean := q.strip():
        base_params["q"] = q_clean
    action_clean = action.strip()
    embedded = access.embedded_enabled()
    cursor_param = "before_id" if embedded else "beforeId"
    if action_clean:
        base_params["action"] = action_clean
    elif category == "models" and embedded:
        base_params["action"] = "admin.model."
    if actor_clean := actor.strip():
        base_params["actor"] = actor_clean
    if since_iso is not None:
        base_params["since"] = since_iso
    if until_iso is not None:
        base_params["until"] = until_iso

    if category == "all" or ("action" in base_params and base_params["action"] == "admin.model."):
        params = dict(base_params, limit=limit)
        if before_id is not None:
            params[cursor_param] = before_id
        return await access.upstream("admin/audit?" + urlencode(params), token=token)

    matched: list[dict[str, Any]] = []
    cursor = before_id
    next_before_id: int | None = None
    for _ in range(5):
        params = dict(base_params, limit=200)
        if cursor is not None:
            params[cursor_param] = cursor
        data = await access.upstream("admin/audit?" + urlencode(params), token=token)
        if not isinstance(data, dict) or not isinstance(data.get("entries"), list):
            return data
        for entry in data["entries"]:
            if isinstance(entry, dict) and _matches_category(entry, category):
                matched.append(entry)
                if len(matched) > limit:
                    break
        upstream_next = data.get("nextBeforeId")
        if len(matched) > limit:
            page = matched[:limit]
            return {"entries": page, "nextBeforeId": page[-1].get("id")}
        if upstream_next is None:
            return {"entries": matched, "nextBeforeId": None}
        cursor = upstream_next
        next_before_id = upstream_next
    return {"entries": matched[:limit], "nextBeforeId": next_before_id}


@router.get("/users", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
async def users(
    q: str = Query(default="", max_length=200),
    cursor: str = Query(default="", max_length=128),
    token: str = Depends(admin_token),
):
    params = {"q": q, "limit": 25}
    if cursor:
        params["cursor"] = cursor
    return await access.upstream("admin/users?" + urlencode(params), token=token)


@router.get("/audit", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
async def audit(
    q: str = Query(default="", max_length=200),
    category: Literal["all", "models", "accounts"] = "all",
    action: str = Query(default="", max_length=120),
    actor: str = Query(default="", max_length=128),
    since: datetime | None = Query(default=None),
    until: datetime | None = Query(default=None),
    before_id: int | None = Query(default=None, ge=1),
    limit: int = Query(default=50, ge=1, le=200),
    token: str = Depends(admin_token),
):
    return await _fetch_audit(
        token, q=q, category=category, action=action, actor=actor,
        since=since, until=until, before_id=before_id, limit=limit,
    )


@router.get("/audit/verify", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
async def verify_audit(token: str = Depends(admin_token)):
    data = await access.upstream("admin/audit/verify", token=token)
    return JSONResponse(data, headers={"Cache-Control": "no-store"})


@router.get("/audit/export", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
async def export_audit(
    format: Literal["csv", "json"] = "csv",
    q: str = Query(default="", max_length=200),
    category: Literal["all", "models", "accounts"] = "all",
    action: str = Query(default="", max_length=120),
    actor: str = Query(default="", max_length=128),
    since: datetime | None = Query(default=None),
    until: datetime | None = Query(default=None),
    before_id: int | None = Query(default=None, ge=1),
    limit: int = Query(default=200, ge=1, le=200),
    token: str = Depends(admin_token),
):
    data = await _fetch_audit(
        token, q=q, category=category, action=action, actor=actor,
        since=since, until=until, before_id=before_id, limit=limit,
    )
    entries = data.get("entries", []) if isinstance(data, dict) else []
    if format == "json":
        payload = json.dumps(
            {"entries": entries, "nextBeforeId": data.get("nextBeforeId") if isinstance(data, dict) else None},
            ensure_ascii=False,
            indent=2,
        ).encode("utf-8")
        return Response(
            payload,
            media_type="application/json",
            headers={"Content-Disposition": 'attachment; filename="audit-log.json"', "Cache-Control": "no-store"},
        )
    lines = ["\ufeff" + exports.csv_row(["id", "at", "action", "actorUserId", "targetUserId", "details"])]
    for entry in entries:
        details = entry.get("details")
        details_text = (
            details
            if isinstance(details, str)
            else (json.dumps(details, ensure_ascii=False, separators=(",", ":")) if details is not None else "")
        )
        lines.append(
            exports.csv_row([
                entry.get("id"),
                entry.get("at"),
                entry.get("action"),
                entry.get("actorUserId"),
                entry.get("targetUserId"),
                details_text,
            ])
        )
    return Response(
        "".join(lines).encode("utf-8"),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": 'attachment; filename="audit-log.csv"', "Cache-Control": "no-store"},
    )


@router.patch("/users/{uid}", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
async def update(uid: UUID, item: Update, token: str = Depends(admin_token)):
    return await access.upstream("admin/users/" + str(uid), "PATCH", token=token, body=item.model_dump(mode="json", exclude_unset=True))
