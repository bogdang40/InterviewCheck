"""Tests for M11 model budgets, token/cost metering, chain failover, and fleet usage."""
import asyncio
import json
import math
from unittest.mock import AsyncMock
from uuid import uuid4

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest

from api import (
    access, account_db, authoring, integrations, model_budgets,
    model_execution, model_registry, model_resolver, scoring_hooks,
    secret_box, ssrf_guard, store,
)
from api.main import app


def _seed_admin(email: str = "budget-admin@example.invalid") -> str:
    uid, ts = str(uuid4()), account_db.now()
    with account_db.connection(write=True) as db:
        db.execute(
            "INSERT INTO users(id, email, password_hash, role, disabled, created_at, updated_at) VALUES (?,?,?,?,0,?,?)",
            (uid, email, account_db.DECOY, "admin", ts, ts),
        )
        return account_db.issue(db, uid, "pytest")


def _register(
    *,
    slug: str,
    provider: str = "openai",
    capability: str = "reference",
    model_id: str = "gpt-4o",
    secret: str = "sk-m11-secret-1234",
    is_default: bool = False,
    parameters: dict | None = None,
) -> dict:
    uid = str(uuid4())
    enc = secret_box.encrypt_secret(secret, aad=uid) if secret else None
    hint = secret_box.mask_key_hint(secret) if secret else None
    with store.connection(write=True) as db:
        return model_registry.create_model(
            db, model_uuid=uid, slug=slug, display_name=f"Model {slug}", provider=provider,
            capability=capability, model_id=model_id, endpoint=None, api_version=None,
            parameters=parameters or {}, encrypted_api_key=enc, key_hint=hint,
            enabled=True, is_default=is_default,
        )


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "fixture-m11-budget-key")
    for key in (
        "INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL",
        "INTERVIEWCHECK_PUBLIC_ORIGIN", "OPENAI_API_KEY", "INTERVIEWCHECK_REFERENCE_MODEL",
        "ANTHROPIC_API_KEY", "INTERVIEWCHECK_ANTHROPIC_MODEL", "INTERVIEWCHECK_EMBEDDING_MODEL",
        "INTERVIEWCHECK_JUDGE_MODEL", "DEEPGRAM_API_KEY",
    ):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])
    model_execution.reset_quotas()
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def test_schema_migration_cascade_and_backup_exclusion(env):
    with store.connection() as db:
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        indexes = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='index'")}
    assert "model_usage_daily" in tables
    assert "idx_model_usage_date" in indexes

    m = _register(slug="cascade-budget", is_default=True, parameters={"input_cost_per_1m_usd": 2.0})
    with store.connection(write=True) as db:
        model_budgets.record_usage(db, m["id"], input_tokens=500, output_tokens=100, ok=True, config=m["parameters"])
        assert db.execute("SELECT count(*) FROM model_usage_daily WHERE model_id=?", (m["id"],)).fetchone()[0] == 1

    env.cookies.set(access.COOKIE, _seed_admin())
    backup = env.get("/api/backups/workspace")
    assert backup.status_code == 200 and "model_usage_daily" not in backup.text

    assert env.delete(f"/api/admin/models/{m['id']}").status_code == 200
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM model_usage_daily WHERE model_id=?", (m["id"],)).fetchone()[0] == 0


def test_budget_schema_validation_bounds_and_patch_persistence(env):
    env.cookies.set(access.COOKIE, _seed_admin())
    base = {
        "slug": "budget-valid", "display_name": "Budget Valid", "provider": "openai",
        "capability": "reference", "model_id": "gpt-4o", "apiKey": "sk-valid-budget-1234",
        "parameters": {
            "fallback_priority": 10, "daily_token_limit": 50_000,
            "monthly_cost_limit_usd": 25.5, "input_cost_per_1m_usd": 2.5, "output_cost_per_1m_usd": 10.0,
        },
    }
    res = env.post("/api/admin/models", json=base)
    assert res.status_code == 201
    mid = res.json()["model"]["id"]
    params = res.json()["model"]["parameters"]
    assert params["daily_token_limit"] == 50_000
    assert params["monthly_cost_limit_usd"] == 25.5
    assert params["input_cost_per_1m_usd"] == 2.5
    assert params["output_cost_per_1m_usd"] == 10.0

    edge = env.post("/api/admin/models", json={
        **base, "slug": "budget-edge", "parameters": {
            "daily_token_limit": 1, "monthly_cost_limit_usd": 0.01,
            "input_cost_per_1m_usd": 0, "output_cost_per_1m_usd": 1000.0,
        },
    })
    assert edge.status_code == 201

    cleared = env.patch(f"/api/admin/models/{mid}", json={"parameters": {"daily_token_limit": None}})
    assert cleared.status_code == 200
    assert cleared.json()["model"]["parameters"]["daily_token_limit"] is None
    assert cleared.json()["model"]["parameters"]["monthly_cost_limit_usd"] == 25.5

    bad_cases = [
        {"daily_token_limit": 0}, {"daily_token_limit": -1}, {"daily_token_limit": 100_000_001},
        {"daily_token_limit": True}, {"daily_token_limit": 10.5},
        {"monthly_cost_limit_usd": 0.0}, {"monthly_cost_limit_usd": 0.009}, {"monthly_cost_limit_usd": 100_000.01},
        {"monthly_cost_limit_usd": True}, {"input_cost_per_1m_usd": -0.01}, {"input_cost_per_1m_usd": 1000.01},
        {"output_cost_per_1m_usd": -1.0}, {"output_cost_per_1m_usd": 1001.0}, {"output_cost_per_1m_usd": False},
    ]
    for bad in bad_cases:
        resp = env.post("/api/admin/models", json={**base, "slug": f"bad-{uuid4().hex[:6]}", "parameters": bad})
        assert resp.status_code == 422, f"Expected 422 for {bad}, got {resp.status_code}"

    nan_body = (
        b'{"slug":"nan-budget","display_name":"NaN","provider":"openai","capability":"reference",'
        b'"model_id":"gpt-4o","apiKey":"sk-1234567890","parameters":{"monthly_cost_limit_usd":NaN}}'
    )
    assert env.post("/api/admin/models", content=nan_body, headers={"Content-Type": "application/json"}).status_code == 422


def test_extract_usage_across_providers_and_edge_cases():
    assert model_budgets.extract_usage("openai", {"usage": {"prompt_tokens": 120, "completion_tokens": 45}}) == (120, 45)
    assert model_budgets.extract_usage("openai", {"usage": {"input_tokens": 80, "output_tokens": 20}}) == (80, 20)
    assert model_budgets.extract_usage("openai", {"usage": {"prompt_tokens": 33, "total_tokens": 33}}) == (33, 0)
    assert model_budgets.extract_usage("openai_compatible", {"usage": {"total_tokens": 64}}) == (0, 0)
    assert model_budgets.extract_usage("anthropic", {"usage": {"input_tokens": 210, "output_tokens": 90}}) == (210, 90)
    assert model_budgets.extract_usage("azure_openai", {"usage": {"prompt_tokens": -5, "completion_tokens": True}}) == (0, 0)
    assert model_budgets.extract_usage("openai", None) == (0, 0)
    assert model_budgets.extract_usage("openai", {"usage": "bad"}) == (0, 0)


def test_check_budget_daily_tokens_monthly_cost_and_period_boundaries(env):
    m = _register(
        slug="period-test",
        is_default=True,
        parameters={
            "daily_token_limit": 1000,
            "monthly_cost_limit_usd": 1.50,
            "input_cost_per_1m_usd": 1000.0,
            "output_cost_per_1m_usd": 1000.0,
        },
    )
    cfg = m["parameters"]
    with store.connection(write=True) as db:
        # Prior month cost does not count toward current month or today
        model_budgets.record_usage(db, m["id"], input_tokens=5000, output_tokens=0, ok=True, config=cfg, usage_date="2026-10-15")
        # Earlier day in same month: 800 tokens -> $0.80 (does not count toward today's daily tokens)
        model_budgets.record_usage(db, m["id"], input_tokens=800, output_tokens=0, ok=True, config=cfg, usage_date="2026-11-01")
        d1 = model_budgets.check_budget(db, m["id"], cfg, today="2026-11-19")
        assert d1.allowed is True and d1.daily_tokens == 0 and d1.monthly_cost_usd == pytest.approx(0.80)

        # Add 600 tokens today ($0.60 -> monthly $1.40 < $1.50, daily 600 < 1000)
        model_budgets.record_usage(db, m["id"], input_tokens=400, output_tokens=200, ok=True, config=cfg, usage_date="2026-11-19")
        d2 = model_budgets.check_budget(db, m["id"], cfg, today="2026-11-19")
        assert d2.allowed is True and d2.daily_tokens == 600 and d2.monthly_cost_usd == pytest.approx(1.40)

        # Add 150 tokens today ($0.15 -> monthly $1.55 >= $1.50, daily 750 < 1000)
        model_budgets.record_usage(db, m["id"], input_tokens=150, output_tokens=0, ok=False, config=cfg, usage_date="2026-11-19")
        d3 = model_budgets.check_budget(db, m["id"], cfg, today="2026-11-19")
        assert d3.allowed is False and d3.reason == "monthly_cost_limit_exceeded"

        # Add 250 more tokens today -> daily 1000 >= 1000 (daily check triggers first)
        model_budgets.record_usage(db, m["id"], input_tokens=250, output_tokens=0, ok=True, config=cfg, usage_date="2026-11-19")
        d4 = model_budgets.check_budget(db, m["id"], cfg, today="2026-11-19")
        assert d4.allowed is False and d4.reason == "daily_token_limit_exceeded" and d4.daily_tokens == 1000


def test_execution_metering_hooks_and_dispatch_compat(env, monkeypatch):
    seen_hooks = []
    comp_target = model_resolver.ResolvedModel(
        "registry", None, None, "Compat", "openai_compatible", "reference", "llama", "", "https://llm.example.com", None, {}, "connected"
    )
    out = asyncio.run(model_resolver.dispatch_completion(
        comp_target, "sys", "usr",
        fetch_fn=AsyncMock(return_value={"choices": [{"finish_reason": "stop", "message": {"content": "ok"}}], "usage": {"prompt_tokens": 11, "completion_tokens": 7}}),
        on_usage=lambda i, o: seen_hooks.append((i, o)),
    ))
    assert out == ("llama", "ok") and seen_hooks == [(11, 7)]

    q_model = _register(
        slug="q-meter", provider="openai", capability="question_planning", model_id="gpt-4o",
        is_default=True, parameters={"input_cost_per_1m_usd": 5.0, "output_cost_per_1m_usd": 15.0},
    )
    emb_model = _register(
        slug="emb-meter", provider="openai", capability="embedding", model_id="text-embedding-3-small",
        is_default=True, parameters={"input_cost_per_1m_usd": 1.0},
    )
    ref_model = _register(
        slug="ref-meter", provider="openai", capability="reference", model_id="gpt-4o",
        is_default=True, parameters={"input_cost_per_1m_usd": 2.0, "output_cost_per_1m_usd": 8.0},
    )

    monkeypatch.setattr(authoring, "fetch_json", AsyncMock(return_value={
        "choices": [{"finish_reason": "stop", "message": {"content": '["Q1?"]'}}],
        "usage": {"prompt_tokens": 1000, "completion_tokens": 500},
    }))
    assert env.post("/api/authoring/questions", json={"provider": "OpenAI", "role": "SRE", "description": "Scale"}).status_code == 200

    monkeypatch.setattr(scoring_hooks, "fetch_json", AsyncMock(return_value={
        "data": [{"index": 0, "embedding": [1.0, 0.0]}, {"index": 1, "embedding": [1.0, 0.0]}],
        "usage": {"prompt_tokens": 400, "total_tokens": 400},
    }))
    assert env.post("/api/scoring/semantic", json={"answer": "a", "references": [{"label": "R", "text": "r", "permitted": False}]}).status_code == 200

    monkeypatch.setattr(integrations, "fetch_json", AsyncMock(return_value={
        "status": "completed",
        "output": [{"type": "message", "content": [{"type": "output_text", "text": "Ref answer"}]}],
        "usage": {"input_tokens": 200, "output_tokens": 100},
    }))
    assert env.post("/api/integrations/reference", json={"role": "SRE", "question": "Q?"}).status_code == 200

    with store.connection() as db:
        fleet = model_budgets.fleet_usage_summary(db)
    assert fleet["models"][q_model["id"]]["daily_tokens"] == 1500
    assert fleet["models"][q_model["id"]]["monthly_cost_usd"] == pytest.approx(0.0125)
    assert fleet["models"][emb_model["id"]]["daily_tokens"] == 400
    assert fleet["models"][ref_model["id"]]["daily_tokens"] == 300
    assert fleet["summary"]["daily_tokens"] == 2200
    assert fleet["summary"]["request_count"] == 3


def test_budget_failover_429_exhaustion_and_non_budget_error_preservation(env, monkeypatch):
    p = _register(
        slug="bud-primary", provider="openai", capability="judge", model_id="gpt-4o",
        is_default=True, parameters={"fallback_priority": 10, "daily_token_limit": 100, "input_cost_per_1m_usd": 10.0},
    )
    s = _register(
        slug="bud-backup", provider="anthropic", capability="judge", model_id="claude-sonnet-4-6",
        is_default=False, parameters={"fallback_priority": 20, "monthly_cost_limit_usd": 0.02, "input_cost_per_1m_usd": 1000.0},
    )
    called_urls = []

    async def judge_fetch(name, method, url, **kwargs):
        called_urls.append(url)
        if "openai.com" in url:
            return {
                "choices": [{"finish_reason": "stop", "message": {"content": '{"likelihood": 50, "confidence": "low"}'}}],
                "usage": {"prompt_tokens": 80, "completion_tokens": 30},
            }
        return {
            "stop_reason": "end_turn",
            "content": [{"type": "text", "text": '{"likelihood": 90, "confidence": "high"}'}],
            "usage": {"input_tokens": 25, "output_tokens": 0},
        }

    monkeypatch.setattr(scoring_hooks, "fetch_json", judge_fetch)
    # 1st call hits primary (110 tokens >= daily_token_limit 100)
    r1 = env.post("/api/scoring/judge", json={"question": "Q?", "answer": "A"})
    assert r1.status_code == 200 and r1.json()["provider"] == "openai"

    # 2nd call skips primary cleanly (no openai call) and fails over to anthropic (cost $0.025 >= $0.02)
    called_urls.clear()
    r2 = env.post("/api/scoring/judge", json={"question": "Q?", "answer": "A"})
    assert r2.status_code == 200 and r2.json()["provider"] == "anthropic"
    assert called_urls == ["https://api.anthropic.com/v1/messages"]

    # 3rd call: both candidates exceed budget -> 429 "Model budget ceiling reached." with zero external calls
    called_urls.clear()
    r3 = env.post("/api/scoring/judge", json={"question": "Q?", "answer": "A"})
    assert r3.status_code == 429 and r3.json()["detail"] == "Model budget ceiling reached."
    assert called_urls == []

    # Mixed failure: primary over budget, backup returns 503 -> still 429 "Model budget ceiling reached."
    with store.connection(write=True) as db:
        db.execute("DELETE FROM model_usage_daily WHERE model_id=?", (s["id"],))
    monkeypatch.setattr(scoring_hooks, "fetch_json", AsyncMock(side_effect=HTTPException(503, "Anthropic down")))
    r4 = env.post("/api/scoring/judge", json={"question": "Q?", "answer": "A"})
    assert r4.status_code == 429 and r4.json()["detail"] == "Model budget ceiling reached."

    # Non-budget failure: clear both budgets and verify 503 is preserved
    with store.connection(write=True) as db:
        db.execute("DELETE FROM model_usage_daily")
    r5 = env.post("/api/scoring/judge", json={"question": "Q?", "answer": "A"})
    assert r5.status_code == 503

    with store.connection() as db:
        summary = model_budgets.fleet_usage_summary(db)
    assert summary["models"][p["id"]]["error_count"] == 1
    assert summary["models"][s["id"]]["error_count"] == 1
    assert summary["summary"]["error_count"] == 2


def test_extreme_usage_tokens_clamped_and_budget_enforced(env, monkeypatch):
    cost = model_budgets.estimate_cost_usd(10**308, 0, {"input_cost_per_1m_usd": 1000.0})
    assert math.isfinite(cost) and cost > 0.0
    assert model_budgets.clamp_tokens(10**400) == model_budgets.MAX_TOKEN_COUNT

    for idx, extreme_prompt_tokens in enumerate((2**63, 1e30)):
        m = _register(
            slug=f"overflow-{idx}",
            provider="openai",
            capability="judge",
            model_id="gpt-4o",
            is_default=(idx == 0),
            parameters={"fallback_priority": idx + 1, "daily_token_limit": 100, "input_cost_per_1m_usd": 10.0},
        )
        monkeypatch.setattr(
            scoring_hooks,
            "fetch_json",
            AsyncMock(
                return_value={
                    "choices": [{"finish_reason": "stop", "message": {"content": '{"likelihood": 50, "confidence": "low"}'}}],
                    "usage": {"prompt_tokens": extreme_prompt_tokens, "completion_tokens": 0},
                }
            ),
        )
        res = env.post("/api/scoring/judge", json={"question": "Q?", "answer": "A"})
        assert res.status_code == 200
        with store.connection() as db:
            row = db.execute(
                "SELECT input_tokens, output_tokens FROM model_usage_daily WHERE model_id=?", (m["id"],)
            ).fetchone()
            assert row is not None and row["input_tokens"] == model_budgets.MAX_TOKEN_COUNT and row["output_tokens"] == 0
            assert not model_budgets.check_budget(db, m["id"], m["parameters"]).allowed

    blocked = env.post("/api/scoring/judge", json={"question": "Q?", "answer": "A"})
    assert blocked.status_code == 429 and blocked.json()["detail"] == "Model budget ceiling reached."


def test_overflow_10_pow_400_and_non_finite_float_guards(env, monkeypatch):
    from api import model_circuit

    _register(slug="ovf-judge", provider="openai", capability="judge", model_id="gpt-4o", is_default=True)
    emb = _register(slug="ovf-emb", provider="openai", capability="embedding", model_id="text-embedding-3-small", is_default=True)

    captured = {}

    async def capture_judge(name, method, url, **kwargs):
        captured["payload"] = json.loads(kwargs["json"]["messages"][-1]["content"])
        return {
            "choices": [{"finish_reason": "stop", "message": {"content": '{"likelihood": 42, "confidence": "low"}'}}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1},
        }

    monkeypatch.setattr(scoring_hooks, "fetch_json", capture_judge)
    sig_body = f'{{"question":"Q?","answer":"A","signals":{{"huge":{10**400},"nan":NaN,"ok":2}}}}'.encode()
    r1 = env.post("/api/scoring/judge", content=sig_body, headers={"Content-Type": "application/json"})
    assert r1.status_code == 200
    assert captured["payload"]["signals"] == {"ok": 2.0}

    monkeypatch.setattr(
        scoring_hooks,
        "fetch_json",
        AsyncMock(return_value={
            "choices": [{"finish_reason": "stop", "message": {"content": f'{{"likelihood": {10**400}, "confidence": "low"}}'}}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1},
        }),
    )
    assert env.post("/api/scoring/judge", json={"question": "Q?", "answer": "A"}).status_code == 502

    for bad_vec in ([10**400, 1.0], [float("nan"), 1.0], [float("inf"), 1.0], [True, 1.0]):
        with store.connection(write=True) as db:
            model_circuit.record_outcome(db, emb["id"], ok=True)
        monkeypatch.setattr(
            scoring_hooks,
            "fetch_json",
            AsyncMock(return_value={
                "data": [{"index": 0, "embedding": bad_vec}, {"index": 1, "embedding": [1.0, 1.0]}],
                "usage": {"prompt_tokens": 1, "total_tokens": 1},
            }),
        )
        assert env.post("/api/scoring/semantic", json={"answer": "a", "references": [{"label": "R", "text": "r", "permitted": False}]}).status_code == 502

    assert model_execution._safe_timeout(10**400, default=30.0, low=1.0, high=180.0) == 30.0
    assert model_execution._safe_timeout(float("nan"), default=75.0, low=1.0, high=180.0) == 75.0
