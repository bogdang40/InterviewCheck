"""Same origin access to the single operator service on the loopback interface."""
from .origin import browser_origin

from starlette.datastructures import Headers
from starlette.responses import JSONResponse


class LocalBoundary:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        headers = Headers(scope=scope)
        expected = browser_origin(headers, scope["scheme"])

        async def reject(status, detail):
            await JSONResponse({"detail": detail}, status_code=status)(scope, receive, send)

        if expected is None:
            await reject(400, "Open InterviewCheck on its local address.")
            return
        origin = headers.get("origin")
        if origin and origin != expected:
            await reject(403, "The request must originate from this workspace.")
            return
        mutating = scope["method"] not in {"GET", "HEAD", "OPTIONS"}
        path = scope["path"]
        csrf_guarded = path.startswith("/api/") or (path.startswith("/v1/") and path != "/v1/billing/webhook")
        if mutating and csrf_guarded:
            if headers.get("x-interviewcheck") != "1":
                await reject(403, "Missing workspace request header.")
                return
            limit = 24 * 1024 ** 2 if path == "/api/integrations/transcribe" else 2 * 1024 ** 2
            if path.startswith("/v1/"):
                limit = 256 * 1024
            elif path in {"/api/backups/preview", "/api/backups/restore"}:
                from .backup_schema import LIMIT
                limit = LIMIT
            try:
                declared = int(headers.get("content-length", "0"))
            except ValueError:
                await reject(400, "Invalid content length.")
                return
            if declared < 0 or declared > limit:
                await reject(413, "Input exceeds the size limit.")
                return
            # Enforce the same limit on requests sent without Content-Length.
            data = bytearray()
            while True:
                message = await receive()
                if message["type"] == "http.disconnect":
                    return
                chunk = message.get("body", b"")
                if len(data) + len(chunk) > limit:
                    await reject(413, "Input exceeds the size limit.")
                    return
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
            await self.app(scope, body, send)
            return
        await self.app(scope, receive, send)
