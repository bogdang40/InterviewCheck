#!/usr/bin/env python3
"""Verify InterviewCheck edge security controls against ASGI or a live base URL."""
from __future__ import annotations

import argparse
import asyncio
from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
import sys
import tempfile
from typing import Any

import httpx

ROOT = Path(__file__).resolve().parent.parent
PORTABLE = ROOT / "portable"
if str(PORTABLE) not in sys.path:
    sys.path.insert(0, str(PORTABLE))


@dataclass(frozen=True)
class EdgeCheck:
    id: str
    ok: bool
    status: int
    detail: str


def _rec(results: list[EdgeCheck], cid: str, ok: bool, status: int, detail: str) -> None:
    results.append(EdgeCheck(id=cid, ok=bool(ok), status=int(status), detail=detail))


def _app_unreached(response: httpx.Response) -> bool:
    """True for the empty reply Caddy gives a host it does not serve; the app labels every reply it sends."""
    return response.status_code < 500 and not response.content and "permissions-policy" not in response.headers


async def run_edge_checks(client: httpx.AsyncClient, *, mode: str, target: str, edge: bool = False) -> dict[str, Any]:
    """With edge=True the target is the public Caddy edge, which answers some probes before the app can:
    it serves only its own host name and replaces X-Forwarded-Host and X-InterviewCheck-Client-IP."""
    results: list[EdgeCheck] = []

    r_cors_cross = await client.options(
        "/api/health", headers={"Origin": "https://evil.example", "Access-Control-Request-Method": "POST"},
    )
    acao_cross = r_cors_cross.headers.get("access-control-allow-origin")
    _rec(results, "cors_preflight_cross_origin", r_cors_cross.status_code == 403 and acao_cross is None,
         r_cors_cross.status_code, f"OPTIONS cross-origin preflight returned {r_cors_cross.status_code} (ACAO={acao_cross!r}).")

    r_cors_same = await client.options("/api/health", headers={"Access-Control-Request-Method": "POST"})
    acao_same = r_cors_same.headers.get("access-control-allow-origin")
    pre_note = " Pre-M21-W3 ASGI returns 405 before explicit preflight guard lands." if r_cors_same.status_code == 405 else ""
    _rec(results, "cors_preflight_strict", r_cors_same.status_code == 403 and acao_same is None,
         r_cors_same.status_code, f"OPTIONS preflight returned {r_cors_same.status_code} (ACAO={acao_same!r}).{pre_note}")

    r_host = await client.get("/api/health", headers={"Host": "evil.example"})
    host_ok = r_host.status_code == 400 or (edge and _app_unreached(r_host))
    _rec(results, "host_injection", host_ok, r_host.status_code,
         f"Invalid Host header returned {r_host.status_code} (expected 400{', or an empty reply from the edge' if edge else ''}).")

    r_origin = await client.post("/api/sessions", json={}, headers={"Origin": "https://evil.example", "X-InterviewCheck": "1"})
    _rec(results, "origin_spoofing", r_origin.status_code == 403, r_origin.status_code,
         f"Spoofed Origin POST returned {r_origin.status_code} (expected 403).")

    r_csrf = await client.post("/api/sessions", json={})
    _rec(results, "csrf_header_enforcement", r_csrf.status_code == 403, r_csrf.status_code,
         f"POST without X-InterviewCheck header returned {r_csrf.status_code} (expected 403).")

    # At the edge a 200 means the proxy replaced the spoofed header; a spoofed value reaching the app is a 400.
    proxy_ok = {200, 400} if edge else {400}
    r_dup_comma = await client.get("/api/health", headers={"X-Forwarded-Host": "127.0.0.1:3000, evil.example"})
    _rec(results, "duplicate_proxy_header_comma", r_dup_comma.status_code in proxy_ok, r_dup_comma.status_code,
         f"Comma-joined X-Forwarded-Host returned {r_dup_comma.status_code} (expected {' or '.join(map(str, sorted(proxy_ok)))}).")

    r_dup_host = await client.get("/api/health", headers=[("x-forwarded-host", "127.0.0.1:3000"), ("x-forwarded-host", "evil.example")])
    host_note = " Pre-M21-W3 ASGI reads first header only." if r_dup_host.status_code == 200 else ""
    _rec(results, "duplicate_proxy_header_multi_host", r_dup_host.status_code in proxy_ok, r_dup_host.status_code,
         f"Duplicate X-Forwarded-Host headers returned {r_dup_host.status_code} (expected {' or '.join(map(str, sorted(proxy_ok)))}).{host_note}")

    r_dup_ip = await client.get("/api/health", headers=[("x-interviewcheck-client-ip", "203.0.113.10"), ("x-interviewcheck-client-ip", "203.0.113.11")])
    ip_note = " Pre-M21-W3 ASGI reads first header only." if r_dup_ip.status_code == 200 else ""
    _rec(results, "duplicate_proxy_header_multi_ip", r_dup_ip.status_code in proxy_ok, r_dup_ip.status_code,
         f"Duplicate X-InterviewCheck-Client-IP headers returned {r_dup_ip.status_code} (expected {' or '.join(map(str, sorted(proxy_ok)))}).{ip_note}")

    r_ok = await client.get("/api/health")
    hdrs = r_ok.headers
    missing: list[str] = []
    if hdrs.get("x-content-type-options") != "nosniff":
        missing.append("X-Content-Type-Options=nosniff")
    if hdrs.get("x-frame-options") != "DENY":
        missing.append("X-Frame-Options=DENY")
    if hdrs.get("referrer-policy") != "no-referrer":
        missing.append("Referrer-Policy=no-referrer")
    if not (hdrs.get("permissions-policy") or "").strip():
        missing.append("Permissions-Policy")
    if "frame-ancestors 'none'" not in (hdrs.get("content-security-policy") or ""):
        missing.append("Content-Security-Policy(frame-ancestors 'none')")
    if "access-control-allow-origin" in hdrs:
        missing.append("unexpected Access-Control-Allow-Origin")
    if edge and "max-age=" not in (hdrs.get("strict-transport-security") or ""):
        missing.append("Strict-Transport-Security")
    if edge and "server" in hdrs:
        missing.append("unexpected Server")
    _rec(
        results, "mandatory_security_headers", r_ok.status_code == 200 and not missing, r_ok.status_code,
        "All mandatory security headers verified." if (r_ok.status_code == 200 and not missing)
        else f"Header issues: {', '.join(missing) or f'status={r_ok.status_code}'}",
    )

    if edge:
        # The page's own CSP (with its script hashes) must reach the browser, not the proxy's default.
        r_page = await client.get("/")
        page_csp = r_page.headers.get("content-security-policy") or ""
        _rec(results, "edge_keeps_app_csp", r_page.status_code == 200 and "script-src" in page_csp, r_page.status_code,
             "The home page carries the app's Content-Security-Policy." if "script-src" in page_csp
             else f"The home page CSP is not the app's: {page_csp!r}.")

    errors = [f"{item.id}: {item.detail}" for item in results if not item.ok]
    return {"ok": not errors, "mode": mode, "target": target, "checks": [asdict(item) for item in results], "errors": errors}


async def _run_asgi_async(app_obj: Any = None) -> dict[str, Any]:
    from api import store  # noqa: E402

    if app_obj is None:
        from api import main  # noqa: E402
        app_obj = main.app

    prev_db = os.environ.get("INTERVIEWCHECK_DB")
    tmp_dir: tempfile.TemporaryDirectory[str] | None = None
    try:
        if not prev_db:
            tmp_dir = tempfile.TemporaryDirectory(prefix="ic-edge-asgi-")
            os.environ["INTERVIEWCHECK_DB"] = str(Path(tmp_dir.name) / "review.sqlite3")
        if not store.db_path().is_file():
            store.initialize(store.db_path())
        # ASGITransport does not run the app's startup, which prepares the account database in
        # embedded mode; /api/health (a mandatory-header check target) requires it.
        from api.access import embedded_enabled  # noqa: E402
        if embedded_enabled():
            from api.account_db import check_database  # noqa: E402
            check_database()
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app_obj), base_url="http://127.0.0.1", timeout=10.0) as client:
            return await run_edge_checks(client, mode="asgi", target="api.main:app")
    finally:
        if tmp_dir is not None:
            if prev_db is None:
                os.environ.pop("INTERVIEWCHECK_DB", None)
            else:
                os.environ["INTERVIEWCHECK_DB"] = prev_db
            tmp_dir.cleanup()


async def _run_base_url_async(base_url: str, edge: bool = False) -> dict[str, Any]:
    target = base_url.rstrip("/")
    async with httpx.AsyncClient(base_url=target, timeout=10.0, follow_redirects=False) as client:
        return await run_edge_checks(client, mode="edge" if edge else "base-url", target=target, edge=edge)


def run_asgi(app_obj: Any = None) -> dict[str, Any]:
    return asyncio.run(_run_asgi_async(app_obj))


def run_base_url(base_url: str, edge: bool = False) -> dict[str, Any]:
    return asyncio.run(_run_base_url_async(base_url, edge))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Verify InterviewCheck edge security controls.")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--base-url", help="Target live server base URL (e.g. http://127.0.0.1:8000).")
    group.add_argument("--asgi", action="store_true", help="Run checks directly against FastAPI ASGI app.")
    parser.add_argument("--edge", action="store_true",
                        help="With --base-url: the target is the public HTTPS edge (Caddy) in front of the app.")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON report.")
    args = parser.parse_args(argv)
    if args.edge and not args.base_url:
        parser.error("--edge requires --base-url")

    try:
        report = run_asgi() if args.asgi else run_base_url(args.base_url, edge=args.edge)
    except httpx.HTTPError as exc:
        report = {"ok": False, "mode": "base-url", "target": args.base_url, "checks": [], "errors": [f"HTTP error ({type(exc).__name__}): {exc}"]}

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        for item in report["checks"]:
            print(f"[{'PASS' if item['ok'] else 'FAIL'}] {item['id']}: {item['detail']}")
        for err in report["errors"]:
            if not report["checks"]:
                print(f"[FAIL] {err}")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
