"""Unit and integration tests for M6 telemetry, health history, quotas, retries, and failover."""
from unittest.mock import AsyncMock
from uuid import uuid4

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest

from api import (
    access, account_db, audio, authoring, integrations, model_circuit, model_execution,
    model_probe, model_registry, model_resolver, model_telemetry,
    scoring_hooks, secret_box, ssrf_guard, store,
)
from api.main import app


def _seed_user(*, email: str = "admin@example.invalid", role: str = "admin") -> tuple[str, str]:
    uid, ts = str(uuid4()), account_db.now()
    with account_db.connection(write=True) as db:
        db.execute("INSERT INTO users(id, email, password_hash, role, disabled, created_at, updated_at) VALUES (?,?,?,?,0,?,?)",
                   (uid, email, account_db.DECOY, role, ts, ts))
        token = account_db.issue(db, uid, "pytest")
    return uid, token


def _register(*, slug: str, provider: str = "openai", capability: str = "reference", model_id: str = "gpt-4o",
              secret: str = "sk-m6-secret-1234", endpoint: str | None = None, enabled: bool = True,
              is_default: bool = False, parameters: dict | None = None) -> dict:
    uid = str(uuid4())
    enc = secret_box.encrypt_secret(secret, aad=uid) if secret else None
    hint = secret_box.mask_key_hint(secret) if secret else None
    with store.connection(write=True) as db:
        return model_registry.create_model(
            db, model_uuid=uid, slug=slug, display_name=f"Model {slug}", provider=provider,
            capability=capability, model_id=model_id, endpoint=endpoint, api_version=None,
            parameters=parameters or {}, encrypted_api_key=enc, key_hint=hint, enabled=enabled, is_default=is_default,
        )


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "fixture-m6-secret-key")
    for key in (
        "INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL",
        "INTERVIEWCHECK_PUBLIC_ORIGIN", "OPENAI_API_KEY", "INTERVIEWCHECK_REFERENCE_MODEL",
        "ANTHROPIC_API_KEY", "INTERVIEWCHECK_ANTHROPIC_MODEL", "DEEPGRAM_API_KEY",
    ):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def test_health_history_retention_summary_cascade_and_backup_isolation(env):
    mid = _register(slug="hist-model", is_default=True)["id"]
    with store.connection(write=True) as db:
        for i in range(65):
            ok = i % 5 != 0
            model_telemetry.record_check(
                db, mid, source="probe" if i % 2 == 0 else "live", ok=ok,
                http_status=200 if ok else 503, latency_ms=100 + i,
                error=None if ok else f"Err /Users/alice/secret.txt sk-proj-AbCdEfGhIjKlMnOpQrStUv {i}",
                checked_at=f"2026-11-19T00:{i // 60:02d}:{i % 60:02d}Z",
            )
        health = model_telemetry.get_model_health(db, mid, limit=50)
        assert len(health["history"]) == 50
        assert health["history"][0]["checked_at"] == "2026-11-19T00:01:04Z"
        assert health["history"][-1]["checked_at"] == "2026-11-19T00:00:15Z"
        assert health["summary"]["total_checks"] == 50 and health["summary"]["ok_count"] == 40
        assert health["summary"]["error_count"] == 10 and health["summary"]["uptime_pct"] == 80.0
        assert health["summary"]["p95_latency_ms"] == 162
        err_entry = next(item for item in health["history"] if not item["ok"])
        assert "/Users/alice" not in err_entry["error"] and "sk-proj-" not in err_entry["error"]

        model_registry.toggle_model(db, mid, enabled=False)
        model_telemetry.record_check(
            db, mid, source="live", ok=True, http_status=200, latency_ms=22, error=None, checked_at="2026-11-19T02:00:00Z"
        )
        assert model_registry.get_row(db, mid)["status"] == "disabled"

    _, tok = _seed_user(role="admin")
    env.cookies.set(access.COOKIE, tok)
    backup_res = env.get("/api/backups/workspace")
    assert backup_res.status_code == 200 and "model_health_checks" not in backup_res.text

    assert env.delete(f"/api/admin/models/{mid}").status_code == 200
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM model_health_checks WHERE model_id=?", (mid,)).fetchone()[0] == 0


def test_telemetry_and_health_endpoints_auth_and_probe_persistence(env, monkeypatch):
    mid = _register(slug="probe-hist", is_default=True)["id"]
    for path in ("/api/admin/models/telemetry", f"/api/admin/models/{mid}/health", "/api/admin/models/not-a-uuid/health?limit=999"):
        assert env.get(path).status_code == 401

    _, user_tok = _seed_user(email="user@example.invalid", role="user")
    env.cookies.set(access.COOKIE, user_tok)
    for path in ("/api/admin/models/telemetry", f"/api/admin/models/{mid}/health"):
        assert env.get(path).status_code == 403

    _, admin_tok = _seed_user(email="admin2@example.invalid", role="admin")
    env.cookies.set(access.COOKIE, admin_tok)
    empty = env.get("/api/admin/models/telemetry")
    assert empty.status_code == 200 and empty.json()["summary"]["total_models"] == 1 and empty.json()["summary"]["uptime_pct"] is None

    monkeypatch.setattr(model_probe, "probe_model", AsyncMock(return_value=model_probe.ProbeOutcome(
        ok=True, status="connected", http_status=200, latency_ms=45, last_error=None, checked_at="2026-11-19T05:00:00Z",
    )))
    assert env.post(f"/api/admin/models/{mid}/probe").status_code == 200

    monkeypatch.setattr(model_probe, "probe_model", AsyncMock(return_value=model_probe.ProbeOutcome(
        ok=False, status="error", http_status=503, latency_ms=15, last_error="Provider unavailable.", checked_at="2026-11-19T05:01:00Z",
    )))
    assert env.post(f"/api/admin/models/{mid}/probe").status_code == 502

    fleet = env.get("/api/admin/models/telemetry").json()
    assert fleet["summary"]["total_checks"] == 2 and fleet["summary"]["ok_checks"] == 1 and fleet["summary"]["error_models"] == 1
    assert fleet["models"][mid]["uptime_pct"] == 50.0

    health_res = env.get(f"/api/admin/models/{mid}/health?limit=1")
    assert health_res.status_code == 200
    body = health_res.json()
    assert len(body["history"]) == 1 and body["history"][0]["source"] == "probe" and body["history"][0]["http_status"] == 503
    assert body["summary"]["total_checks"] == 2
    assert env.get(f"/api/admin/models/{mid}/health?limit=51").status_code == 422
    assert env.get(f"/api/admin/models/{uuid4()}/health").status_code == 404


def test_max_retries_and_rpm_limit_validation_and_persistence(env):
    _, tok = _seed_user(role="admin")
    env.cookies.set(access.COOKIE, tok)
    base = {
        "slug": "param-test", "display_name": "Param Test", "provider": "openai",
        "capability": "reference", "model_id": "gpt-4o", "apiKey": "sk-param-test-1234",
        "parameters": {"fallback_priority": 10, "max_retries": 2, "rpm_limit": 30},
    }
    created = env.post("/api/admin/models", json=base)
    assert created.status_code == 201
    mid = created.json()["model"]["id"]
    assert created.json()["model"]["parameters"]["max_retries"] == 2 and created.json()["model"]["parameters"]["rpm_limit"] == 30

    cleared = env.patch(f"/api/admin/models/{mid}", json={"parameters": {"rpm_limit": None}})
    assert cleared.status_code == 200 and cleared.json()["model"]["parameters"]["rpm_limit"] is None
    assert env.patch(f"/api/admin/models/{mid}", json={"parameters": {"max_retries": None}}).status_code == 422

    for bad_params in ({"max_retries": -1}, {"max_retries": 4}, {"max_retries": True}, {"rpm_limit": 0}, {"rpm_limit": 10001}, {"rpm_limit": False}):
        assert env.post("/api/admin/models", json=dict(base, slug=f"bad-{uuid4().hex[:6]}", parameters=bad_params)).status_code == 422


def test_resolve_chain_priority_blocked_providers_and_env_fallbacks(env, monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "sk-env-oa")
    monkeypatch.setenv("INTERVIEWCHECK_REFERENCE_MODEL", "gpt-4o-mini")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-env-ant")
    monkeypatch.setenv("INTERVIEWCHECK_ANTHROPIC_MODEL", "claude-sonnet-4-6")

    _register(slug="oa-disabled", provider="openai", capability="reference", enabled=False)
    m_low = _register(slug="compat-low", provider="openai_compatible", capability="reference", endpoint="https://low.example.com/v1", parameters={"fallback_priority": 50})
    m_high = _register(slug="compat-high", provider="openai_compatible", capability="reference", endpoint="https://high.example.com/v1", parameters={"fallback_priority": 10})

    chain = model_resolver.resolve_chain("reference")
    assert [c.slug for c in chain] == [m_high["slug"], m_low["slug"], None]
    assert chain[-1].provider == "anthropic" and chain[-1].source == "env"
    assert model_resolver.resolve_capability("reference").slug == m_high["slug"]
    assert [c.slug for c in model_resolver.resolve_chain("reference", provider=m_low["slug"])] == [m_low["slug"]]


def test_quota_failover_exhaustion_and_reset(env, monkeypatch):
    p = _register(slug="quota-primary", provider="openai", capability="reference", is_default=True, parameters={"fallback_priority": 10, "rpm_limit": 2, "max_retries": 2})
    s = _register(slug="quota-backup", provider="anthropic", capability="reference", is_default=False, parameters={"fallback_priority": 20, "rpm_limit": 1})
    seen_providers = []

    async def fake_fetch(name, method, url, **kwargs):
        seen_providers.append(name)
        if name == "OpenAI":
            return {"status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": "From OpenAI"}]}]}
        return {"stop_reason": "end_turn", "content": [{"type": "text", "text": "From Anthropic"}]}

    monkeypatch.setattr(integrations, "fetch_json", fake_fetch)
    assert env.post("/api/integrations/reference", json={"role": "SRE", "question": "Q1"}).json()["label"].startswith("OpenAI")
    assert env.post("/api/integrations/reference", json={"role": "SRE", "question": "Q2"}).json()["label"].startswith("OpenAI")
    r3 = env.post("/api/integrations/reference", json={"role": "SRE", "question": "Q3"})
    assert r3.status_code == 200 and r3.json()["text"] == "From Anthropic"
    assert seen_providers == ["OpenAI", "OpenAI", "Anthropic"]

    with store.connection() as db:
        assert model_registry.get_row(db, p["id"])["status"] == "connected"
        assert model_registry.get_row(db, s["id"])["status"] == "connected"

    r4 = env.post("/api/integrations/reference", json={"role": "SRE", "question": "Q4"})
    assert r4.status_code == 429 and "Retry-After" in r4.headers

    model_execution.reset_quotas()
    r5 = env.post("/api/integrations/reference", json={"role": "SRE", "question": "Q5"})
    assert r5.status_code == 200 and r5.json()["text"] == "From OpenAI"


def test_transient_retries_failover_and_live_telemetry_across_consumers(env, monkeypatch):
    monkeypatch.setattr(model_execution.asyncio, "sleep", AsyncMock())
    a1 = _register(slug="auth-p1", provider="openai", capability="question_planning", model_id="gpt-4o", is_default=True, parameters={"fallback_priority": 10, "max_retries": 1})
    _register(slug="auth-p2", provider="openai", capability="question_planning", model_id="gpt-4o-mini", is_default=False, parameters={"fallback_priority": 20})
    _register(slug="auth-ant-ref", provider="anthropic", capability="reference", model_id="claude-sonnet-4-6", is_default=False, parameters={"fallback_priority": 30})
    calls = []

    async def fake_authoring_fetch(name, method, url, **kwargs):
        calls.append((name, kwargs["json"]["model"]))
        if kwargs["json"]["model"] == "gpt-4o":
            raise HTTPException(503 if len(calls) == 1 else 429, "Temporary overload")
        return {"choices": [{"finish_reason": "stop", "message": {"content": '["Q1?"]'}}]}

    monkeypatch.setattr(authoring, "fetch_json", fake_authoring_fetch)
    q_res = env.post("/api/authoring/questions", json={"provider": "OpenAI", "role": "SRE", "description": "Scale systems"})
    assert q_res.status_code == 200 and q_res.json() == {"questions": ["Q1?"]}
    assert calls == [("OpenAI", "gpt-4o"), ("OpenAI", "gpt-4o"), ("OpenAI", "gpt-4o-mini")]

    with store.connection() as db:
        assert model_registry.get_row(db, a1["id"])["status"] == "error"
        assert model_telemetry.summarize_model(db, a1["id"])["error_count"] == 2

    chain = model_resolver.resolve_chain("question_planning", allow_reference_fallback=True)
    assert [m.slug for m in chain] == ["auth-p1", "auth-p2", "auth-ant-ref"]


def test_cross_provider_failover_audio_and_scoring_and_slug_scoping(env, monkeypatch):
    monkeypatch.setattr(model_execution.asyncio, "sleep", AsyncMock())
    p1 = _register(slug="oa-p1", provider="openai", capability="reference", is_default=True, parameters={"fallback_priority": 10, "max_retries": 1})
    p2 = _register(slug="oa-p2", provider="openai", capability="reference", model_id="gpt-4o-backup", is_default=False, parameters={"fallback_priority": 20})
    auth_calls = []

    async def auth_fetch(name, method, url, **kwargs):
        auth_calls.append(kwargs["json"]["model"])
        if len(auth_calls) <= 2:
            raise HTTPException(503, "Primary down")
        return {"choices": [{"finish_reason": "stop", "message": {"content": "Backup OK"}}]}

    monkeypatch.setattr(authoring, "fetch_json", auth_fetch)
    res = env.post("/api/authoring/reference", json={"provider": "OpenAI", "style": "Spoken answer", "role": "SRE", "question": "Q?"})
    assert res.status_code == 200 and res.json()["text"] == "Backup OK"
    assert auth_calls == ["gpt-4o", "gpt-4o", "gpt-4o-backup"]

    auth_calls.clear()
    with store.connection(write=True) as db:
        model_circuit.record_outcome(db, p1["id"], ok=True)
    assert env.post("/api/authoring/reference", json={"provider": "oa-p1", "style": "Spoken answer", "role": "SRE", "question": "Q?"}).status_code == 503
    assert auth_calls == ["gpt-4o", "gpt-4o"]

    with store.connection() as db:
        assert model_registry.get_row(db, p1["id"])["status"] == "error"
        assert model_registry.get_row(db, p2["id"])["status"] == "connected"
        assert model_telemetry.summarize_model(db, p1["id"])["last_source"] == "live"

    _register(slug="dg-1", provider="deepgram", capability="transcription", model_id="nova-2", is_default=True, parameters={"fallback_priority": 10})
    _register(slug="dg-2", provider="deepgram", capability="transcription", model_id="nova-3", is_default=False, parameters={"fallback_priority": 20})

    async def audio_fetch(name, method, url, **kwargs):
        if kwargs["params"]["model"] == "nova-2":
            raise HTTPException(502, "Bad gateway")
        return {"results": {"utterances": [{"speaker": 0, "transcript": "Transcript ok"}]}}

    monkeypatch.setattr(audio, "fetch_json", audio_fetch)
    tx = env.post("/api/integrations/transcribe", content=b"wavdata", headers={"Content-Type": "audio/wav", "X-Send-Audio": "deepgram"})
    assert tx.status_code == 200 and tx.json()["segments"] == [{"speaker": "0", "text": "Transcript ok"}]

    _register(slug="emb-1", provider="openai", capability="embedding", model_id="emb-a", is_default=True, parameters={"fallback_priority": 10})
    _register(slug="emb-2", provider="openai", capability="embedding", model_id="emb-b", is_default=False, parameters={"fallback_priority": 20})
    _register(slug="jdg-1", provider="openai", capability="judge", model_id="jdg-a", is_default=True, parameters={"fallback_priority": 10})
    _register(slug="jdg-2", provider="anthropic", capability="judge", model_id="jdg-b", is_default=False, parameters={"fallback_priority": 20})

    async def scoring_fetch(name, method, url, **kwargs):
        model = kwargs["json"]["model"]
        if model == "emb-a":
            raise HTTPException(504, "Timeout")
        if model == "emb-b":
            return {"data": [{"index": 0, "embedding": [1.0, 0.0]}, {"index": 1, "embedding": [1.0, 0.0]}]}
        if model == "jdg-a":
            raise HTTPException(429, "Rate limited")
        return {"stop_reason": "end_turn", "content": [{"type": "text", "text": '{"likelihood": 88, "confidence": "high", "evidence": ["e1"], "follow_up_questions": ["f1"]}'}]}

    monkeypatch.setattr(scoring_hooks, "fetch_json", scoring_fetch)
    sem = env.post("/api/scoring/semantic", json={"answer": "ans", "references": [{"label": "R", "text": "ref", "permitted": False}]})
    assert sem.status_code == 200 and sem.json()["model"] == "emb-b"
    jdg = env.post("/api/scoring/judge", json={"question": "Q?", "answer": "A"})
    assert jdg.status_code == 200 and jdg.json()["provider"] == "anthropic" and jdg.json()["model"] == "jdg-b"


def test_ssrf_and_non_transient_errors_never_failover(env, monkeypatch):
    bad = _register(
        slug="ssrf-primary", provider="openai_compatible", capability="reference",
        endpoint="https://169.254.169.254/v1", is_default=True, parameters={"fallback_priority": 10},
    )
    _register(slug="healthy-backup", provider="openai", capability="reference", is_default=False, parameters={"fallback_priority": 20})
    called = []

    async def spy_fetch(*args, **kwargs):
        called.append(args)
        return {"status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": "Should not run"}]}]}

    monkeypatch.setattr(integrations, "fetch_json", spy_fetch)
    assert env.post("/api/integrations/reference", json={"role": "SRE", "question": "Q?"}).status_code == 400 and called == []

    with store.connection(write=True) as db:
        db.execute("UPDATE connected_models SET endpoint=? WHERE id=?", ("https://rebind.example.com/v1", bad["id"]))

    async def ssrf_transport_fail(*args, **kwargs):
        called.append(args)
        raise HTTPException(502, "Blocked unsafe provider endpoint.") from ssrf_guard.SSRFValidationError("private ip")

    monkeypatch.setattr(integrations, "fetch_json", ssrf_transport_fail)
    assert env.post("/api/integrations/reference", json={"role": "SRE", "question": "Q?"}).status_code == 502 and len(called) == 1

    called.clear()
    with store.connection(write=True) as db:
        db.execute("UPDATE connected_models SET endpoint=? WHERE id=?", ("https://llm.example.com/v1", bad["id"]))

    async def auth_fail(*args, **kwargs):
        called.append(args)
        raise HTTPException(401, "Invalid API key.")

    monkeypatch.setattr(integrations, "fetch_json", auth_fail)
    assert env.post("/api/integrations/reference", json={"role": "SRE", "question": "Q?"}).status_code == 401 and len(called) == 1
