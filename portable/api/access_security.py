"""Cookie-authenticated security and rate-limit proxy routes for /api/integrations."""
from urllib.parse import urlencode
from uuid import UUID

from fastapi import APIRouter, Body, Depends, HTTPException, Query, Request

from . import access, access_admin, rate_limit
from .account_security import ApiTokenCreate, RateLimitUnlockInput, RevokeSessionsInput

router = APIRouter()


async def _user_token(request: Request) -> str:
    if not access.account_enabled():
        raise HTTPException(503, "Account security requires embedded or remote access mode.")
    token = request.cookies.get(access.COOKIE)
    if not token:
        raise HTTPException(401, "Sign in under Account.")
    await access.snapshot(request)
    return token


@router.get("/security/sessions")
async def list_sessions(token: str = Depends(_user_token)):
    return await access.upstream("auth/sessions", token=token)


@router.delete("/security/sessions/{sid}")
async def revoke_session(sid: UUID, token: str = Depends(_user_token)):
    return await access.upstream(f"auth/sessions/{sid}", "DELETE", token=token)


@router.get("/security/tokens")
async def list_tokens(token: str = Depends(_user_token)):
    return await access.upstream("auth/tokens", token=token)


@router.post("/security/tokens", status_code=201)
async def create_token(item: ApiTokenCreate, token: str = Depends(_user_token)):
    return await access.upstream("auth/tokens", "POST", token=token, body=item.model_dump(exclude_none=True))


@router.delete("/security/tokens/{tid}")
async def revoke_token(tid: UUID, token: str = Depends(_user_token)):
    return await access.upstream(f"auth/tokens/{tid}", "DELETE", token=token)


@router.get("/admin/security/users/{uid}/sessions", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
async def admin_user_sessions(uid: UUID, token: str = Depends(access_admin.admin_token)):
    return await access.upstream(f"admin/users/{uid}/sessions", token=token)


@router.post("/admin/security/users/{uid}/revoke-sessions", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
async def admin_revoke_user_sessions(
    uid: UUID,
    item: RevokeSessionsInput | None = Body(default=None),
    token: str = Depends(access_admin.admin_token),
):
    payload = {"sessionId": str(item.sessionId)} if item and item.sessionId else {}
    return await access.upstream(f"admin/users/{uid}/revoke-sessions", "POST", token=token, body=payload)


@router.get("/admin/security/rate-limits", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
async def admin_list_rate_limits(token: str = Depends(access_admin.admin_token)):
    return await access.upstream("admin/rate-limits", token=token)


@router.delete("/admin/security/rate-limits", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
async def admin_clear_rate_limits(
    limiter: str | None = Query(default=None, max_length=40),
    keyHash: str | None = Query(default=None, max_length=64),
    key: str | None = Query(default=None, max_length=254),
    body: RateLimitUnlockInput | None = Body(default=None),
    token: str = Depends(access_admin.admin_token),
):
    params = {}
    for name, bval, qval in (
        ("limiter", body.limiter if body else None, limiter),
        ("keyHash", body.keyHash if body else None, keyHash),
        ("key", body.key if body else None, key),
    ):
        val = bval if bval is not None else qval
        if val is not None:
            params[name] = val
    qs = ("?" + urlencode(params)) if params else ""
    return await access.upstream("admin/rate-limits" + qs, "DELETE", token=token)
