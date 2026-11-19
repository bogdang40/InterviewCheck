"""Tests for M21-W3: duplicate proxy header rejection and strict CORS preflight denial."""
import asyncio

from fastapi.testclient import TestClient
import httpx
import pytest

from api import account_db, local_boundary, origin
from api.main import app


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    for key in (
        "INTERVIEWCHECK_ACCESS_MODE",
        "INTERVIEWCHECK_ACCESS_URL",
        "INTERVIEWCHECK_OPERATOR_EMAIL",
        "INTERVIEWCHECK_OPERATOR_ID",
        "INTERVIEWCHECK_PUBLIC_ORIGIN",
        "INTERVIEWCHECK_PRODUCTION",
        "INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP",
    ):
        monkeypatch.delenv(key, raising=False)
    with TestClient(app, base_url="http://127.0.0.1:8000", headers={"X-InterviewCheck": "1"}) as client:
        yield client


def _run_boundary(method: str, path: str, raw_headers: list[tuple[bytes, bytes]], scheme: str = "http") -> tuple[int, dict[str, str], bytes]:
    sent: list[dict] = []

    async def inner(scope, receive, send):
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b'{"ok":true}'})

    async def run():
        mw = local_boundary.LocalBoundary(inner)
        scope = {"type": "http", "method": method, "scheme": scheme, "path": path, "headers": raw_headers}

        async def receive():
            return {"type": "http.disconnect"}

        async def send(msg):
            sent.append(msg)

        await mw(scope, receive, send)

    asyncio.run(run())
    start = sent[0]
    headers = {k.decode().lower(): v.decode() for k, v in start.get("headers", [])}
    body = sent[1].get("body", b"") if len(sent) > 1 else b""
    return int(start["status"]), headers, body


def test_duplicate_or_comma_proxy_headers_rejected_with_400(env, monkeypatch):
    # Multiple X-Forwarded-Host headers (even identical) rejected with 400
    status_dup_host, _, _ = _run_boundary(
        "GET",
        "/api/health",
        [
            (b"host", b"127.0.0.1:8000"),
            (b"x-forwarded-host", b"localhost:3000"),
            (b"x-forwarded-host", b"localhost:3000"),
        ],
    )
    assert status_dup_host == 400

    status_smuggled_host, _, _ = _run_boundary(
        "GET",
        "/api/health",
        [
            (b"host", b"127.0.0.1:8000"),
            (b"x-forwarded-host", b"localhost:3000"),
            (b"x-forwarded-host", b"evil.example"),
        ],
    )
    assert status_smuggled_host == 400

    # Comma-separated X-Forwarded-Host rejected with 400
    assert env.get("/api/health", headers={"X-Forwarded-Host": "localhost:3000, evil.example"}).status_code == 400
    assert env.get("/v1/billing/plans", headers={"X-Forwarded-Host": "localhost:3000,evil.example"}).status_code == 400

    # Multiple X-InterviewCheck-Client-IP headers rejected with 400 (both with and without TRUST_PROXY_CLIENT_IP)
    for trusted in ("0", "1"):
        monkeypatch.setenv("INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP", trusted)
        status_dup_ip, _, _ = _run_boundary(
            "POST",
            "/v1/auth/login",
            [
                (b"host", b"127.0.0.1:8000"),
                (b"x-interviewcheck", b"1"),
                (b"x-interviewcheck-client-ip", b"198.51.100.1"),
                (b"x-interviewcheck-client-ip", b"198.51.100.2"),
            ],
        )
        assert status_dup_ip == 400

    # Comma-separated X-InterviewCheck-Client-IP rejected with 400
    assert env.get("/api/health", headers={"X-InterviewCheck-Client-IP": "198.51.100.1, 198.51.100.2"}).status_code == 400
    assert env.post(
        "/v1/auth/login",
        json={"email": "a@example.test", "password": "long-password-1"},
        headers={"X-InterviewCheck-Client-IP": "198.51.100.1,198.51.100.2"},
    ).status_code == 400

    # Full ASGI app rejects multi-header requests via httpx
    async def run_asgi_multi():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://127.0.0.1:8000") as ac:
            r1 = await ac.get(
                "/api/health",
                headers=[("x-forwarded-host", "localhost:3000"), ("x-forwarded-host", "evil.example")],
            )
            r2 = await ac.get(
                "/api/health",
                headers=[("x-interviewcheck-client-ip", "198.51.100.1"), ("x-interviewcheck-client-ip", "198.51.100.2")],
            )
            return r1.status_code, r2.status_code

    assert asyncio.run(run_asgi_multi()) == (400, 400)


def test_single_valid_proxy_headers_and_workspace_client_still_work(env, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("INTERVIEWCHECK_PUBLIC_ORIGIN", "https://review.example.test")
    monkeypatch.setenv("INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP", "1")

    with TestClient(
        app,
        base_url="https://127.0.0.1:8000",
        client=("127.0.0.1", 52000),
        headers={
            "Origin": "https://review.example.test",
            "X-Forwarded-Host": "review.example.test",
            "X-InterviewCheck-Client-IP": "198.51.100.42",
            "X-InterviewCheck": "1",
        },
    ) as pub:
        ok = pub.get("/api/health")
        assert ok.status_code == 200
        assert ok.json() == {"ok": True}

    # Direct origin.workspace_client check rejects multi/comma headers safely
    class _FakeClient:
        host = "127.0.0.1"

    class _FakeUrl:
        scheme = "https"

    class _FakeRequest:
        client = _FakeClient()
        url = _FakeUrl()

        def __init__(self, raw):
            from starlette.datastructures import Headers
            self.headers = Headers(raw=raw)

    assert origin.workspace_client(_FakeRequest([
        (b"host", b"127.0.0.1:8000"),
        (b"x-forwarded-host", b"review.example.test"),
        (b"x-interviewcheck-client-ip", b"198.51.100.42"),
    ])) == "198.51.100.42"
    assert origin.workspace_client(_FakeRequest([
        (b"host", b"127.0.0.1:8000"),
        (b"x-forwarded-host", b"review.example.test"),
        (b"x-interviewcheck-client-ip", b"198.51.100.1"),
        (b"x-interviewcheck-client-ip", b"198.51.100.2"),
    ])) == "127.0.0.1"


def test_options_cors_preflight_rejected_with_403_and_no_acao_reflection(env, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    for path in ("/api/sessions", "/api/health", "/api/admin/models", "/v1/auth/login", "/v1/admin/compliance/summary"):
        for req_headers in (
            {"Origin": "https://evil.example", "Access-Control-Request-Method": "POST"},
            {"Origin": "http://127.0.0.1:8000", "Access-Control-Request-Method": "GET"},
            {"Access-Control-Request-Method": "DELETE"},
        ):
            res = env.options(path, headers=req_headers)
            assert res.status_code == 403
            assert res.json() == {"detail": "Cross-origin preflight requests are not permitted."}
            assert "access-control-allow-origin" not in res.headers
            assert res.headers["x-frame-options"] == "DENY"
            assert res.headers["referrer-policy"] == "no-referrer"
            assert res.headers["x-content-type-options"] == "nosniff"
            assert res.headers["cache-control"] == "no-store"

    # OPTIONS without Access-Control-Request-Method falls through cleanly with no ACAO
    non_preflight = env.options("/api/health")
    assert non_preflight.status_code == 405
    assert "access-control-allow-origin" not in non_preflight.headers


def test_access_sqlite_schema_version_stays_at_8(env):
    assert account_db.VERSION == 8
    with account_db.connection() as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == 8
