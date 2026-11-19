"""Tests for M11-W2 routing simulator, fleet diagnostics, audio metering, and security gates."""
import asyncio
import json
from unittest.mock import AsyncMock
from uuid import uuid4

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest

from api import (
    access, account_db, audio, model_budgets, model_execution,
    model_registry, provider_http, rate_limit, secret_box, ssrf_guard, store,
)
from api.main import app


def _seed_user(*, email: str = "sim-admin@example.invalid", role: str = "admin") -> str:
    uid, ts = str(uuid4()), account_db.now()
    with account_db.connection(write=True) as db:
        db.execute(
            "INSERT INTO users(id, email, password_hash, role, disabled, created_at, updated_at) VALUES (?,?,?,?,0,?,?)",
            (uid, email, account_db.DECOY, role, ts, ts),
        )
        return account_db.issue(db, uid, "pytest")


def _register(
    *, slug: str, provider: str = "openai", capability: str = "reference", model_id: str = "gpt-4o",
    secret: str = "sk-m11-sim-secret-9876", endpoint: str | None = None, enabled: bool = True,
    is_default: bool = False, parameters: dict | None = None,
) -> dict:
    uid = str(uuid4())
    enc = secret_box.encrypt_secret(secret, aad=uid) if secret else None
    hint = secret_box.mask_key_hint(secret) if secret else None
    with store.connection(write=True) as db:
        return model_registry.create_model(
            db, model_uuid=uid, slug=slug, display_name=f"Model {slug}", provider=provider,
            capability=capability, model_id=model_id, endpoint=endpoint, api_version=None,
            parameters=parameters or {}, encrypted_api_key=enc, key_hint=hint,
            enabled=enabled, is_default=is_default,
        )


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "fixture-m11-sim-key")
    for key in (
        "INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL",
        "INTERVIEWCHECK_PUBLIC_ORIGIN", "OPENAI_API_KEY", "INTERVIEWCHECK_REFERENCE_MODEL",
        "ANTHROPIC_API_KEY", "INTERVIEWCHECK_ANTHROPIC_MODEL", "INTERVIEWCHECK_EMBEDDING_MODEL",
        "INTERVIEWCHECK_JUDGE_MODEL", "DEEPGRAM_API_KEY", "AZURE_OPENAI_API_KEY",
        "AZURE_OPENAI_DEPLOYMENT", "AZURE_OPENAI_ENDPOINT", "AZURE_OPENAI_API_VERSION",
    ):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])
    model_execution.reset_quotas()
    rate_limit.reset_all()
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


@pytest.mark.parametrize("mode", [None, "embedded", "remote"])
def test_simulator_and_diagnostics_auth_csrf_and_validation(env, monkeypatch, mode):
    if mode == "embedded":
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    elif mode == "remote":
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://accounts.example.invalid")
        monkeypatch.setattr(access, "upstream", AsyncMock(side_effect=HTTPException(401, "Expired")))

    assert env.get("/api/admin/models/diagnostics").status_code == 401
    assert env.post("/api/admin/models/simulate-chain", json={"capability": "reference"}).status_code == 401
    forged = {"Cookie": f"{access.COOKIE}=mm_forged_cookie_value_12345678901234567890"}
    assert env.get("/api/admin/models/diagnostics", headers=forged).status_code == 401
    assert env.post("/api/admin/models/simulate-chain", json={"capability": "reference"}, headers=forged).status_code == 401

    if mode == "remote":
        monkeypatch.setattr(access, "upstream", AsyncMock(return_value={
            "user": {"id": str(uuid4()), "email": "u@example.invalid", "role": "user", "disabled": False},
            "entitlement": {"active": True},
        }))
        user_hdr = {"Cookie": f"{access.COOKIE}=remote-user"}
    else:
        user_hdr = {"Cookie": f"{access.COOKIE}={_seed_user(email='u@example.invalid', role='user')}"}

    assert env.get("/api/admin/models/diagnostics", headers=user_hdr).status_code == 403
    assert env.post("/api/admin/models/simulate-chain", json={"capability": "reference"}, headers=user_hdr).status_code == 403

    if mode != "remote":
        admin_tok = _seed_user(email="a@example.invalid", role="admin")
        with TestClient(app, base_url="http://127.0.0.1") as raw:
            raw.cookies.set(access.COOKIE, admin_tok)
            assert raw.post("/api/admin/models/simulate-chain", json={"capability": "reference"}).status_code == 403

        env.cookies.set(access.COOKIE, admin_tok)
        assert env.post("/api/admin/models/simulate-chain", json={"capability": "bad"}).status_code == 422
        assert env.post("/api/admin/models/simulate-chain", json={"capability": "reference", "extra": 1}).status_code == 422
        assert env.post("/api/admin/models/simulate-chain", json={"capability": "reference", "allow_reference_fallback": "yes"}).status_code == 422


def test_simulate_chain_dry_run_no_http_no_decrypt_and_no_secret_exposure(env, monkeypatch):
    secret_val = "sk-top-secret-sim-value-4321"
    env_secret = "sk-env-secret-sim-value-8765"
    monkeypatch.setenv("ANTHROPIC_API_KEY", env_secret)
    monkeypatch.setenv("INTERVIEWCHECK_ANTHROPIC_MODEL", "claude-sonnet-4-6")
    monkeypatch.setenv("OPENAI_API_KEY", env_secret)
    monkeypatch.setenv("INTERVIEWCHECK_REFERENCE_MODEL", "gpt-4o-mini")

    m_primary = _register(
        slug="sim-primary", provider="openai", capability="question_planning", model_id="gpt-4o",
        secret=secret_val, is_default=True, parameters={"fallback_priority": 10, "rpm_limit": 3},
    )
    m_disabled = _register(
        slug="sim-disabled", provider="anthropic", capability="question_planning", model_id="claude-3",
        secret=secret_val, enabled=False, parameters={"fallback_priority": 20},
    )
    m_over_daily = _register(
        slug="sim-over-daily", provider="openai", capability="question_planning", model_id="gpt-4o-mini",
        secret=secret_val, parameters={"fallback_priority": 30, "daily_token_limit": 100},
    )
    m_over_monthly = _register(
        slug="sim-over-month", provider="openai", capability="question_planning", model_id="gpt-4.1-mini",
        secret=secret_val, parameters={"fallback_priority": 40, "monthly_cost_limit_usd": 0.05, "input_cost_per_1m_usd": 1000.0},
    )
    m_ref_oa = _register(
        slug="ref-oa-suppressed", provider="openai", capability="reference", model_id="gpt-4.1",
        secret=secret_val, is_default=True, parameters={"fallback_priority": 5},
    )
    m_ref_az = _register(
        slug="ref-az-bad", provider="azure_openai", capability="reference", model_id="az-dep",
        secret=secret_val, endpoint="https://my-res.openai.azure.com", parameters={"fallback_priority": 15},
    )
    m_ref_ok = _register(
        slug="ref-compat-ok", provider="openai_compatible", capability="reference", model_id="qwen-2.5",
        secret=secret_val, endpoint="https://qwen.example.com/v1", parameters={"fallback_priority": 25},
    )
    with store.connection(write=True) as db:
        db.execute("UPDATE connected_models SET endpoint=? WHERE id=?", ("http://127.0.0.1/v1", m_ref_az["id"]))
        enc_blob = db.execute("SELECT encrypted_api_key FROM connected_models WHERE id=?", (m_primary["id"],)).fetchone()[0]
        model_budgets.record_usage(db, m_over_daily["id"], input_tokens=120, output_tokens=0, ok=True, config=m_over_daily["parameters"])
        model_budgets.record_usage(db, m_over_monthly["id"], input_tokens=60, output_tokens=0, ok=True, config=m_over_monthly["parameters"])
    model_execution.QUOTA_LIMITER.consume(m_primary["id"], 3)

    monkeypatch.setattr(secret_box, "decrypt_secret", lambda *a, **kw: (_ for _ in ()).throw(AssertionError("decrypt called")))
    monkeypatch.setattr(provider_http, "fetch_json", lambda *a, **kw: (_ for _ in ()).throw(AssertionError("http called")))
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda *a, **kw: (_ for _ in ()).throw(AssertionError("dns called")))

    env.cookies.set(access.COOKIE, _seed_user())
    res = env.post("/api/admin/models/simulate-chain", json={"capability": "question_planning", "allow_reference_fallback": True})
    assert res.status_code == 200
    body = res.json()
    assert secret_val not in res.text and env_secret not in res.text and enc_blob not in res.text
    assert body["would_fail_503"] is False

    active = body["active_chain"]
    assert [c["rank"] for c in active] == [1, 2]
    assert active[0]["slug"] == m_primary["slug"] and active[0]["rpm_remaining"] == 2 and active[0]["budget_status"] == "ok"
    assert active[1]["slug"] == m_ref_ok["slug"] and active[1]["capability"] == "reference"

    skipped = {(c["slug"] or f"env:{c['provider']}"): c for c in body["skipped"]}
    assert skipped[m_disabled["slug"]]["skip_reason"] == "disabled" and skipped[m_disabled["slug"]]["rank"] is None
    assert skipped[m_over_daily["slug"]]["skip_reason"] == "daily_token_limit_exceeded"
    assert skipped[m_over_daily["slug"]]["budget_status"] == "daily_token_limit_exceeded"
    assert skipped[m_over_monthly["slug"]]["skip_reason"] == "monthly_cost_limit_exceeded"
    assert skipped[m_ref_oa["slug"]]["skip_reason"] == "suppressed_by_primary_capability"
    assert skipped[m_ref_az["slug"]]["skip_reason"] == "invalid_endpoint"
    assert skipped["env:openai"]["skip_reason"] == "suppressed_by_registry"
    assert skipped["env:anthropic"]["skip_reason"] == "suppressed_by_registry"

    model_execution.QUOTA_LIMITER.consume(m_primary["id"], 3)
    model_execution.QUOTA_LIMITER.consume(m_primary["id"], 3)
    slug_res = env.post("/api/admin/models/simulate-chain", json={"capability": "question_planning", "provider": m_primary["slug"]})
    assert slug_res.status_code == 200 and slug_res.json()["would_fail_503"] is True
    assert slug_res.json()["skipped"][0]["skip_reason"] == "rpm_quota_exceeded"
    assert slug_res.json()["skipped"][0]["rpm_remaining"] == 0

    missing = env.post("/api/admin/models/simulate-chain", json={"capability": "judge", "provider": "nonexistent-slug"})
    assert missing.status_code == 200 and missing.json()["active_chain"] == [] and missing.json()["would_fail_503"] is True


def test_diagnostics_endpoint_and_transcription_readiness_states(env):
    env.cookies.set(access.COOKIE, _seed_user())
    d0 = env.get("/api/admin/models/diagnostics")
    assert d0.status_code == 200
    b0 = d0.json()
    assert b0["transcription"] == {"ready": False, "active_provider": None, "active_model": None, "candidate_count": 0}
    assert "usage" in b0 and "telemetry" in b0 and isinstance(b0["generated_at"], str)

    dg = _register(
        slug="dg-diag", provider="deepgram", capability="transcription", model_id="nova-3",
        is_default=True, parameters={"daily_token_limit": 500},
    )
    d1 = env.get("/api/admin/models/diagnostics").json()
    assert d1["transcription"] == {"ready": True, "active_provider": "deepgram", "active_model": "nova-3", "candidate_count": 1}

    with store.connection(write=True) as db:
        model_budgets.record_usage(db, dg["id"], input_tokens=500, output_tokens=0, ok=True, config=dg["parameters"])
    d2 = env.get("/api/admin/models/diagnostics").json()
    assert d2["transcription"] == {"ready": False, "active_provider": None, "active_model": None, "candidate_count": 0}
    assert "sk-m11-sim-secret-9876" not in json.dumps(d2)


def test_audio_http_and_live_ws_metering_budget_failover_and_telemetry(env, monkeypatch):
    p = _register(
        slug="dg-primary", provider="deepgram", capability="transcription", model_id="nova-2",
        secret="dg-secret-primary-1111", is_default=True,
        parameters={"fallback_priority": 10, "daily_token_limit": 100, "rpm_limit": 2},
    )
    s = _register(
        slug="dg-backup", provider="deepgram", capability="transcription", model_id="nova-3",
        secret="dg-secret-backup-2222", is_default=False,
        parameters={"fallback_priority": 20, "daily_token_limit": 500},
    )

    seen_usage = []
    monkeypatch.setattr(audio, "fetch_json", AsyncMock(return_value={
        "results": {"utterances": [{"speaker": 0, "transcript": "Hello world"}]},
        "usage": {"prompt_tokens": 110, "completion_tokens": 10},
    }))
    out = asyncio.run(audio.transcribe_bytes(b"RIFF", "audio/wav", on_usage=lambda i, o: seen_usage.append((i, o))))
    assert out == {"segments": [{"speaker": "0", "text": "Hello world"}]} and seen_usage == [(110, 10)]

    called_models = []

    async def failover_fetch(name, method, url, **kwargs):
        called_models.append(kwargs["params"]["model"])
        return {"results": {"utterances": [{"speaker": 0, "transcript": "Backup tx"}]}, "usage": {"total_tokens": 500}}

    monkeypatch.setattr(audio, "fetch_json", failover_fetch)
    tx_res = env.post("/api/integrations/transcribe", content=b"RIFF", headers={"Content-Type": "audio/wav", "X-Send-Audio": "deepgram"})
    assert tx_res.status_code == 200 and called_models == ["nova-3"]

    over_res = env.post("/api/integrations/transcribe", content=b"RIFF", headers={"Content-Type": "audio/wav", "X-Send-Audio": "deepgram"})
    assert over_res.status_code == 429 and over_res.json()["detail"] == "Model budget ceiling reached."
    with pytest.raises(Exception) as ws_over:
        with env.websocket_connect("ws://127.0.0.1/api/integrations/live", headers={"Origin": "http://127.0.0.1"}):
            pass
    assert getattr(ws_over.value, "code", None) == 1008

    with store.connection(write=True) as db:
        db.execute("DELETE FROM model_usage_daily")
    model_execution.reset_quotas()
    model_execution.QUOTA_LIMITER.consume(p["id"], 2)
    model_execution.QUOTA_LIMITER.consume(p["id"], 2)

    class OkProvider:
        async def __aenter__(self):
            self.q = asyncio.Queue()
            return self

        async def __aexit__(self, *args):
            pass

        async def send(self, data):
            if data == '{"type":"CloseStream"}':
                await self.q.put(json.dumps({"type": "Results", "is_final": True, "channel": {"alternatives": [{"transcript": "Live ok"}]}}))
                await self.q.put(None)

        async def __aiter__(self):
            while (msg := await self.q.get()) is not None:
                yield msg

    connect_urls = []
    monkeypatch.setattr(audio, "connect", lambda url, **kw: (connect_urls.append(url), OkProvider())[1])
    with env.websocket_connect("ws://127.0.0.1/api/integrations/live", headers={"Origin": "http://127.0.0.1"}) as ws:
        ws.send_text("send-audio-to-deepgram")
        assert ws.receive_json() == {"ready": True}
        ws.send_bytes(b"pcm")
        ws.send_text("finish")
        assert ws.receive_json() == {"text": "Live ok"}
    assert "model=nova-3" in connect_urls[0]

    model_execution.reset_quotas()

    class ErrProvider:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            pass

        async def send(self, data):
            pass

        def __aiter__(self):
            return self

        async def __anext__(self):
            return json.dumps({"type": "Error", "message": "upstream boom"})

    monkeypatch.setattr(audio, "connect", lambda url, **kw: ErrProvider())
    with env.websocket_connect("ws://127.0.0.1/api/integrations/live", headers={"Origin": "http://127.0.0.1"}) as ws:
        ws.send_text("send-audio-to-deepgram")
        assert ws.receive_json() == {"ready": True}
        assert "error" in ws.receive_json()

    env.cookies.set(access.COOKIE, _seed_user())
    diag = env.get("/api/admin/models/diagnostics").json()
    assert diag["usage"]["models"][s["id"]]["request_count"] == 1
    assert diag["usage"]["models"][p["id"]]["error_count"] == 1
    assert diag["telemetry"]["models"][s["id"]]["ok_count"] == 2
    assert diag["telemetry"]["models"][p["id"]]["error_count"] == 1
    assert "dg-secret-primary-1111" not in json.dumps(diag) and "dg-secret-backup-2222" not in json.dumps(diag)
