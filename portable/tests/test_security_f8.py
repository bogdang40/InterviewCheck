"""Tests for M2 F8: security headers, CSP, exports.py print.js, /v1 CSRF, and rate limiting."""
import hashlib
import hmac
import json
from pathlib import Path
import re
import time
from unittest.mock import AsyncMock

from fastapi.testclient import TestClient
import pytest

from api import account_db, authoring, integrations, scoring_hooks, store
from api.account_server import app as standalone
from api.main import app


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    for key in (
        "INTERVIEWCHECK_ACCESS_MODE",
        "INTERVIEWCHECK_ACCESS_URL",
        "INTERVIEWCHECK_OPERATOR_EMAIL",
        "INTERVIEWCHECK_PUBLIC_ORIGIN",
        "INTERVIEWCHECK_PRODUCTION",
    ):
        monkeypatch.delenv(key, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        yield client


def _assert_base_security_headers(headers, *, expect_hsts: bool = False):
    assert headers["x-content-type-options"] == "nosniff"
    assert headers["x-frame-options"] == "DENY"
    assert headers["referrer-policy"] == "no-referrer"
    assert "microphone=(self)" in headers["permissions-policy"]
    assert "display-capture=(self)" in headers["permissions-policy"]
    assert "camera=()" in headers["permissions-policy"]
    if expect_hsts:
        assert "max-age=31536000" in headers["strict-transport-security"]
    else:
        assert "strict-transport-security" not in headers


def test_security_headers_and_csp_across_endpoints(env, monkeypatch):
    health = env.get("/api/health")
    assert health.status_code == 200
    _assert_base_security_headers(health.headers, expect_hsts=False)
    assert health.headers["cache-control"] == "no-store"
    assert "default-src 'none'" in health.headers["content-security-policy"]

    # LocalBoundary early rejection still carries security headers
    with TestClient(app, base_url="http://127.0.0.1") as raw:
        rejected = raw.post("/api/sessions", json={"candidate": "A", "role": "B", "policy": "P", "consent": True})
        assert rejected.status_code == 403
        _assert_base_security_headers(rejected.headers)

    # Static export index.html CSP hashes match inline <script> elements with no unsafe-inline in script-src
    static_index = Path(__file__).resolve().parents[1] / "web" / "out" / "index.html"
    if static_index.is_file():
        page = env.get("/")
        assert page.status_code == 200
        _assert_base_security_headers(page.headers)
        csp = page.headers["content-security-policy"]
        script_src = next(part for part in csp.split(";") if part.strip().startswith("script-src"))
        assert "'unsafe-inline'" not in script_src
        assert "'sha256-" in script_src
        assert "media-src 'self' blob:" in csp
        if "etag" in page.headers:
            not_modified = env.get("/", headers={"If-None-Match": page.headers["etag"]})
            assert not_modified.status_code == 304
            assert "script-src 'self' 'sha256-" in not_modified.headers["content-security-policy"]

    # Standalone account service /health carries full security headers
    with TestClient(standalone) as s:
        sh = s.get("/health")
        assert sh.status_code == 200
        _assert_base_security_headers(sh.headers)
        assert sh.headers["cache-control"] == "no-store"

    # HSTS emitted when INTERVIEWCHECK_PUBLIC_ORIGIN is configured
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("INTERVIEWCHECK_PUBLIC_ORIGIN", "https://review.example.test")
    with TestClient(app, base_url="https://127.0.0.1", headers={"X-Forwarded-Host": "review.example.test"}) as pub:
        ph = pub.get("/api/health")
        assert ph.status_code == 200
        _assert_base_security_headers(ph.headers, expect_hsts=True)


def test_exports_print_uses_external_script_without_inline_onclick(env):
    created = env.post("/api/sessions", json={"candidate": "Ada", "role": "Staff", "policy": "None", "consent": True})
    assert created.status_code == 201
    sid = created.json()["id"]

    printed = env.get(f"/api/sessions/{sid}/print")
    assert printed.status_code == 200
    assert "onclick=" not in printed.text
    assert '<script src="/api/exports/print.js" defer></script>' in printed.text
    assert len(re.findall(r"<script\b", printed.text)) == 1
    csp = printed.headers["content-security-policy"]
    assert "script-src 'self'" in csp
    assert "'unsafe-inline'" not in csp

    js = env.get("/api/exports/print.js")
    assert js.status_code == 200
    assert "application/javascript" in js.headers["content-type"]
    assert "print-report" in js.text and "window.print()" in js.text


def test_csrf_enforced_on_v1_mutations_except_webhook(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("STRIPE_WEBHOOK_SECRET", "whsec_csrf_test")

    with TestClient(app, base_url="http://127.0.0.1") as raw:
        assert raw.post("/v1/auth/login", json={"email": "a@example.test", "password": "long-password-1"}).status_code == 403
        raw_evt = json.dumps({"id": "evt_csrf", "type": "unused.event", "data": {"object": {}}}).encode()
        ts = int(time.time())
        sig = hmac.new(b"whsec_csrf_test", f"{ts}.".encode() + raw_evt, hashlib.sha256).hexdigest()
        webhook = raw.post("/v1/billing/webhook", content=raw_evt, headers={"Content-Type": "application/json", "Stripe-Signature": f"t={ts},v1={sig}"})
        assert webhook.status_code == 200

    with TestClient(standalone) as s:
        assert s.post(
            "/v1/auth/login",
            json={"email": "a@example.test", "password": "long-password-1"},
            headers={"Origin": "https://evil.example"},
        ).status_code == 403
        assert s.post(
            "/v1/auth/login",
            json={"email": "a@example.test", "password": "long-password-1"},
            headers={"Cookie": "ic_access=forged"},
        ).status_code == 403
        # Non-browser native caller (no Origin, no Cookie) reaches auth logic (401 invalid credentials)
        assert s.post("/v1/auth/login", json={"email": "a@example.test", "password": "long-password-1"}).status_code == 401
        # Browser caller with X-InterviewCheck: 1 also passes CSRF check
        assert s.post(
            "/v1/auth/login",
            json={"email": "a@example.test", "password": "long-password-1"},
            headers={"Origin": "http://127.0.0.1", "X-InterviewCheck": "1"},
        ).status_code == 401


def test_rate_limits_on_ai_and_admin_routes_with_lifespan_reset(env, monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "sk-fixture-1234567890")
    monkeypatch.setenv("INTERVIEWCHECK_REFERENCE_MODEL", "gpt-4o")
    monkeypatch.setattr(authoring, "fetch_json", AsyncMock(return_value={"choices": [{"finish_reason": "stop", "message": {"content": "Ref"}}]}))
    monkeypatch.setattr(integrations, "fetch_json", AsyncMock(return_value={"status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": "Ref"}]}]}))
    monkeypatch.setattr(scoring_hooks, "fetch_json", AsyncMock(return_value={"data": [{"index": 0, "embedding": [1.0, 0.0]}, {"index": 1, "embedding": [1.0, 0.0]}]}))

    for i in range(20):
        res = env.post("/api/authoring/reference", json={"provider": "OpenAI", "style": "Spoken answer", "role": "Eng", "question": "Q?"})
        assert res.status_code == 200, f"failed at {i}"
    blocked = env.post("/api/authoring/reference", json={"provider": "OpenAI", "style": "Spoken answer", "role": "Eng", "question": "Q?"})
    assert blocked.status_code == 429 and int(blocked.headers["retry-after"]) >= 1

    # Shared AI_REQUEST bucket also blocks /api/integrations/reference and /api/scoring/semantic in same window
    assert env.post("/api/integrations/reference", json={"role": "Eng", "question": "Q?"}).status_code == 429
    assert env.post("/api/scoring/semantic", json={"answer": "ans", "references": [{"label": "ref", "text": "txt"}]}).status_code == 429

    # New TestClient lifespan resets rate limiters cleanly
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as fresh:
        assert fresh.post("/api/integrations/reference", json={"role": "Eng", "question": "Q?"}).status_code == 200
        with account_db.connection(write=True) as db:
            ts = account_db.now()
            uid = "11111111-1111-4111-8111-111111111111"
            db.execute("INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,0,?,?)",
                       (uid, "admin@example.invalid", account_db.DECOY, "admin", ts, ts))
            tok = account_db.issue(db, uid, "pytest")
        fresh.cookies.set("ic_access", tok)
        for _ in range(15):
            assert fresh.post("/api/admin/models/00000000-0000-4000-8000-000000000000/probe").status_code == 404
        assert fresh.post("/api/admin/models/00000000-0000-4000-8000-000000000000/probe").status_code == 429
