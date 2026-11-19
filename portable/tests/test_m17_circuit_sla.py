"""Tests for M17-W1: model circuit breakers, SLA percentile analytics, and execution gating."""
import asyncio
from datetime import datetime, timedelta, timezone
import sqlite3
from types import SimpleNamespace
from unittest.mock import AsyncMock
from uuid import uuid4

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest

from api import (
    access, account_db, model_budgets, model_circuit, model_execution,
    model_registry, model_telemetry, rate_limit, scoring_hooks, secret_box, ssrf_guard, store,
)
from api.main import app


def _seed_user(*, email: str = "circuit-admin@example.invalid", role: str = "admin") -> str:
    uid, ts = str(uuid4()), account_db.now()
    with account_db.connection(write=True) as db:
        db.execute(
            "INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,0,?,?)",
            (uid, email, account_db.DECOY, role, ts, ts),
        )
        return account_db.issue(db, uid, "pytest")


def _register(
    *, slug: str, provider: str = "openai", capability: str = "reference",
    model_id: str = "gpt-4o", endpoint: str | None = None,
    api_key: str = "sk-circuit-test-1234",
    is_default: bool = False, parameters: dict | None = None,
) -> dict:
    uid = str(uuid4())
    enc = secret_box.encrypt_secret(api_key, aad=uid)
    with store.connection(write=True) as db:
        return model_registry.create_model(
            db, model_uuid=uid, slug=slug, display_name=f"M {slug}", provider=provider,
            capability=capability, model_id=model_id, endpoint=endpoint, api_version=None,
            parameters=parameters or {}, encrypted_api_key=enc, key_hint=secret_box.mask_key_hint(api_key),
            enabled=True, is_default=is_default,
        )


@pytest.fixture
def env(tmp_path, monkeypatch):
    rate_limit.reset_all()
    model_execution.reset_quotas()
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "fixture-m17-circuit-key")
    for key in (
        "INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL",
        "INTERVIEWCHECK_PUBLIC_ORIGIN", "OPENAI_API_KEY", "INTERVIEWCHECK_REFERENCE_MODEL",
        "ANTHROPIC_API_KEY", "INTERVIEWCHECK_ANTHROPIC_MODEL",
    ):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def test_migration_main_mounts_cascade_and_backup_exclusion(env):
    with store.connection() as db:
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert {"model_circuit_state", "prompt_templates", "prompt_template_versions"}.issubset(tables)

    m = _register(slug="circuit-cascade", is_default=True)
    with store.connection(write=True) as db:
        model_circuit.record_outcome(db, m["id"], ok=False, error="503 down")
        assert db.execute("SELECT count(*) FROM model_circuit_state WHERE model_id=?", (m["id"],)).fetchone()[0] == 1

    env.cookies.set(access.COOKIE, _seed_user())
    assert env.get("/api/admin/models/sla").status_code == 200
    assert env.get("/api/admin/prompts").status_code == 200
    backup = env.get("/api/backups/workspace")
    assert backup.status_code == 200
    assert "model_circuit_state" not in backup.text and "prompt_templates" not in backup.text

    assert env.delete(f"/api/admin/models/{m['id']}").status_code == 200
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM model_circuit_state WHERE model_id=?", (m["id"],)).fetchone()[0] == 0


@pytest.mark.parametrize("mode", [None, "embedded", "remote"])
def test_circuit_sla_auth_gates_and_csrf(env, monkeypatch, mode):
    m = _register(slug="auth-circuit", is_default=True)
    if mode == "embedded":
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    elif mode == "remote":
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://accounts.example.invalid")
        monkeypatch.setattr(access, "upstream", AsyncMock(side_effect=HTTPException(401, "Expired")))

    routes = [
        ("GET", "/api/admin/models/sla", None),
        ("POST", f"/api/admin/models/{m['id']}/circuit/reset", None),
        ("PATCH", f"/api/admin/models/{m['id']}/circuit", {"cooldown_seconds": 30}),
    ]
    for method, path, body in routes:
        assert env.request(method, path, json=body).status_code == 401
        forged = {"Cookie": f"{access.COOKIE}=mm_forged_123456789012345678901234567890"}
        assert env.request(method, path, json=body, headers=forged).status_code == 401

    if mode == "remote":
        monkeypatch.setattr(access, "upstream", AsyncMock(return_value={
            "user": {"id": str(uuid4()), "email": "u@example.invalid", "role": "user", "disabled": False},
            "entitlement": {"active": True},
        }))
        user_hdr = {"Cookie": f"{access.COOKIE}=remote-user"}
    else:
        user_hdr = {"Cookie": f"{access.COOKIE}={_seed_user(email='u@example.invalid', role='user')}"}
    for method, path, body in routes:
        assert env.request(method, path, json=body, headers=user_hdr).status_code == 403

    if mode != "remote":
        adm_tok = _seed_user(email="adm@example.invalid", role="admin")
        with TestClient(app, base_url="http://127.0.0.1") as raw:
            raw.cookies.set(access.COOKIE, adm_tok)
            assert raw.post(f"/api/admin/models/{m['id']}/circuit/reset").status_code == 403
            assert raw.patch(f"/api/admin/models/{m['id']}/circuit", json={"cooldown_seconds": 30}).status_code == 403


def test_circuit_state_machine_transitions_and_error_sanitization(env):
    m = _register(slug="sm-model", is_default=True)
    t0 = datetime(2026, 11, 19, 10, 0, 0, tzinfo=timezone.utc)
    with store.connection(write=True) as db:
        assert model_circuit.can_execute(db, m["id"], now=t0) == model_circuit.CircuitDecision(True, "closed", 0)
        c1 = model_circuit.record_outcome(db, m["id"], ok=False, error="Err sk-proj-AbCdEfGhIjKlMnOpQrStUv /Users/alice/k", now=t0)
        assert c1["state"] == "closed" and c1["failure_streak"] == 1
        assert "sk-proj-" not in c1["last_failure_reason"] and "/Users/alice" not in c1["last_failure_reason"]

        c2 = model_circuit.record_outcome(db, m["id"], ok=False, error="Err 2", now=t0 + timedelta(seconds=1))
        assert c2["state"] == "closed" and c2["failure_streak"] == 2
        c3 = model_circuit.record_outcome(db, m["id"], ok=False, error="Err 3", now=t0 + timedelta(seconds=2))
        assert c3["state"] == "open" and c3["failure_streak"] == 3 and c3["opened_at"] is not None

        blocked = model_circuit.can_execute(db, m["id"], now=t0 + timedelta(seconds=20))
        assert blocked.allowed is False and blocked.state == "open" and blocked.retry_after_s == 42

        half = model_circuit.can_execute(db, m["id"], now=t0 + timedelta(seconds=62))
        assert half == model_circuit.CircuitDecision(True, "half_open", 0)
        assert db.execute("SELECT state FROM model_circuit_state WHERE model_id=?", (m["id"],)).fetchone()[0] == "half_open"

        reopened = model_circuit.record_outcome(db, m["id"], ok=False, error="Probe fail", now=t0 + timedelta(seconds=63))
        assert reopened["state"] == "open" and reopened["failure_streak"] == 4

        half2 = model_circuit.can_execute(db, m["id"], now=t0 + timedelta(seconds=125))
        assert half2.allowed is True and half2.state == "half_open"
        closed = model_circuit.record_outcome(db, m["id"], ok=True, now=t0 + timedelta(seconds=126))
        assert closed["state"] == "closed" and closed["failure_streak"] == 0
        assert closed["opened_at"] is None and closed["next_retry_at"] is None and closed["last_failure_reason"] is None


def test_execution_chain_circuit_failover_503_and_ssrf_budget_preservation(env, monkeypatch):
    p = _register(slug="cb-primary", provider="openai", capability="judge", model_id="gpt-4o", is_default=True, parameters={"fallback_priority": 10})
    s = _register(slug="cb-backup", provider="anthropic", capability="judge", model_id="claude-sonnet-4-6", is_default=False, parameters={"fallback_priority": 20})

    env.cookies.set(access.COOKIE, _seed_user())
    assert env.patch(f"/api/admin/models/{p['id']}/circuit", json={"consecutive_threshold": 2, "cooldown_seconds": 45}).status_code == 200
    assert env.patch(f"/api/admin/models/{s['id']}/circuit", json={"consecutive_threshold": 2, "cooldown_seconds": 25}).status_code == 200

    called_urls: list[str] = []

    async def failover_fetch(name, method, url, **kwargs):
        called_urls.append(url)
        if "openai.com" in url:
            raise HTTPException(503, "Primary overloaded")
        return {"stop_reason": "end_turn", "content": [{"type": "text", "text": '{"likelihood": 80, "confidence": "high"}'}]}

    monkeypatch.setattr(scoring_hooks, "fetch_json", failover_fetch)
    body = {"question": "Q?", "answer": "A"}
    for _ in range(2):
        res = env.post("/api/scoring/judge", json=body)
        assert res.status_code == 200 and res.json()["provider"] == "anthropic"

    called_urls.clear()
    res3 = env.post("/api/scoring/judge", json=body)
    assert res3.status_code == 200 and res3.json()["provider"] == "anthropic"
    assert called_urls == ["https://api.anthropic.com/v1/messages"]

    monkeypatch.setattr(scoring_hooks, "fetch_json", AsyncMock(side_effect=HTTPException(503, "Backup down")))
    assert env.post("/api/scoring/judge", json=body).status_code == 503
    assert env.post("/api/scoring/judge", json=body).status_code == 503

    called_urls.clear()
    monkeypatch.setattr(scoring_hooks, "fetch_json", failover_fetch)
    all_open = env.post("/api/scoring/judge", json=body)
    assert all_open.status_code == 503 and "circuit-open" in all_open.json()["detail"]
    assert 1 <= int(all_open.headers["retry-after"]) <= 45
    assert called_urls == []

    # Reset backup circuit and verify SSRF validation on fallback is still enforced.
    assert env.post(f"/api/admin/models/{s['id']}/circuit/reset").status_code == 200
    with store.connection(write=True) as db:
        db.execute("UPDATE connected_models SET provider='openai_compatible', endpoint='https://127.0.0.1/v1' WHERE id=?", (s["id"],))
    ssrf_res = env.post("/api/scoring/judge", json=body)
    assert ssrf_res.status_code == 400 and called_urls == []

    # Budget exhaustion still takes precedence over circuit-open fallback.
    assert env.post(f"/api/admin/models/{p['id']}/circuit/reset").status_code == 200
    with store.connection(write=True) as db:
        db.execute("UPDATE connected_models SET provider='anthropic', endpoint=NULL WHERE id=?", (s["id"],))
        model_circuit.record_outcome(db, s["id"], ok=False, error="trip1")
        model_circuit.record_outcome(db, s["id"], ok=False, error="trip2")
        db.execute("UPDATE connected_models SET config_json='{\"fallback_priority\":10,\"daily_token_limit\":1}' WHERE id=?", (p["id"],))
        model_budgets.record_usage(db, p["id"], input_tokens=5, output_tokens=0, ok=True, config={"daily_token_limit": 1})
    assert env.post("/api/scoring/judge", json=body).status_code == 429


def test_sla_percentiles_policy_validation_reset_and_audit(env, tmp_path):
    m = _register(slug="sla-model", is_default=True)
    with store.connection(write=True) as db:
        for i in range(1, 21):
            ok = i <= 17
            model_telemetry.record_check(
                db, m["id"], source="live", ok=ok, http_status=200 if ok else 503,
                latency_ms=i * 100, error=None if ok else "err", checked_at=f"2026-11-19T00:00:{i:02d}Z",
            )
        sla = model_circuit.compute_sla(db, m["id"])
        assert sla["p50_latency_ms"] == 1000 and sla["p95_latency_ms"] == 1900 and sla["p99_latency_ms"] == 2000
        assert sla["error_rate_pct"] == 15.0 and sla["sla_target_ms"] == 2500 and sla["sla_compliant"] is True

    env.cookies.set(access.COOKIE, _seed_user())
    fleet = env.get("/api/admin/models/sla").json()
    assert fleet["summary"]["total_models"] == 1 and fleet["summary"]["sla_compliant_models"] == 1
    assert fleet["models"][m["id"]]["p95_latency_ms"] == 1900

    for bad in ({}, {"extra": 1}, {"consecutive_threshold": 0}, {"consecutive_threshold": 21},
                {"consecutive_threshold": True}, {"cooldown_seconds": 4}, {"cooldown_seconds": 3601},
                {"sla_target_ms": 99}, {"sla_target_ms": 60001}, {"sla_target_ms": None}):
        assert env.patch(f"/api/admin/models/{m['id']}/circuit", json=bad).status_code == 422
    assert env.patch(f"/api/admin/models/{uuid4()}/circuit", json={"sla_target_ms": 500}).status_code == 404
    assert env.post(f"/api/admin/models/{uuid4()}/circuit/reset").status_code == 404
    assert env.patch("/api/admin/models/not-a-uuid/circuit", json={"sla_target_ms": 500}).status_code == 422

    patched = env.patch(f"/api/admin/models/{m['id']}/circuit", json={"consecutive_threshold": 2, "cooldown_seconds": 15, "sla_target_ms": 1500})
    assert patched.status_code == 200 and patched.json()["circuit"]["sla_target_ms"] == 1500

    violating = env.get("/api/admin/models/sla").json()
    assert violating["models"][m["id"]]["sla_compliant"] is False
    assert violating["summary"]["sla_violating_models"] == 1

    with store.connection(write=True) as db:
        model_circuit.record_outcome(db, m["id"], ok=False, error="f1")
        model_circuit.record_outcome(db, m["id"], ok=False, error="f2")
    assert env.get("/api/admin/models/sla").json()["summary"]["open_circuits"] == 1

    reset = env.post(f"/api/admin/models/{m['id']}/circuit/reset")
    assert reset.status_code == 200 and reset.json()["circuit"]["state"] == "closed" and reset.json()["circuit"]["failure_streak"] == 0

    with account_db.connection() as adb:
        actions = [r[0] for r in adb.execute("SELECT action FROM audit_log ORDER BY id ASC").fetchall()]
    assert "admin.model.circuit_policy" in actions and "admin.model.circuit_reset" in actions

    # Verify fallback model_audit when account_db file is absent.
    (tmp_path / "access.sqlite3").unlink()
    env.app.dependency_overrides[model_circuit._require_admin] = lambda: {"id": "local-admin", "role": "admin"}
    try:
        assert env.patch(f"/api/admin/models/{m['id']}/circuit", json={"sla_target_ms": 2000}).status_code == 200
        assert env.post(f"/api/admin/models/{m['id']}/circuit/reset").status_code == 200
    finally:
        env.app.dependency_overrides.clear()
    with store.connection() as db:
        fb_actions = [r[0] for r in db.execute("SELECT action FROM model_audit ORDER BY id ASC").fetchall()]
    assert "admin.model.circuit_policy" in fb_actions and "admin.model.circuit_reset" in fb_actions


def test_half_open_single_probe_gating_lease_expiry_and_migration(env):
    legacy = sqlite3.connect(":memory:")
    legacy.execute("CREATE TABLE connected_models(id TEXT PRIMARY KEY)")
    legacy.execute(
        "CREATE TABLE model_circuit_state(model_id TEXT PRIMARY KEY, state TEXT NOT NULL DEFAULT 'closed', "
        "failure_streak INTEGER NOT NULL DEFAULT 0, consecutive_threshold INTEGER NOT NULL DEFAULT 3, "
        "cooldown_seconds INTEGER NOT NULL DEFAULT 60, sla_target_ms INTEGER NOT NULL DEFAULT 2500, "
        "opened_at TEXT, next_retry_at TEXT, last_failure_reason TEXT, updated_at TEXT NOT NULL)"
    )
    model_circuit.migrate(legacy)
    model_circuit.migrate(legacy)
    assert "half_open_probe_until" in {r[1] for r in legacy.execute("PRAGMA table_info(model_circuit_state)")}
    legacy.close()

    m = _register(slug="ho-probe", capability="judge", is_default=True)
    env.cookies.set(access.COOKIE, _seed_user())
    assert env.patch(f"/api/admin/models/{m['id']}/circuit", json={"consecutive_threshold": 1, "cooldown_seconds": 20}).status_code == 200
    t0 = datetime(2026, 11, 19, 12, 0, 0, tzinfo=timezone.utc)
    with store.connection(write=True) as db:
        model_circuit.record_outcome(db, m["id"], ok=False, error="down", now=t0)
        first = model_circuit.can_execute(db, m["id"], now=t0 + timedelta(seconds=21))
        second = model_circuit.can_execute(db, m["id"], now=t0 + timedelta(seconds=22))
        assert first == model_circuit.CircuitDecision(True, "half_open", 0)
        assert second.allowed is False and second.state == "half_open" and second.retry_after_s >= 1
        expired = model_circuit.can_execute(db, m["id"], now=t0 + timedelta(seconds=42))
        assert expired == model_circuit.CircuitDecision(True, "half_open", 0)

    reset = env.post(f"/api/admin/models/{m['id']}/circuit/reset").json()["circuit"]
    assert reset["state"] == "closed" and reset["half_open_probe_until"] is None

    with store.connection(write=True) as db:
        past = (datetime.now(timezone.utc) - timedelta(seconds=5)).isoformat()
        db.execute(
            "UPDATE model_circuit_state SET state='open', next_retry_at=?, half_open_probe_until=NULL WHERE model_id=?",
            (past, m["id"]),
        )
    hits: list[str] = []

    async def slow_fetch(name, method, url, **kwargs):
        hits.append(url)
        await asyncio.sleep(0.08)
        raise HTTPException(503, "still down")

    async def gather_two():
        return await asyncio.gather(
            model_execution.execute_completion_chain("judge", "sys", "usr", fetch_fn=slow_fetch),
            model_execution.execute_completion_chain("judge", "sys", "usr", fetch_fn=slow_fetch),
            return_exceptions=True,
        )

    results = asyncio.run(gather_two())
    assert len(hits) == 1 and all(isinstance(r, HTTPException) and r.status_code == 503 for r in results)


def test_retry_loop_stops_when_circuit_opens_on_first_attempt(env, monkeypatch):
    m = _register(slug="retry-stop", capability="judge", is_default=True, parameters={"max_retries": 2})
    env.cookies.set(access.COOKIE, _seed_user())
    assert env.patch(f"/api/admin/models/{m['id']}/circuit", json={"consecutive_threshold": 1, "cooldown_seconds": 60}).status_code == 200

    calls = 0

    async def fail_fetch(name, method, url, **kwargs):
        nonlocal calls
        calls += 1
        raise HTTPException(503, "provider overloaded")

    monkeypatch.setattr(scoring_hooks, "fetch_json", fail_fetch)
    res = env.post("/api/scoring/judge", json={"question": "Q?", "answer": "A"})
    assert res.status_code == 503 and calls == 1
    with store.connection() as db:
        row = db.execute("SELECT state, failure_streak FROM model_circuit_state WHERE model_id=?", (m["id"],)).fetchone()
        assert row["state"] == "open" and row["failure_streak"] == 1


def test_unprefixed_api_key_and_signing_secret_redacted_everywhere(env):
    raw_key = "az99887766554433221100ffeeddccbbaa"
    m = _register(
        slug="unprefixed-leak", provider="openai_compatible", capability="embedding",
        model_id="embed-v1", endpoint="https://llm.example.invalid/v1", api_key=raw_key, is_default=True,
    )

    async def fail_emb(name, method, url, **kwargs):
        raise HTTPException(502, f"Bad auth {raw_key} rejected")

    with pytest.raises(HTTPException) as exc_info:
        asyncio.run(
            model_execution.execute_embedding_chain(
                ["hello"],
                request_builder=lambda t, texts: (t.endpoint + "/embeddings", {}, {"input": texts}),
                fetch_fn=fail_emb,
            )
        )
    assert raw_key not in str(exc_info.value.detail) and "[REDACTED]" in str(exc_info.value.detail)

    env.cookies.set(access.COOKIE, _seed_user())
    sla = env.get("/api/admin/models/sla").json()
    health = env.get(f"/api/admin/models/{m['id']}/health").json()
    assert raw_key not in str(sla) and raw_key not in str(health)
    assert sla["models"][m["id"]]["circuit"]["last_failure_reason"] == "Bad auth [REDACTED] rejected"

    with store.connection(write=True) as db:
        direct = model_circuit.record_outcome(db, m["id"], ok=False, error=f"Direct fail {raw_key}")
    assert raw_key not in direct["last_failure_reason"] and "[REDACTED]" in direct["last_failure_reason"]
    fake = SimpleNamespace(api_key=raw_key, signing_secret="whsec_unprefixed_secret_9876")
    assert model_execution._redact_target_secrets("key=" + raw_key + " sig=whsec_unprefixed_secret_9876", fake) == "key=[REDACTED] sig=[REDACTED]"

