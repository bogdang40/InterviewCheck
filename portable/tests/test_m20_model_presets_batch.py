"""Tests for M20-W2 admin model presets and batch toggle/probe endpoints."""
import asyncio
import json
from unittest.mock import AsyncMock
from uuid import uuid4

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
import pytest

from api import (
    access, account_db, main, model_execution, model_presets, model_probe,
    model_registry, model_schemas, model_telemetry, rate_limit, secret_box, ssrf_guard, store,
)
from api.local_boundary import LocalBoundary
from api.security_headers import SecurityHeadersMiddleware


def _build_app():
    if any(getattr(r, "path", "") == "/api/admin/models/presets" for r in main.app.routes):
        return main.app
    test_app = FastAPI(lifespan=main.lifespan)
    test_app.add_middleware(LocalBoundary)
    test_app.add_middleware(SecurityHeadersMiddleware, static_dir=None)
    for exc_type, handler in main.app.exception_handlers.items():
        test_app.add_exception_handler(exc_type, handler)
    test_app.include_router(model_presets.router)
    test_app.include_router(main.model_admin.router)
    return test_app


def _seed_user(*, email: str = "m20-admin@example.invalid", role: str = "admin") -> str:
    uid, ts = str(uuid4()), account_db.now()
    with account_db.connection(write=True) as db:
        db.execute(
            "INSERT INTO users(id, email, password_hash, role, disabled, created_at, updated_at) VALUES (?,?,?,?,0,?,?)",
            (uid, email, account_db.DECOY, role, ts, ts),
        )
        return account_db.issue(db, uid, "pytest")


def _register(
    *, slug: str, provider: str = "openai", capability: str = "reference", model_id: str = "gpt-4o",
    secret: str = "sk-m20-secret-9999", endpoint: str | None = None, api_version: str | None = None, enabled: bool = True,
) -> dict:
    uid = str(uuid4())
    enc = secret_box.encrypt_secret(secret, aad=uid) if secret else None
    hint = secret_box.mask_key_hint(secret) if secret else None
    with store.connection(write=True) as db:
        return model_registry.create_model(
            db, model_uuid=uid, slug=slug, display_name=f"Model {slug}", provider=provider,
            capability=capability, model_id=model_id, endpoint=endpoint, api_version=api_version,
            parameters={}, encrypted_api_key=enc, key_hint=hint, enabled=enabled, is_default=False,
        )


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "fixture-m20-presets-key")
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])
    model_execution.reset_quotas()
    rate_limit.reset_all()
    with TestClient(_build_app(), base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


@pytest.mark.parametrize("mode", [None, "embedded", "remote"])
def test_presets_and_batch_auth_csrf_and_validation(env, monkeypatch, mode):
    m1 = _register(slug="m20-auth-1")
    toggle_body = {"model_ids": [m1["id"]], "enabled": False}
    probe_body = {"model_ids": [m1["id"]]}

    if mode == "embedded":
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    elif mode == "remote":
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://accounts.example.invalid")
        monkeypatch.setattr(access, "upstream", AsyncMock(side_effect=HTTPException(401, "Expired")))

    assert env.get("/api/admin/models/presets").status_code == 401
    assert env.post("/api/admin/models/batch/toggle", json=toggle_body).status_code == 401
    assert env.post("/api/admin/models/batch/probe", json=probe_body).status_code == 401

    forged = {"Cookie": f"{access.COOKIE}=mm_forged_cookie_value_12345678901234567890"}
    assert env.get("/api/admin/models/presets", headers=forged).status_code == 401
    assert env.post("/api/admin/models/batch/toggle", json=toggle_body, headers=forged).status_code == 401
    assert env.post("/api/admin/models/batch/probe", json=probe_body, headers=forged).status_code == 401

    if mode == "remote":
        monkeypatch.setattr(access, "upstream", AsyncMock(return_value={
            "user": {"id": str(uuid4()), "email": "u@example.invalid", "role": "user", "disabled": False},
            "entitlement": {"active": True},
        }))
        user_hdr = {"Cookie": f"{access.COOKIE}=remote-user"}
    else:
        user_hdr = {"Cookie": f"{access.COOKIE}={_seed_user(email='u@example.invalid', role='user')}"}

    assert env.get("/api/admin/models/presets", headers=user_hdr).status_code == 403
    assert env.post("/api/admin/models/batch/toggle", json=toggle_body, headers=user_hdr).status_code == 403
    assert env.post("/api/admin/models/batch/probe", json=probe_body, headers=user_hdr).status_code == 403

    if mode != "remote":
        admin_tok = _seed_user(email="a@example.invalid", role="admin")
        with TestClient(_build_app(), base_url="http://127.0.0.1") as raw:
            raw.cookies.set(access.COOKIE, admin_tok)
            assert raw.post("/api/admin/models/batch/toggle", json=toggle_body).status_code == 403
            assert raw.post("/api/admin/models/batch/probe", json=probe_body).status_code == 403

        env.cookies.set(access.COOKIE, admin_tok)
        for bad_toggle in (
            {"model_ids": [], "enabled": False}, {"model_ids": [m1["id"], m1["id"]], "enabled": False},
            {"model_ids": [str(uuid4()) for _ in range(26)], "enabled": True},
            {"model_ids": [m1["id"]], "enabled": "false"}, {"model_ids": [m1["id"]], "enabled": False, "extra": 1},
        ):
            assert env.post("/api/admin/models/batch/toggle", json=bad_toggle).status_code == 422

        for bad_probe in (
            {"model_ids": []}, {"model_ids": [m1["id"], m1["id"]]},
            {"model_ids": [str(uuid4()) for _ in range(11)]}, {"model_ids": [m1["id"]], "extra": 1},
        ):
            assert env.post("/api/admin/models/batch/probe", json=bad_probe).status_code == 422


def test_presets_catalog_non_secret_and_schema_compatible(env):
    env.cookies.set(access.COOKIE, _seed_user())
    res = env.get("/api/admin/models/presets")
    assert res.status_code == 200
    presets = res.json()["presets"]
    assert len(presets) == 8

    assert {p["provider"] for p in presets} == {"openai", "anthropic", "azure_openai", "deepgram", "openai_compatible"}
    assert {p["capability"] for p in presets} == {"reference", "question_planning", "transcription", "embedding", "judge"}

    required_keys = {
        "id", "provider", "capability", "model_id", "display_name", "slug_prefix",
        "endpoint_placeholder", "api_version_default", "parameters",
    }
    for preset in presets:
        assert required_keys.issubset(preset.keys())
        assert "apiKey" not in preset and "encrypted_api_key" not in preset and "key_hint" not in preset
        validated = model_schemas.ModelCreateInput.model_validate({
            "slug": preset["slug_prefix"], "display_name": preset["display_name"],
            "provider": preset["provider"], "capability": preset["capability"],
            "model_id": preset["model_id"], "endpoint": preset["endpoint_placeholder"],
            "api_version": preset["api_version_default"], "parameters": preset["parameters"],
            "apiKey": "sk-test-preset-validation-1234",
        })
        assert validated.provider == preset["provider"]


def test_batch_toggle_atomic_rollback_and_audit(env):
    env.cookies.set(access.COOKIE, _seed_user())
    m1 = _register(slug="m20-tog-1", enabled=True)
    m2 = _register(slug="m20-tog-2", enabled=True)

    missing_res = env.post(
        "/api/admin/models/batch/toggle",
        json={"model_ids": [m1["id"], str(uuid4()), m2["id"]], "enabled": False},
    )
    assert missing_res.status_code == 404

    with store.connection() as db:
        rows = [model_registry.public_model(model_registry.get_row(db, mid)) for mid in (m1["id"], m2["id"])]
    assert all(r["enabled"] is True and r["status"] == "unverified" for r in rows)

    with account_db.connection() as adb:
        assert adb.execute("SELECT 1 FROM audit_log WHERE action='admin.model.batch_toggle'").fetchone() is None

    ok_disable = env.post(
        "/api/admin/models/batch/toggle",
        json={"model_ids": [m1["id"], m2["id"]], "enabled": False},
    )
    assert ok_disable.status_code == 200
    body = ok_disable.json()
    assert body["updated"] == 2
    assert all(m["enabled"] is False and m["status"] == "disabled" for m in body["models"])

    with account_db.connection() as adb:
        audit_row = adb.execute(
            "SELECT details FROM audit_log WHERE action='admin.model.batch_toggle' ORDER BY id DESC LIMIT 1"
        ).fetchone()
    assert audit_row is not None
    assert json.loads(audit_row["details"]) == {
        "model_ids": [m1["id"], m2["id"]],
        "enabled": False,
        "updated": 2,
    }

    ok_enable = env.post(
        "/api/admin/models/batch/toggle",
        json={"model_ids": [m1["id"], m2["id"]], "enabled": True},
    )
    assert ok_enable.status_code == 200
    assert all(m["enabled"] is True and m["status"] == "unverified" for m in ok_enable.json()["models"])


def test_batch_probe_bounded_secretbox_error_audit_and_rate_limit(env, monkeypatch):
    env.cookies.set(access.COOKIE, _seed_user())
    secrets_list = [f"sk-batch-secret-token-{i:04d}" for i in range(1, 7)]
    models = [
        _register(slug=f"m20-probe-{i}", secret=secrets_list[i], enabled=(i != 4))
        for i in range(6)
    ]

    # Corrupt model #1 ciphertext so SecretBoxError occurs for that item only.
    with store.connection(write=True) as db:
        db.execute(
            "UPDATE connected_models SET encrypted_api_key=? WHERE id=?",
            ("v2:deadbeef:not_valid!", models[1]["id"]),
        )
    with store.connection() as db:
        enc_0 = db.execute("SELECT encrypted_api_key FROM connected_models WHERE id=?", (models[0]["id"],)).fetchone()[0]

    # Missing model ID returns 404 without running any probes.
    probe_calls = []

    async def fake_probe(row, *, api_key):
        probe_calls.append((row["id"], api_key))
        return model_probe.ProbeOutcome(
            ok=True, status="connected", http_status=200, latency_ms=10, last_error=None, checked_at="2026-01-01T00:00:00Z"
        )

    monkeypatch.setattr(model_probe, "probe_model", fake_probe)
    missing_probe = env.post("/api/admin/models/batch/probe", json={"model_ids": [models[0]["id"], str(uuid4())]})
    assert missing_probe.status_code == 404 and probe_calls == []

    in_flight = 0
    max_in_flight = 0

    async def bounded_probe(row, *, api_key):
        nonlocal in_flight, max_in_flight
        in_flight += 1
        max_in_flight = max(max_in_flight, in_flight)
        await asyncio.sleep(0.02)
        in_flight -= 1
        if row["id"] == models[2]["id"]:
            return model_probe.ProbeOutcome(
                ok=False,
                status="error",
                http_status=502,
                latency_ms=25,
                last_error=f"Upstream failed with Bearer {api_key} at /Users/admin/secret",
                checked_at="2026-01-01T00:00:01Z",
            )
        return model_probe.ProbeOutcome(
            ok=True,
            status="connected",
            http_status=200,
            latency_ms=12,
            last_error=None,
            checked_at="2026-01-01T00:00:01Z",
        )

    monkeypatch.setattr(model_probe, "probe_model", bounded_probe)
    ids = [m["id"] for m in models]
    res = env.post("/api/admin/models/batch/probe", json={"model_ids": ids})
    assert res.status_code == 200
    body = res.json()

    assert 2 <= max_in_flight <= 4
    assert body["probed"] == 6
    assert body["ok_count"] == 4
    assert body["error_count"] == 2
    assert len(body["results"]) == 6

    by_id = {entry["id"]: entry for entry in body["results"]}
    assert by_id[models[0]["id"]]["ok"] is True
    assert by_id[models[0]["id"]]["status"] == "connected"
    assert by_id[models[0]["id"]]["detail"] is None
    assert by_id[models[0]["id"]]["latency_ms"] == 12

    assert by_id[models[1]["id"]]["ok"] is False
    assert by_id[models[1]["id"]]["status"] == "error"
    assert "could not be decrypted" in by_id[models[1]["id"]]["detail"]
    assert by_id[models[1]["id"]]["latency_ms"] is None

    assert by_id[models[2]["id"]]["ok"] is False
    assert by_id[models[2]["id"]]["status"] == "error"
    assert "/Users/admin" not in by_id[models[2]["id"]]["detail"]

    assert by_id[models[4]["id"]]["ok"] is True
    assert by_id[models[4]["id"]]["status"] == "disabled"
    assert by_id[models[4]["id"]]["model"]["status"] == "disabled"

    for secret_val in secrets_list:
        assert secret_val not in res.text
    assert enc_0 not in res.text

    with store.connection() as db:
        tel = model_telemetry.fleet_telemetry(db)
    assert tel["models"][models[0]["id"]]["ok_count"] == 1
    assert tel["models"][models[1]["id"]]["error_count"] == 1

    with account_db.connection() as adb:
        audit_row = adb.execute(
            "SELECT details FROM audit_log WHERE action='admin.model.batch_probe' ORDER BY id DESC LIMIT 1"
        ).fetchone()
    assert audit_row is not None
    assert json.loads(audit_row["details"]) == {
        "model_ids": ids,
        "probed": 6,
        "ok_count": 4,
        "error_count": 2,
    }

    for _ in range(16):
        rl = env.post("/api/admin/models/batch/probe", json={"model_ids": [models[0]["id"]]})
        if rl.status_code == 429:
            break
    assert rl.status_code == 429
