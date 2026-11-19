"""Account membership and entitlement verification using the access service."""
import os
from typing import Any, Literal
from uuid import UUID, uuid4

from urllib.parse import urlsplit

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field, SecretStr
from starlette.requests import HTTPConnection

from . import rate_limit
from .error_sanitizer import sanitize_error_text
from .provider_http import configured, fetch_json, setting

router = APIRouter()
COOKIE = "ic_access"


def embedded_enabled():
    return os.getenv("INTERVIEWCHECK_ACCESS_MODE", "").strip().lower() == "embedded"


def production_mode() -> bool:
    return configured("INTERVIEWCHECK_PUBLIC_ORIGIN") or os.getenv("INTERVIEWCHECK_PRODUCTION", "").strip().lower() in {"1", "true", "yes"}


def account_enabled():
    mode = os.getenv("INTERVIEWCHECK_ACCESS_MODE", "").strip().lower()
    if mode not in {"", "embedded", "remote"} or (mode == "embedded" and configured("INTERVIEWCHECK_ACCESS_URL")):
        raise HTTPException(503, "Choose embedded accounts or an external access URL.")
    if mode == "remote" and not configured("INTERVIEWCHECK_ACCESS_URL"):
        raise HTTPException(503, "Configure the remote access URL.")
    return embedded_enabled() or configured("INTERVIEWCHECK_ACCESS_URL")


def access_url(path: str) -> str:
    root = setting("INTERVIEWCHECK_ACCESS_URL").rstrip("/")
    parsed = urlsplit(root)
    local = parsed.hostname in {"127.0.0.1", "localhost", "::1"}
    if parsed.username or parsed.password or parsed.query or parsed.fragment or not (
        parsed.scheme == "https" or (parsed.scheme == "http" and local)
    ):
        raise HTTPException(503, "The access service requires HTTPS or a local HTTP address.")
    return root + "/v1/" + path


async def upstream(path, method="GET", *, token=None, body=None, idempotency=None, client_address=None):
    headers: dict[str, str] = {"X-InterviewCheck": "1"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if idempotency:
        headers["Idempotency-Key"] = idempotency
    options: dict[str, Any] = {"headers": headers}
    if body is not None:
        options["json"] = body
    if account_enabled() and embedded_enabled():
        import httpx
        from .account_server import local_service
        transport = httpx.ASGITransport(app=local_service, client=(client_address or "127.0.0.1", 0))
        async with httpx.AsyncClient(transport=transport, base_url="http://127.0.0.1") as client:
            response = await client.request(method, "/" + path, **options)
        data = response.json() if response.content else {}
        if response.is_error:
            raw_msg = data.get("error", {}).get("message") or data.get("detail") or "Account request failed."
            raise HTTPException(response.status_code, sanitize_error_text(raw_msg, "Account request failed."))
        return data
    return await fetch_json("Access service", method, access_url(path), **options)


def verify_operator_email(email):
    if not configured("INTERVIEWCHECK_OPERATOR_EMAIL"):
        return
    if not isinstance(email, str) or email.casefold() != setting("INTERVIEWCHECK_OPERATOR_EMAIL").casefold():
        raise HTTPException(403, "Sign in with the operator account assigned to this workstation.")


def public_remote():
    return configured("INTERVIEWCHECK_PUBLIC_ORIGIN") and not embedded_enabled()


def operator_id():
    try:
        return str(UUID(os.getenv("INTERVIEWCHECK_OPERATOR_ID", "").strip()))
    except ValueError as error:
        raise ValueError("A public workspace with remote access requires INTERVIEWCHECK_OPERATOR_ID as a UUID.") from error


def verify_account(data):
    user = data.get("user") if isinstance(data, dict) else None
    entitlement = data.get("entitlement") if isinstance(data, dict) else None
    if not isinstance(user, dict) or not isinstance(entitlement, dict) or type(entitlement.get("active")) is not bool:
        raise HTTPException(502, "The access service returned an invalid account.")
    verify_operator_email(user.get("email"))
    if public_remote() and (configured("INTERVIEWCHECK_OPERATOR_ID") or configured("INTERVIEWCHECK_OPERATOR_EMAIL")) and user.get("id") != operator_id():
        raise HTTPException(403, "Sign in with the operator account assigned to this workstation.")


async def snapshot(connection: HTTPConnection):
    token = connection.cookies.get(COOKIE)
    if not token:
        raise HTTPException(401, "Sign in under Account.")
    result = await upstream("me", token=token)
    verify_account(result)
    return result


async def require_entitlement(request: HTTPConnection):
    if not account_enabled():
        if production_mode():
            raise HTTPException(503, "Configure embedded or remote account authentication in production mode.")
        return
    account = await snapshot(request)
    if (account.get("entitlement") or {}).get("active") is not True:
        raise HTTPException(402, "An active InterviewCheck plan is required.")


async def require_admin_session(request: HTTPConnection) -> tuple[dict[str, Any], str]:
    token = request.cookies.get(COOKIE)
    if not token:
        raise HTTPException(401, "Sign in with an administrator account.")
    enabled = account_enabled()
    if not enabled or embedded_enabled():
        from . import account_auth, account_db
        if not account_db.database().is_file():
            raise HTTPException(401, "Sign in with an administrator account.")
        user, _ = account_auth.authenticate(f"Bearer {token}")
        if user.get("disabled"):
            raise HTTPException(401, "Session expired. Sign in again.")
        if enabled:
            verify_operator_email(user.get("email"))
    else:
        data = await upstream("me", token=token)
        if not isinstance(data, dict) or not isinstance(data.get("user"), dict):
            raise HTTPException(502, "The access service returned an invalid account.")
        user = data["user"]
        if user.get("disabled"):
            raise HTTPException(401, "Session expired. Sign in again.")
        if public_remote() or configured("INTERVIEWCHECK_OPERATOR_EMAIL") or configured("INTERVIEWCHECK_OPERATOR_ID"):
            verify_account(data)
    if user.get("role") != "admin":
        raise HTTPException(403, "Admin access required.")
    return user, token


class Credentials(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    password: SecretStr = Field(min_length=10, max_length=200)
    adminSecret: SecretStr | None = Field(default=None, max_length=200)
    inviteCode: SecretStr | None = Field(default=None, max_length=200)


class PasswordChangeRequest(BaseModel):
    currentPassword: SecretStr = Field(min_length=10, max_length=200)
    newPassword: SecretStr = Field(min_length=10, max_length=200)


class Checkout(BaseModel):
    plan: Literal["monthly", "annual"] | None = None


def _set_access_cookie(response: Response, request: Request, token: str) -> None:
    secure = bool(os.getenv("INTERVIEWCHECK_PUBLIC_ORIGIN")) or request.url.scheme == "https"
    response.set_cookie(COOKIE, token, httponly=True, secure=secure, samesite="strict", path="/api")


@router.post("/access/password")
async def change_password(form: PasswordChangeRequest, request: Request, response: Response):
    token = request.cookies.get(COOKIE)
    if not token:
        raise HTTPException(401, "Sign in under Account.")
    from .origin import workspace_client
    data = await upstream(
        "auth/password",
        "POST",
        token=token,
        body={"currentPassword": form.currentPassword.get_secret_value(), "newPassword": form.newPassword.get_secret_value()},
        client_address=workspace_client(request) if embedded_enabled() else None,
    )
    if not isinstance(data, dict) or not isinstance(data.get("token"), str) or not data["token"]:
        raise HTTPException(502, "The access service returned an invalid session.")
    verify_account(data)
    _set_access_cookie(response, request, data["token"])
    return {"email": data["user"]["email"], "active": data["entitlement"]["active"],
            **({"admin": True} if data["user"].get("role") == "admin" else {})}


@router.post("/access/{action}")
async def sign_in(action: Literal["login", "signup"], form: Credentials, request: Request, response: Response):
    if action == "signup" and public_remote():
        raise HTTPException(403, "Create the operator account on the assigned access service first.")
    verify_operator_email(form.email.strip())
    from .origin import workspace_client
    data = await upstream("auth/" + action, "POST", body={
        "email": form.email.strip(), "password": form.password.get_secret_value(), "deviceName": "Portable workspace",
        **({"inviteCode": form.inviteCode.get_secret_value()} if form.inviteCode else {}),
        **({"adminSecret": form.adminSecret.get_secret_value()} if form.adminSecret else {})
    }, client_address=workspace_client(request) if embedded_enabled() else None)
    if not isinstance(data, dict) or not isinstance(data.get("token"), str) or not data["token"]:
        raise HTTPException(502, "The access service returned an invalid session.")
    verify_account(data)
    _set_access_cookie(response, request, data["token"])
    return {"email": data["user"]["email"], "active": data["entitlement"]["active"],
            **({"admin": True} if data["user"].get("role") == "admin" else {})}


@router.get("/account")
async def account(request: Request):
    data = await snapshot(request)
    return {"email": data["user"]["email"], "active": data["entitlement"]["active"],
            **({"admin": True} if data["user"].get("role") == "admin" else {})}


@router.get("/plans")
async def available_plans(request: Request):
    await snapshot(request)
    data = await upstream("billing/plans")
    return {"configured": data.get("configured") is True, "plans": [p for p in data.get("plans", []) if p in ("monthly", "annual")]}


@router.post("/logout")
async def logout(request: Request, response: Response):
    token = request.cookies.get(COOKIE)
    if token:
        try:
            await upstream("auth/logout", "POST", token=token)
        except HTTPException as error:
            if error.status_code != 401:
                raise
    response.delete_cookie(COOKIE, path="/api")
    return {"signed_out": True}


@router.post("/billing/{action}", dependencies=[Depends(rate_limit.limit(rate_limit.BILLING_ACTION))])
async def billing(action: Literal["checkout", "portal"], request: Request, form: Checkout | None = None):
    await snapshot(request)
    if action == "checkout" and (form is None or form.plan is None):
        raise HTTPException(422, "Select a plan.")
    from .account_stripe import browser_return_origin
    from .origin import browser_origin
    scope = browser_return_origin.set(browser_origin(request.headers, request.url.scheme))
    try:
        data = await upstream("billing/" + action, "POST", token=request.cookies[COOKIE],
                              body=form.model_dump(exclude_none=True) if form else {},
                              idempotency=request.headers.get("idempotency-key") or str(uuid4()))
    finally:
        browser_return_origin.reset(scope)
    url = data.get("url", "") if isinstance(data, dict) else ""
    parsed = urlsplit(url)
    if parsed.scheme != "https" or parsed.hostname not in {"checkout.stripe.com", "billing.stripe.com"}:
        raise HTTPException(502, "The access service returned an invalid Stripe link.")
    return {"url": url}
