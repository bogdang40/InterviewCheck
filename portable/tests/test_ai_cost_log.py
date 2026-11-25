"""AI cost log: every provider call is logged per account, company, provider and model, without text."""
from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest

from api import authoring, rate_limit, ssrf_guard, store
from api.main import app

QUESTION = "How would you keep a slow dependency from taking down checkout?"


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "fixture-cost-log-secret-key")
    for key in ("INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("ADMIN_EMAILS", "owner@acme.example")
    monkeypatch.setenv("ADMIN_BOOTSTRAP_SECRET", "bootstrap-fixture-secret")
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])
    rate_limit.reset_all()
    store.initialize(store.db_path())
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def _admin_with_model(web):
    signup = web.post("/api/integrations/access/signup",
                      json={"email": "owner@acme.example", "password": "strong-password-1", "adminSecret": "bootstrap-fixture-secret"})
    assert signup.status_code == 200 and signup.json()["admin"] is True
    created = web.post("/api/admin/models", json={
        "slug": "team-gpt", "display_name": "Team GPT", "provider": "azure_openai", "capability": "reference",
        "model_id": "team-gpt-dep", "endpoint": "https://acme.cognitiveservices.azure.com", "api_version": "2025-04-01-preview",
        "apiKey": "azure-fixture-key-123456", "is_default": True,
        "parameters": {"input_cost_per_1m_usd": 2.0, "output_cost_per_1m_usd": 10.0},
    })
    assert created.status_code == 201, created.text


def _azure_reply(*_args, **_kwargs):
    return {"choices": [{"finish_reason": "stop", "message": {"content": "Use timeouts and a circuit breaker."}}],
            "usage": {"prompt_tokens": 1000, "completion_tokens": 500, "total_tokens": 1500}}


def _ask(web):
    return web.post("/api/authoring/reference", json={"provider": "Azure OpenAI", "style": "Spoken answer",
                                                      "question": QUESTION, "role": "Backend engineer"})


def test_each_call_is_logged_per_company_account_provider_and_model(env, monkeypatch):
    _admin_with_model(env)

    async def ok(*args, **kwargs):
        return _azure_reply()
    monkeypatch.setattr(authoring, "fetch_json", ok)
    assert _ask(env).status_code == 200
    assert _ask(env).status_code == 200

    body = env.get("/api/admin/usage/ai-costs?days=7").json()
    expected = round(2 * (1000 * 2.0 + 500 * 10.0) / 1_000_000, 6)
    assert body["totals"] == {"requests": 2, "errors": 0, "input_tokens": 2000, "output_tokens": 1000, "cost_usd": expected}
    assert body["by_company"][0]["company"] == "acme.example" and body["by_company"][0]["accounts"] == 1
    row = body["by_company_model"][0]
    assert (row["account_email"], row["provider"], row["model_id"], row["model_name"], row["capability"]) == (
        "owner@acme.example", "azure_openai", "team-gpt-dep", "Team GPT", "reference")
    assert body["by_provider_model"][0]["requests"] == 2
    assert body["by_month"][0]["month"] == body["last_day"][:7]
    assert body["recent"][0]["ok"] == 1 and body["recent"][0]["input_tokens"] == 1000

    csv = env.get("/api/admin/usage/ai-costs.csv?days=7")
    assert csv.status_code == 200 and "attachment" in csv.headers["content-disposition"]
    lines = csv.text.strip().splitlines()
    assert lines[0].startswith("at,company,account_email") and len(lines) == 3
    with store.connection() as db:
        stored = " ".join(str(v) for row in db.execute("SELECT * FROM ai_cost_log") for v in tuple(row))
    assert "slow dependency" not in stored and "circuit breaker" not in stored  # no prompt or answer text


def test_failed_calls_are_logged_as_errors(env, monkeypatch):
    _admin_with_model(env)

    async def broken(*args, **kwargs):
        raise HTTPException(503, "Provider unavailable.")
    monkeypatch.setattr(authoring, "fetch_json", broken)
    assert _ask(env).status_code >= 500
    totals = env.get("/api/admin/usage/ai-costs").json()["totals"]
    assert totals["requests"] >= 1 and totals["errors"] == totals["requests"] and totals["cost_usd"] == 0


def test_cost_log_is_for_admins_only(env, monkeypatch):
    assert env.get("/api/admin/usage/ai-costs").status_code in (401, 403)
    assert env.get("/api/admin/usage/ai-costs.csv").status_code in (401, 403)
    member = env.post("/api/integrations/access/signup", json={"email": "member@acme.example", "password": "strong-password-2"})
    assert member.status_code == 200
    assert env.get("/api/admin/usage/ai-costs").status_code == 403
