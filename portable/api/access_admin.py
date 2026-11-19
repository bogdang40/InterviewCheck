"""Cookie-authenticated admin controls for an embedded or remote access service."""
from urllib.parse import urlencode
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request

from . import access, rate_limit
from .account_admin import Update


async def admin_token(request: Request) -> str:
    _, token = await access.require_admin_session(request)
    if not access.account_enabled():
        raise HTTPException(503, "Account administration requires embedded or remote access mode.")
    return token


router = APIRouter(prefix="/admin", dependencies=[Depends(admin_token)])


@router.get("/users", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
async def users(request: Request, q: str = Query(default="", max_length=200), cursor: str = Query(default="", max_length=128)):
    token = await admin_token(request)
    params = {"q": q, "limit": 25}
    if cursor:
        params["cursor"] = cursor
    return await access.upstream("admin/users?" + urlencode(params), token=token)


@router.get("/audit", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
async def audit(request: Request):
    token = await admin_token(request)
    return await access.upstream("admin/audit?limit=20", token=token)


@router.patch("/users/{uid}", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
async def update(uid: UUID, item: Update, request: Request):
    token = await admin_token(request)
    return await access.upstream("admin/users/" + str(uid), "PATCH", token=token, body=item.model_dump(mode="json", exclude_unset=True))
