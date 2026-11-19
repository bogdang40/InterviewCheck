"""Python implementation of the native /v1 service. Workspace data is never routed here."""
from typing import Literal
from uuid import UUID, uuid4
import os
import sqlite3

from fastapi import APIRouter, Depends, FastAPI, Header, HTTPException, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel
from starlette.concurrency import run_in_threadpool
from starlette.datastructures import Headers

from . import account_admin, account_auth, account_db as db, account_stripe as billing, account_stripe_webhooks as webhooks
from .origin import workspace_client

routes = APIRouter()


class AccountBoundary:
    def __init__(self, app, *, embedded):
        self.app, self.embedded = app, embedded

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        if self.embedded:
            from .access import embedded_enabled
            if not embedded_enabled():
                return await JSONResponse({"detail": "Embedded accounts are disabled."}, status_code=404)(scope, receive, send)
        if scope["method"] in {"POST", "PATCH"}:
            headers = Headers(scope=scope)
            if headers.get("content-type", "").split(";")[0].strip().lower() != "application/json":
                # Existing native callers send logout and portal with an empty body.
                empty_allowed = scope["path"].endswith(("/auth/logout", "/billing/portal"))
                if not empty_allowed:
                    return await JSONResponse({"detail": "A JSON request is required."}, status_code=415)(scope, receive, send)
            data = bytearray()
            while True:
                event = await receive()
                if event["type"] == "http.disconnect":
                    return
                if len(data) + len(event.get("body", b"")) > 256 * 1024:
                    return await JSONResponse({"detail": "Request exceeds 256 KiB."}, status_code=413)(scope, receive, send)
                data.extend(event.get("body", b""))
                if not event.get("more_body"):
                    break
            consumed = False

            async def replay():
                nonlocal consumed
                if consumed:
                    return await receive()
                consumed = True
                return {"type": "http.request", "body": bytes(data), "more_body": False}
            return await self.app(scope, replay, send)
        return await self.app(scope, receive, send)


def identity(authorization: str | None = Header(default=None)):
    return account_auth.authenticate(authorization)


@routes.post("/auth/{action}")
def login(action: Literal["login", "signup", "logout"], request: Request, form: account_auth.Login | None = None):
    if action == "logout":
        user, sid = account_auth.authenticate(request.headers.get("authorization"))
        with db.connection(write=True) as conn:
            conn.execute("UPDATE sessions SET revoked_at=? WHERE id=?", (db.now(), sid))
            db.audit(conn, "auth.logout", user["id"], user["id"])
        return Response(status_code=204)
    if form is None:
        raise HTTPException(422, "Credentials are required.")
    if request.app.state.embedded and form.email != os.getenv("INTERVIEWCHECK_OPERATOR_EMAIL", "").strip().lower():
        raise HTTPException(403, "Use the operator email assigned to this workspace.")
    public = not request.app.state.embedded or bool(os.getenv("INTERVIEWCHECK_PUBLIC_ORIGIN"))
    address = workspace_client(request) if request.app.state.embedded else (request.client.host if request.client else "local")
    result = account_auth.sign_in(action, form, address, public_signup=public)
    return JSONResponse(result, status_code=201 if action == "signup" else 200)


@routes.get("/me")
def me(auth=Depends(identity)):
    user, _ = auth
    with db.connection() as conn:
        return db.snapshot(conn, user)


@routes.get("/billing/plans")
def plans():
    configured = billing.plans()
    return {"configured": bool(configured and os.getenv("STRIPE_SECRET_KEY") and os.getenv("STRIPE_WEBHOOK_SECRET")),
            "plans": list(configured)}


class Checkout(BaseModel):
    plan: Literal["monthly", "annual"]


@routes.post("/billing/checkout")
async def checkout(item: Checkout, auth=Depends(identity), idempotency_key: UUID | None = Header(default=None)):
    return await billing.create_link(auth[0], item.plan, request_id=str(idempotency_key or uuid4()))


@routes.post("/billing/portal")
async def portal(auth=Depends(identity), idempotency_key: UUID | None = Header(default=None)):
    return await billing.create_link(auth[0], portal=True, request_id=str(idempotency_key or uuid4()))


@routes.post("/billing/webhook")
async def webhook(request: Request):
    event = await run_in_threadpool(webhooks.verify, await request.body(), request.headers.get("stripe-signature"))
    return await webhooks.apply(event)


@routes.get("/billing/return")
def back(request: Request):
    link = '<p><a href="/account/">Return to account settings</a></p>' if request.app.state.embedded else ""
    return HTMLResponse("<!doctype html><html lang=en><meta charset=utf-8><title>InterviewCheck billing</title>"
                        "<h1>Return to InterviewCheck</h1><p>Open Account and select Refresh access.</p>" + link)


def service(embedded):
    instance = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    instance.state.embedded = embedded
    instance.add_middleware(AccountBoundary, embedded=embedded)

    @instance.exception_handler(HTTPException)
    async def http_error(_, exc):
        codes = {401: "unauthenticated", 402: "subscription_required", 403: "forbidden", 404: "not_found",
                 409: "conflict", 422: "invalid_input", 429: "rate_limited", 503: "service_unavailable"}
        return JSONResponse({"error": {"code": codes.get(exc.status_code, "request_error"), "message": str(exc.detail)}},
                            status_code=exc.status_code, headers={"Cache-Control": "no-store"})

    @instance.exception_handler(RequestValidationError)
    async def invalid(_, exc):
        fields = [str(error["loc"][-1]) for error in exc.errors() if error.get("loc")]
        return JSONResponse({"error": {"code": "invalid_input", "message": "Check input fields: " + ", ".join(fields)}},
                            status_code=422)

    @instance.middleware("http")
    async def uncached(request, call_next):
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["Referrer-Policy"] = "no-referrer"
        return response
    instance.include_router(routes)
    instance.include_router(account_admin.router)
    return instance


local_service = service(True)
app = FastAPI(title="InterviewCheck accounts", docs_url=None, redoc_url=None, openapi_url=None)
app.mount("/v1", service(False))


@app.get("/health")
def health():
    try:
        db.check_database()
    except (OSError, sqlite3.Error) as error:
        raise HTTPException(503, "Account database is unavailable.") from error
    return {"ok": True, "version": "v1", "billingConfigured": plans()["configured"]}
