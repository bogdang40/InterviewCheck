"""ASGI middleware for CSP, HSTS, Permissions-Policy, and security headers."""
import base64
import hashlib
import os
from pathlib import Path
import re

from starlette.datastructures import Headers, MutableHeaders

from .exports import PRINT_STYLE_HASH
from .origin import browser_origin

_PRINT_PATH_RE = re.compile(r"^/api/sessions/[0-9a-fA-F-]+/print$")
_COMPARE_PRINT_PATH_RE = re.compile(r"^/api/interviews/compare/print$")
_COMPARE_DOSSIER_PATH_RE = re.compile(r"^/api/interviews/compare/dossier$")
_SCRIPT_RE = re.compile(r"<script\b([^>]*)>(.*?)</script>", re.IGNORECASE | re.DOTALL)
_SRC_ATTR_RE = re.compile(r"(?:^|\s)src\s*=", re.IGNORECASE)
_PERMISSIONS = "camera=(), geolocation=(), payment=(), usb=(), microphone=(self), display-capture=(self)"
_API_CSP = "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
_STATIC_ASSET_CSP = "default-src 'none'; frame-ancestors 'none'"
_BILLING_RETURN_CSP = "default-src 'none'; style-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"


class SecurityHeadersMiddleware:
    def __init__(self, app, *, static_dir: Path | None = None, api_service: bool = False) -> None:
        self.app = app
        self.static_dir = static_dir
        self._static_root = static_dir.resolve() if static_dir is not None else None
        self.api_service = api_service
        self._html_hash_cache: dict[Path, tuple[int, tuple[str, ...]]] = {}

    def _resolve_static_html(self, path: str, status: int) -> Path | None:
        if self._static_root is None:
            return None
        if status == 404:
            fallback = self._static_root / "404.html"
            return fallback.resolve() if fallback.is_file() else None
        rel = path.lstrip("/")
        if not rel:
            candidates = [self._static_root / "index.html"]
        else:
            candidates = [
                self._static_root / rel / "index.html",
                self._static_root / rel,
                self._static_root / f"{rel}.html",
            ]
        for candidate in candidates:
            try:
                resolved = candidate.resolve()
            except OSError:
                continue
            if (
                resolved.is_relative_to(self._static_root)
                and resolved.is_file()
                and resolved.suffix.lower() in {".html", ".htm"}
            ):
                return resolved
        return None

    def _script_hashes(self, html_path: Path) -> tuple[str, ...]:
        try:
            mtime_ns = html_path.stat().st_mtime_ns
        except OSError:
            return ()
        cached = self._html_hash_cache.get(html_path)
        if cached is not None and cached[0] == mtime_ns:
            return cached[1]
        try:
            content = html_path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            return ()
        hashes: list[str] = []
        seen: set[str] = set()
        for attrs, body in _SCRIPT_RE.findall(content):
            if _SRC_ATTR_RE.search(attrs) or not body:
                continue
            digest = base64.b64encode(hashlib.sha256(body.encode("utf-8")).digest()).decode("ascii")
            token = f"'sha256-{digest}'"
            if token not in seen:
                seen.add(token)
                hashes.append(token)
        result = tuple(hashes)
        self._html_hash_cache[html_path] = (mtime_ns, result)
        return result

    def _csp_for(self, path: str, status: int, content_type: str, req_headers: Headers, scheme: str) -> str:
        is_print = (
            _PRINT_PATH_RE.fullmatch(path)
            or _COMPARE_PRINT_PATH_RE.fullmatch(path)
            or _COMPARE_DOSSIER_PATH_RE.fullmatch(path)
        )
        if is_print and content_type == "text/html":
            return (
                f"default-src 'none'; script-src 'self'; style-src 'self' '{PRINT_STYLE_HASH}'; "
                "img-src 'none'; font-src 'none'; connect-src 'none'; object-src 'none'; "
                "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
            )
        if path in {"/v1/billing/return", "/billing/return"} and content_type == "text/html":
            return _BILLING_RETURN_CSP
        if self._static_root is not None and not path.startswith(("/api/", "/v1/")) and path != "/health":
            html_path = (
                self._resolve_static_html(path, status)
                if content_type == "text/html"
                else (self._resolve_static_html(path, 200) if status == 304 else None)
            )
            if content_type == "text/html" or html_path is not None:
                hashes = self._script_hashes(html_path) if html_path is not None else ()
                origin = browser_origin(req_headers, scheme)
                if origin:
                    ws_origin = origin.replace("https://", "wss://", 1).replace("http://", "ws://", 1)
                else:
                    ws_origin = "ws: wss:"
                script_src = " ".join(["'self'", *hashes]) if hashes else "'self'"
                return (
                    f"default-src 'self'; script-src {script_src}; style-src 'self' 'unsafe-inline'; "
                    "img-src 'self' data: blob:; font-src 'self'; media-src 'self' blob:; "
                    f"connect-src 'self' {ws_origin}; object-src 'none'; base-uri 'self'; "
                    "form-action 'self'; frame-ancestors 'none'"
                )
            return _STATIC_ASSET_CSP
        return _API_CSP

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        path = scope.get("path", "")
        scheme = scope.get("scheme", "http")
        req_headers = Headers(scope=scope)
        https_mode = bool(os.getenv("INTERVIEWCHECK_PUBLIC_ORIGIN", "").strip()) or scheme == "https"

        async def send_with_headers(message) -> None:
            if message["type"] == "http.response.start":
                raw_headers = list(message.get("headers", []))
                headers = MutableHeaders(raw=raw_headers)
                status = int(message.get("status", 200))
                content_type = headers.get("content-type", "").split(";")[0].strip().lower()
                headers["X-Content-Type-Options"] = "nosniff"
                headers["X-Frame-Options"] = "DENY"
                headers["Referrer-Policy"] = "no-referrer"
                headers["Permissions-Policy"] = _PERMISSIONS
                headers["Content-Security-Policy"] = self._csp_for(path, status, content_type, req_headers, scheme)
                if self.api_service or path.startswith(("/api/", "/v1/")) or path == "/health":
                    headers["Cache-Control"] = "no-store"
                if https_mode:
                    headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
                message["headers"] = raw_headers
            await send(message)

        await self.app(scope, receive, send_with_headers)
