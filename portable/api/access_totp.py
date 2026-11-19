"""Cookie-authenticated TOTP 2FA proxy routes for /api/integrations/security/totp/*."""
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse

from . import access, rate_limit
from .totp_service import TotpCodeInput, TotpDisableInput

router = APIRouter(prefix="/security/totp")


async def _user_session(request: Request) -> tuple[str, str]:
    if not access.account_enabled():
        raise HTTPException(503, "Account security requires embedded or remote access mode.")
    token = request.cookies.get(access.COOKIE)
    if not token:
        raise HTTPException(401, "Sign in under Account.")
    account = await access.snapshot(request)
    user = account.get("user") if isinstance(account, dict) else None
    user_id = str((user or {}).get("id") or (user or {}).get("email") or "")
    return token, user_id


async def _user_token(session: tuple[str, str] = Depends(_user_session)) -> str:
    return session[0]


async def _totp_action_token(session: tuple[str, str] = Depends(_user_session)) -> str:
    token, user_id = session
    if not access.embedded_enabled():
        rate_limit.require_limit(rate_limit.TOTP_ACTION, f"totp_proxy:{user_id}")
    return token


@router.get("/status")
async def totp_status(token: str = Depends(_user_token)):
    data = await access.upstream("auth/totp/status", token=token)
    return JSONResponse(data, headers={"Cache-Control": "no-store"})


@router.post("/setup")
async def totp_setup(token: str = Depends(_user_token)):
    data = await access.upstream("auth/totp/setup", "POST", token=token, body={})
    return JSONResponse(data, headers={"Cache-Control": "no-store"})


@router.post("/verify")
async def totp_verify(item: TotpCodeInput, token: str = Depends(_totp_action_token)):
    data = await access.upstream("auth/totp/verify", "POST", token=token, body={"code": item.code})
    return JSONResponse(data, headers={"Cache-Control": "no-store"})


@router.post("/disable")
async def totp_disable(item: TotpDisableInput, token: str = Depends(_totp_action_token)):
    data = await access.upstream(
        "auth/totp/disable",
        "POST",
        token=token,
        body={"currentPassword": item.currentPassword.get_secret_value(), "code": item.code},
    )
    return JSONResponse(data, headers={"Cache-Control": "no-store"})


@router.post("/backup-codes/regenerate")
async def totp_regenerate(item: TotpCodeInput, token: str = Depends(_totp_action_token)):
    data = await access.upstream("auth/totp/backup-codes/regenerate", "POST", token=token, body={"code": item.code})
    return JSONResponse(data, headers={"Cache-Control": "no-store"})
