"""Single operator membership using the native access service."""
from typing import Literal
from urllib.parse import urlsplit

from fastapi import APIRouter, HTTPException, Request, Response
from pydantic import BaseModel, Field, SecretStr
from starlette.requests import HTTPConnection

from .provider_http import configured, fetch_json, setting

router = APIRouter()
COOKIE = "ic_access"


def access_url(path: str) -> str:
    root = setting("INTERVIEWCHECK_ACCESS_URL").rstrip("/")
    parsed = urlsplit(root)
    local = parsed.hostname in {"127.0.0.1", "localhost", "::1"}
    if parsed.username or parsed.password or parsed.query or parsed.fragment or not (
        parsed.scheme == "https" or (parsed.scheme == "http" and local)
    ):
        raise HTTPException(503, "The access service requires HTTPS or a local HTTP address.")
    return root + "/v1/" + path


async def upstream(path, method="GET", *, token=None, body=None):
    options = {"headers": {"Authorization": f"Bearer {token}"}} if token else {}
    if body is not None:
        options["json"] = body
    return await fetch_json("Access service", method, access_url(path), **options)


def verify_operator(snapshot):
    email = (snapshot.get("user") or {}).get("email", "")
    if not email or email.casefold() != setting("INTERVIEWCHECK_OPERATOR_EMAIL").casefold():
        raise HTTPException(403, "Sign in with the operator account assigned to this workstation.")


async def snapshot(connection: HTTPConnection):
    token = connection.cookies.get(COOKIE)
    if not token:
        raise HTTPException(401, "Sign in under Connections.")
    result = await upstream("me", token=token)
    if not isinstance(result, dict) or not isinstance(result.get("user"), dict):
        raise HTTPException(502, "The access service returned an invalid account.")
    verify_operator(result)
    return result


async def require_entitlement(request: HTTPConnection):
    if configured("INTERVIEWCHECK_ACCESS_URL"):
        account = await snapshot(request)
        if (account.get("entitlement") or {}).get("active") is not True:
            raise HTTPException(402, "An active InterviewCheck plan is required.")


class Credentials(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    password: SecretStr = Field(min_length=10, max_length=200)


class Checkout(BaseModel):
    plan: Literal["monthly", "annual"]


@router.post("/access/{action}")
async def sign_in(action: Literal["login", "signup"], form: Credentials, request: Request, response: Response):
    verify_operator({"user": {"email": form.email.strip()}})
    data = await upstream("auth/" + action, "POST", body={
        "email": form.email.strip(), "password": form.password.get_secret_value(), "deviceName": "Portable workspace"
    })
    if not isinstance(data, dict) or not isinstance(data.get("token"), str) or not data["token"]:
        raise HTTPException(502, "The access service returned an invalid session.")
    verify_operator(data)
    response.set_cookie(COOKIE, data["token"], httponly=True, secure=request.url.scheme == "https", samesite="strict", path="/api")
    return {"email": data["user"]["email"], "active": data["entitlement"]["active"]}


@router.get("/account")
async def account(request: Request):
    data = await snapshot(request)
    return {"email": data["user"]["email"], "active": data["entitlement"]["active"]}


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


@router.post("/billing/{action}")
async def billing(action: Literal["checkout", "portal"], request: Request, form: Checkout | None = None):
    await snapshot(request)
    if action == "checkout" and form is None:
        raise HTTPException(422, "Select a plan.")
    data = await upstream("billing/" + action, "POST", token=request.cookies[COOKIE], body=form.model_dump() if form else {})
    url = data.get("url", "") if isinstance(data, dict) else ""
    parsed = urlsplit(url)
    if parsed.scheme != "https" or parsed.hostname not in {"checkout.stripe.com", "billing.stripe.com"}:
        raise HTTPException(502, "The access service returned an invalid Stripe link.")
    return {"url": url}
