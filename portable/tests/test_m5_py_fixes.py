"""Regression tests for M5 Wave A Python fixes (T5-02, T5-05, T5-06, and M2 polish)."""
import asyncio
import json
from pathlib import Path
from unittest.mock import AsyncMock
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import access, account_db, model_probe, model_registry, prompt_framing, scoring_hooks, ssrf_guard, store
from api.main import app
from api.security_headers import SecurityHeadersMiddleware


def _seed_admin(email: str = "admin@example.invalid", *, role: str = "admin", disabled: bool = False) -> tuple[str, str]:
    uid = str(uuid4())
    ts = account_db.now()
    with account_db.connection(write=True) as db:
        db.execute(
            "INSERT INTO users(id, email, password_hash, role, disabled, created_at, updated_at) VALUES (?,?,?,?,?,?,?)",
            (uid, email, account_db.DECOY, role, 1 if disabled else 0, ts, ts),
        )
        token = account_db.issue(db, uid, "pytest")
    return uid, token


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "fixture-m5-py-secret")
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def _create_compat_model(client: TestClient, slug: str = "m5-compat") -> dict:
    res = client.post(
        "/api/admin/models",
        json={
            "slug": slug,
            "display_name": "Compat Model",
            "provider": "openai_compatible",
            "capability": "reference",
            "model_id": "llama-3",
            "endpoint": "https://llm.example.com/v1",
            "apiKey": "sk-initial-key-1111",
        },
    )
    assert res.status_code == 201
    return res.json()["model"]


def test_t5_02_update_model_optimistic_concurrency_conflict_and_delete(env, monkeypatch):
    _, tok = _seed_admin()
    env.cookies.set(access.COOKIE, tok)
    model = _create_compat_model(env, slug="race-patch")
    mid = model["id"]

    async def mutate_during_ssrf_check(url: str, *, provider: str | None = None) -> str:
        with store.connection(write=True) as db:
            row = model_registry.get_row(db, mid)
            model_registry.update_model(
                db, mid, slug=row["slug"], display_name="Winner", capability=row["capability"],
                model_id=row["model_id"], endpoint=row["endpoint"], api_version=row["api_version"],
                parameters=model_registry.parse_parameters(row["config_json"]),
                encrypted_api_key=row["encrypted_api_key"], key_hint="...9999",
                enabled=True, is_default=False, status="unverified",
                last_error=None, last_latency_ms=None, last_checked_at=None,
            )
        return url

    monkeypatch.setattr(ssrf_guard, "validate_endpoint_url_async", mutate_during_ssrf_check)
    conflict = env.patch(f"/api/admin/models/{mid}", json={"endpoint": "https://other.example.com/v1", "display_name": "Stale"})
    assert conflict.status_code == 409

    with store.connection() as db:
        saved = model_registry.public_model(model_registry.get_row(db, mid))
    assert saved["display_name"] == "Winner" and saved["key_hint"] == "...9999" and saved["endpoint"] == "https://llm.example.com/v1"

    async def delete_during_ssrf_check(url: str, *, provider: str | None = None) -> str:
        with store.connection(write=True) as db:
            model_registry.delete_model(db, mid)
        return url

    monkeypatch.setattr(ssrf_guard, "validate_endpoint_url_async", delete_during_ssrf_check)
    deleted = env.patch(f"/api/admin/models/{mid}", json={"endpoint": "https://other2.example.com/v1"})
    assert deleted.status_code == 404


def test_t5_02_probe_model_optimistic_concurrency_conflict_and_delete(env, monkeypatch):
    _, tok = _seed_admin()
    env.cookies.set(access.COOKIE, tok)
    model = _create_compat_model(env, slug="race-probe")
    mid = model["id"]

    async def rotate_during_probe(row, *, api_key: str) -> model_probe.ProbeOutcome:
        with store.connection(write=True) as db:
            cur = model_registry.get_row(db, mid)
            model_registry.update_model(
                db, mid, slug=cur["slug"], display_name=cur["display_name"], capability=cur["capability"],
                model_id=cur["model_id"], endpoint=cur["endpoint"], api_version=cur["api_version"],
                parameters=model_registry.parse_parameters(cur["config_json"]),
                encrypted_api_key=cur["encrypted_api_key"], key_hint="...2222",
                enabled=True, is_default=False, status="unverified",
                last_error=None, last_latency_ms=None, last_checked_at=None,
            )
        return model_probe.ProbeOutcome(
            ok=True, status="connected", http_status=200, latency_ms=25, last_error=None, checked_at="2026-11-19T06:00:00Z",
        )

    monkeypatch.setattr(model_probe, "probe_model", rotate_during_probe)
    stale_probe = env.post(f"/api/admin/models/{mid}/probe")
    assert stale_probe.status_code == 409

    with store.connection() as db:
        saved = model_registry.public_model(model_registry.get_row(db, mid))
    assert saved["status"] == "unverified" and saved["key_hint"] == "...2222" and saved["last_checked_at"] is None

    async def delete_during_probe(row, *, api_key: str) -> model_probe.ProbeOutcome:
        with store.connection(write=True) as db:
            model_registry.delete_model(db, mid)
        return model_probe.ProbeOutcome(
            ok=True, status="connected", http_status=200, latency_ms=10, last_error=None, checked_at="2026-11-19T06:01:00Z",
        )

    monkeypatch.setattr(model_probe, "probe_model", delete_during_probe)
    assert env.post(f"/api/admin/models/{mid}/probe").status_code == 404


def test_t5_05_control_chars_stripped_from_dict_keys_and_judge_signals(env, monkeypatch):
    framed = json.loads(prompt_framing.untrusted_json_prompt({"bad\x00key\x07\n": {"inner\r\tkey": "val\x00"}}))
    assert framed == {"badkey ": {"inner key": "val"}}

    _, tok = _seed_admin()
    env.cookies.set(access.COOKIE, tok)
    assert env.post(
        "/api/admin/models",
        json={"slug": "judge-m5", "display_name": "Judge", "provider": "openai", "capability": "judge", "model_id": "gpt-4o", "apiKey": "sk-judge-1234"},
    ).status_code == 201

    captured = {}

    async def fake_fetch(name, method, url, **kwargs):
        captured["payload"] = json.loads(kwargs["json"]["messages"][-1]["content"])
        return {"choices": [{"finish_reason": "stop", "message": {"content": '{"likelihood": 80, "confidence": "high", "evidence": [], "follow_up_questions": []}'}}]}

    monkeypatch.setattr(scoring_hooks, "fetch_json", fake_fetch)
    res = env.post(
        "/api/scoring/judge",
        json={"question": "Q?", "answer": "A", "signals": {"sig\x00\x07": 0.5, "two\nlines": 2, "\x00\x07   ": 9}},
    )
    assert res.status_code == 200
    assert captured["payload"]["signals"] == {"sig": 0.5, "two lines": 2.0}


def test_t5_06_304_static_asset_gets_static_asset_csp(tmp_path):
    static_dir = tmp_path / "out"
    static_dir.mkdir()
    (static_dir / "index.html").write_text("<html><script>console.log(1)</script></html>", encoding="utf-8")
    (static_dir / "appearance.js").write_text("console.log('theme');", encoding="utf-8")

    async def dummy_app(scope, receive, send):
        await send({"type": "http.response.start", "status": 304, "headers": []})
        await send({"type": "http.response.body", "body": b""})

    mw = SecurityHeadersMiddleware(dummy_app, static_dir=static_dir)

    async def call_path(path: str) -> dict[str, str]:
        sent = []
        scope = {"type": "http", "path": path, "scheme": "http", "headers": [(b"host", b"127.0.0.1")]}

        async def receive():
            return {"type": "http.request", "body": b"", "more_body": False}

        async def send(msg):
            sent.append(msg)

        await mw(scope, receive, send)
        return {k.decode().lower(): v.decode() for k, v in sent[0]["headers"]}

    js_headers = asyncio.run(call_path("/appearance.js"))
    assert js_headers["content-security-policy"] == "default-src 'none'; frame-ancestors 'none'"

    html_headers = asyncio.run(call_path("/"))
    assert "script-src 'self' 'sha256-" in html_headers["content-security-policy"]


def test_m2_polish_access_admin_single_auth_and_embedded_operator_email(env, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://accounts.example.invalid")
    calls = []

    async def fake_upstream(path, method="GET", *, token=None, body=None, idempotency=None, client_address=None):
        calls.append((method, path))
        if path == "me":
            return {"user": {"id": str(uuid4()), "email": "admin@example.invalid", "role": "admin", "disabled": False}, "entitlement": {"active": True}}
        return {"ok": True}

    monkeypatch.setattr(access, "upstream", fake_upstream)
    env.cookies.set(access.COOKIE, "remote-admin-token")
    assert env.get("/api/integrations/admin/users").status_code == 200
    assert calls.count(("GET", "me")) == 1
    calls.clear()
    assert env.get("/api/integrations/admin/audit").status_code == 200
    assert calls.count(("GET", "me")) == 1
    calls.clear()
    assert env.patch(f"/api/integrations/admin/users/{uuid4()}", json={"role": "user"}).status_code == 200
    assert calls.count(("GET", "me")) == 1

    # Embedded mode enforces operator email and checks disabled (401) before operator email (403)
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_URL", raising=False)
    monkeypatch.setenv("INTERVIEWCHECK_OPERATOR_EMAIL", "op@example.invalid")
    _, wrong_tok = _seed_admin(email="other@example.invalid", role="admin", disabled=False)
    _, dis_wrong_tok = _seed_admin(email="other2@example.invalid", role="admin", disabled=True)
    _, ok_tok = _seed_admin(email="OP@example.invalid", role="admin", disabled=False)

    env.cookies.set(access.COOKIE, wrong_tok)
    assert env.get("/api/admin/models").status_code == 403
    env.cookies.set(access.COOKIE, dis_wrong_tok)
    assert env.get("/api/admin/models").status_code == 401
    env.cookies.set(access.COOKIE, ok_tok)
    assert env.get("/api/admin/models").status_code == 200
