import json
import socket
from unittest.mock import AsyncMock
from uuid import uuid4

from fastapi import HTTPException
from fastapi.testclient import TestClient
import httpx
import pytest

from api import access, account_db, model_probe, model_registry, ssrf_guard, store
from api.main import app


def _seed_user(*, email: str, role: str = "admin", disabled: bool = False) -> tuple[str, str]:
    uid = str(uuid4())
    ts = account_db.now()
    with account_db.connection(write=True) as db:
        db.execute(
            """INSERT INTO users(id, email, password_hash, role, disabled, created_at, updated_at)
               VALUES (?,?,?,?,?,?,?)""",
            (uid, email, account_db.DECOY, role, 1 if disabled else 0, ts, ts),
        )
        token = account_db.issue(db, uid, "pytest")
    return uid, token


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "fixture-admin-secret-key")
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def _valid_openai_payload(**overrides):
    base = {
        "slug": "openai-ref-main",
        "display_name": "OpenAI Reference",
        "provider": "openai",
        "capability": "reference",
        "model_id": "gpt-4o",
        "apiKey": "sk-admin-fixture-1234",
        "parameters": {"temperature": 0.4, "max_tokens": 1200, "timeout_s": 30.0, "fallback_priority": 10},
        "enabled": True,
        "is_default": True,
    }
    base.update(overrides)
    return base


@pytest.mark.parametrize("mode", [None, "embedded", "remote"])
def test_admin_auth_fail_closed_across_all_modes(env, monkeypatch, mode):
    if mode == "embedded":
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    elif mode == "remote":
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://accounts.example.invalid")
        monkeypatch.setattr(access, "upstream", AsyncMock(side_effect=HTTPException(401, "Session expired.")))

    mid = str(uuid4())
    endpoints = [
        ("GET", "/api/admin/models", None),
        ("POST", "/api/admin/models", _valid_openai_payload()),
        ("PATCH", f"/api/admin/models/{mid}", {"display_name": "Updated"}),
        ("POST", f"/api/admin/models/{mid}/toggle", {"enabled": False}),
        ("POST", f"/api/admin/models/{mid}/probe", None),
        ("DELETE", f"/api/admin/models/{mid}", None),
    ]

    for method, path, body in endpoints:
        resp = env.request(method, path, json=body)
        assert resp.status_code == 401
        resp_forged = env.request(
            method, path, json=body,
            headers={"Cookie": f"{access.COOKIE}=mm_forged_token_value_12345678901234567890"},
        )
        assert resp_forged.status_code == 401

    if mode == "remote":
        monkeypatch.setattr(access, "upstream", AsyncMock(return_value={"user": {"id": str(uuid4()), "email": "member@example.invalid", "role": "user", "disabled": False}, "entitlement": {"active": True}}))
        user_header = {"Cookie": f"{access.COOKIE}=remote-user-token"}
    else:
        _, user_token = _seed_user(email="member@example.invalid", role="user")
        user_header = {"Cookie": f"{access.COOKIE}={user_token}"}

    for method, path, body in endpoints:
        resp = env.request(method, path, json=body, headers=user_header)
        assert resp.status_code == 403

    # Missing CSRF header on mutation must be rejected with 403
    if mode != "remote":
        _, admin_token = _seed_user(email="admin@example.invalid", role="admin")
        with TestClient(app, base_url="http://127.0.0.1") as raw_client:
            raw_client.cookies.set(access.COOKIE, admin_token)
            assert raw_client.post("/api/admin/models", json=_valid_openai_payload()).status_code == 403


def test_embedded_multi_admin_signup_without_operator_email_lock(env, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("ADMIN_EMAILS", "admin1@example.invalid,admin2@example.invalid")
    monkeypatch.setenv("ADMIN_BOOTSTRAP_SECRET", "bootstrap-fixture-secret")
    s1 = env.post("/api/integrations/access/signup", json={"email": "admin1@example.invalid", "password": "strong-password-1", "adminSecret": "bootstrap-fixture-secret"})
    assert s1.status_code == 200 and s1.json().get("admin") is True
    assert env.get("/api/admin/models").status_code == 200

    s2 = env.post("/api/integrations/access/signup", json={"email": "admin2@example.invalid", "password": "strong-password-2", "adminSecret": "bootstrap-fixture-secret"})
    assert s2.status_code == 200 and s2.json().get("admin") is True
    assert env.get("/api/admin/models").status_code == 200


@pytest.mark.parametrize(("bad_payload", "expected_code"), [
    (_valid_openai_payload(extra_field="nope"), 422),
    (_valid_openai_payload(parameters={"temperature": True}), 422),
    (_valid_openai_payload(parameters={"temperature": 2.5}), 422),
    (_valid_openai_payload(parameters={"max_tokens": 0}), 422),
    (_valid_openai_payload(parameters={"timeout_s": 0.5}), 422),
    (_valid_openai_payload(parameters={"fallback_priority": 10001}), 422),
    (_valid_openai_payload(provider="deepgram", capability="reference"), 422),
    (_valid_openai_payload(provider="anthropic", capability="embedding"), 422),
    (_valid_openai_payload(apiKey=""), 422),
    (_valid_openai_payload(endpoint="https://api.example.com/v1"), 422),
    (_valid_openai_payload(provider="azure_openai", model_id="dep", endpoint="https://res.openai.azure.com", api_version=None), 422),
    (_valid_openai_payload(provider="openai_compatible", endpoint="http://127.0.0.1/v1", apiKey=None), 400),
    (_valid_openai_payload(provider="openai_compatible", endpoint="https://169.254.169.254/v1", apiKey=None), 400),
])
def test_strict_validation_and_ssrf_leave_zero_partial_rows(env, bad_payload, expected_code):
    _, admin_token = _seed_user(email="admin@example.invalid", role="admin")
    env.cookies.set(access.COOKIE, admin_token)
    resp = env.post("/api/admin/models", json=bad_payload)
    assert resp.status_code == expected_code
    assert env.post("/api/admin/models", content=b'{"slug":"nan-test","display_name":"NaN","provider":"openai","capability":"reference","model_id":"gpt-4o","apiKey":"sk-1234567890","parameters":{"temperature":NaN}}', headers={"Content-Type": "application/json"}).status_code == 422
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM connected_models").fetchone()[0] == 0


def test_crud_key_rotation_vs_preservation_toggle_probe_and_audit(env, monkeypatch):
    _, admin_token = _seed_user(email="admin@example.invalid", role="admin")
    env.cookies.set(access.COOKIE, admin_token)

    secret1 = "sk-first-secret-key-1111"
    secret2 = "sk-second-secret-key-2222"
    create = env.post("/api/admin/models", json=_valid_openai_payload(apiKey=secret1))
    assert create.status_code == 201
    model = create.json()["model"]
    mid = model["id"]
    assert model["hasKey"] is True and model["key_hint"] == "...1111" and secret1 not in create.text

    # Duplicate slug -> 409
    assert env.post("/api/admin/models", json=_valid_openai_payload(apiKey=secret1)).status_code == 409

    # PATCH without apiKey or with blank apiKey preserves existing key
    patch_preserve = env.patch(f"/api/admin/models/{mid}", json={"display_name": "Renamed OpenAI", "apiKey": "   "})
    assert patch_preserve.status_code == 200
    assert patch_preserve.json()["model"]["key_hint"] == "...1111"

    # Non-UUID path -> 422, missing UUID -> 404
    assert env.patch("/api/admin/models/not-a-uuid", json={"display_name": "X"}).status_code == 422
    assert env.patch(f"/api/admin/models/{uuid4()}", json={"display_name": "X"}).status_code == 404

    # Probe success -> 200, updates status/latency/checked_at
    monkeypatch.setattr(model_probe, "probe_model", AsyncMock(return_value=model_probe.ProbeOutcome(
        ok=True, status="connected", http_status=200, latency_ms=42, last_error=None, checked_at="2026-11-19T05:00:00Z",
    )))
    probed = env.post(f"/api/admin/models/{mid}/probe")
    assert probed.status_code == 200 and probed.json()["ok"] is True
    assert probed.json()["model"]["status"] == "connected" and probed.json()["model"]["last_latency_ms"] == 42

    # Rotate key resets status back to unverified and updates key_hint
    rotated = env.patch(f"/api/admin/models/{mid}", json={"apiKey": secret2})
    assert rotated.status_code == 200
    assert rotated.json()["model"]["key_hint"] == "...2222" and rotated.json()["model"]["status"] == "unverified"
    assert secret2 not in rotated.text

    # Probe upstream failure -> 502 and timeout -> 504 with updated DB state
    monkeypatch.setattr(model_probe, "probe_model", AsyncMock(return_value=model_probe.ProbeOutcome(
        ok=False, status="error", http_status=401, latency_ms=15, last_error="Authentication failed (HTTP 401). Check the API key.", checked_at="2026-11-19T05:01:00Z",
    )))
    failed = env.post(f"/api/admin/models/{mid}/probe")
    assert failed.status_code == 502 and failed.json()["model"]["status"] == "error"

    monkeypatch.setattr(model_probe, "probe_model", AsyncMock(return_value=model_probe.ProbeOutcome(
        ok=False, status="error", http_status=None, latency_ms=5001, last_error="Provider connection timed out.", checked_at="2026-11-19T05:02:00Z", timed_out=True,
    )))
    timed_out = env.post(f"/api/admin/models/{mid}/probe")
    assert timed_out.status_code == 504 and timed_out.json()["model"]["status"] == "error"

    # Toggle off -> disabled, toggle on -> restores error status
    toggled_off = env.post(f"/api/admin/models/{mid}/toggle", json={"enabled": False})
    assert toggled_off.status_code == 200 and toggled_off.json()["model"]["status"] == "disabled"
    toggled_on = env.post(f"/api/admin/models/{mid}/toggle", json={"enabled": True})
    assert toggled_on.status_code == 200 and toggled_on.json()["model"]["status"] == "error"

    listed = env.get("/api/admin/models")
    assert listed.status_code == 200 and len(listed.json()["models"]) == 1
    assert secret1 not in listed.text and secret2 not in listed.text

    assert env.delete(f"/api/admin/models/{mid}").status_code == 200
    assert env.delete(f"/api/admin/models/{mid}").status_code == 404

    with account_db.connection() as adb:
        actions = [r["action"] for r in adb.execute("SELECT action, details FROM audit_log ORDER BY id ASC").fetchall()]
        raw_audit = json.dumps([dict(r) for r in adb.execute("SELECT * FROM audit_log").fetchall()])
    assert actions == ["admin.model.create", "admin.model.update", "admin.model.probe", "admin.model.update", "admin.model.probe", "admin.model.probe", "admin.model.toggle", "admin.model.toggle", "admin.model.delete"]
    assert secret1 not in raw_audit and secret2 not in raw_audit


def test_fallback_model_audit_used_when_access_db_is_absent(env, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://accounts.example.invalid")
    monkeypatch.setattr(access, "upstream", AsyncMock(return_value={
        "user": {"id": str(uuid4()), "email": "remote-admin@example.invalid", "role": "admin", "disabled": False},
        "entitlement": {"active": True},
    }))
    env.cookies.set(access.COOKIE, "remote-admin-token")
    res = env.post("/api/admin/models", json=_valid_openai_payload(apiKey="sk-remote-secret-4444"))
    assert res.status_code == 201
    assert not account_db.database().exists()
    with store.connection() as db:
        rows = db.execute("SELECT action, model_id, details FROM model_audit").fetchall()
    assert len(rows) == 1 and rows[0]["action"] == "admin.model.create"
    assert "sk-remote-secret-4444" not in (rows[0]["details"] or "")


def test_clear_api_key_and_probe_ssrf_block(env, monkeypatch):
    _, admin_token = _seed_user(email="admin@example.invalid", role="admin")
    env.cookies.set(access.COOKIE, admin_token)
    oa = env.post("/api/admin/models", json=_valid_openai_payload(slug="oa-clear-test")).json()["model"]
    assert env.patch(f"/api/admin/models/{oa['id']}", json={"clearApiKey": True}).status_code == 422

    compat = env.post("/api/admin/models", json={
        "slug": "compat-clear-test",
        "display_name": "Compat",
        "provider": "openai_compatible",
        "capability": "reference",
        "model_id": "llama-3",
        "endpoint": "https://llm.example.com/v1",
        "apiKey": "sk-compat-secret-1234",
    }).json()["model"]
    cleared = env.patch(f"/api/admin/models/{compat['id']}", json={"clearApiKey": True})
    assert cleared.status_code == 200 and cleared.json()["model"]["hasKey"] is False and cleared.json()["model"]["key_hint"] is None

    # Simulate DNS rebind to private IP at probe time -> 400 + status=error
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: (_ for _ in ()).throw(ssrf_guard.SSRFValidationError("Endpoint resolves to a restricted network address.")))
    probed = env.post(f"/api/admin/models/{compat['id']}/probe")
    assert probed.status_code == 400 and probed.json()["model"]["status"] == "error"
