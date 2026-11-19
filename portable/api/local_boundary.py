"""Same origin access to the single operator service on the loopback interface."""
from fastapi import HTTPException
from starlette.datastructures import Headers
from starlette.requests import cookie_parser
from starlette.responses import JSONResponse

from .access import COOKIE, account_enabled
from .origin import browser_origin

_EARLY_AUTH_BYTES = 256 * 1024


def _has_access_cookie(headers: Headers) -> bool:
    raw = headers.get("cookie")
    return bool(raw and cookie_parser(raw).get(COOKIE, "").strip())


def _early_cookie_error(headers: Headers) -> tuple[int, str] | None:
    try:
        if account_enabled() and not _has_access_cookie(headers):
            return (401, "Sign in under Account.")
    except HTTPException as exc:
        return (exc.status_code, str(exc.detail))
    return None


class LocalBoundary:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        headers = Headers(scope=scope)
        expected = browser_origin(headers, scope["scheme"])

        async def reject(status, detail):
            await JSONResponse({"detail": detail}, status_code=status)(scope, receive, send)

        if expected is None:
            return await reject(400, "Open InterviewCheck on its local address.")
        origin = headers.get("origin")
        if origin and origin != expected:
            return await reject(403, "The request must originate from this workspace.")
        mutating = scope["method"] not in {"GET", "HEAD", "OPTIONS"}
        path = scope["path"]
        csrf_guarded = path.startswith("/api/") or (path.startswith("/v1/") and path != "/v1/billing/webhook")
        if mutating and csrf_guarded:
            if headers.get("x-interviewcheck") != "1":
                return await reject(403, "Missing workspace request header.")
            limit = 24 * 1024 ** 2 if path == "/api/integrations/transcribe" else 2 * 1024 ** 2
            if path.startswith("/v1/"):
                limit = _EARLY_AUTH_BYTES
            elif path in {"/api/backups/preview", "/api/backups/restore"}:
                from .backup_schema import LIMIT
                limit = LIMIT
            try:
                declared = int(headers.get("content-length", "0"))
            except ValueError:
                return await reject(400, "Invalid content length.")
            if declared < 0 or declared > limit:
                return await reject(413, "Input exceeds the size limit.")
            workspace_guarded = path.startswith("/api/") and not path.startswith("/api/integrations/access/")
            checked_large = False
            if workspace_guarded and declared > _EARLY_AUTH_BYTES:
                checked_large = True
                if err := _early_cookie_error(headers):
                    return await reject(*err)
            # Enforce the same limit on requests sent without Content-Length.
            data = bytearray()
            while True:
                message = await receive()
                if message["type"] == "http.disconnect":
                    return
                chunk = message.get("body", b"")
                if not checked_large and workspace_guarded and len(data) + len(chunk) > _EARLY_AUTH_BYTES:
                    checked_large = True
                    if err := _early_cookie_error(headers):
                        return await reject(*err)
                if len(data) + len(chunk) > limit:
                    return await reject(413, "Input exceeds the size limit.")
                data.extend(chunk)
                if not message.get("more_body"):
                    break

            consumed = False

            async def body():
                nonlocal consumed
                if consumed:
                    return await receive()
                consumed = True
                return {"type": "http.request", "body": bytes(data), "more_body": False}
            return await self.app(scope, body, send)
        return await self.app(scope, receive, send)
