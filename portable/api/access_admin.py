"""Cookie-authenticated admin controls for an embedded or remote access service."""
from urllib.parse import urlencode
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, Request

from . import access
from .account_admin import Update

router = APIRouter(prefix="/admin")


async def admin_token(request):
    account = await access.snapshot(request)
    if account["user"].get("role") != "admin" or account["user"].get("disabled"):
        raise HTTPException(403, "Admin access required.")
    return request.cookies[access.COOKIE]


@router.get("/users")
async def users(request: Request, q: str = Query(default="", max_length=200), cursor: str = Query(default="", max_length=128)):
    token = await admin_token(request)
    params = {"q": q, "limit": 25}
    if cursor:
        params["cursor"] = cursor
    return await access.upstream("admin/users?" + urlencode(params), token=token)


@router.get("/audit")
async def audit(request: Request):
    token = await admin_token(request)
    return await access.upstream("admin/audit?limit=20", token=token)


@router.patch("/users/{uid}")
async def update(uid: UUID, item: Update, request: Request):
    token = await admin_token(request)
    return await access.upstream("admin/users/" + str(uid), "PATCH", token=token, body=item.model_dump(mode="json", exclude_unset=True))
