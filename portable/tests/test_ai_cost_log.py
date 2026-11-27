"""AI cost log: every provider call is logged per account, company, provider and model, without text."""
import csv
from io import StringIO

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest

from api import authoring, provider_http, rate_limit, ssrf_guard, store
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
    return created.json()["model"]["id"]


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
    assert body["totals"] == {
        "requests": 2, "errors": 0, "input_tokens": 2000, "output_tokens": 1000, "unsplit_tokens": 0, "cost_usd": expected,
        "estimated_requests": 2, "missing_rate_requests": 0, "missing_usage_requests": 0, "unknown_requests": 0,
    }
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
    assert totals["missing_usage_requests"] == totals["requests"]


@pytest.mark.parametrize("guard", ["preflight", "transport"])
def test_local_refusals_preserve_diagnostics_without_recording_spend(env, monkeypatch, guard):
    model_id = _admin_with_model(env)

    async def blocked(*args, **kwargs):
        cause = ssrf_guard.SSRFValidationError("Fixture endpoint refused.")
        if guard == "transport":
            raise HTTPException(502, "Fixture endpoint refused.") from cause
        raise cause

    if guard == "preflight":
        monkeypatch.setattr(ssrf_guard, "validate_endpoint_url_async", blocked)
    else:
        monkeypatch.setattr(authoring, "fetch_json", blocked)
    assert _ask(env).status_code in (400, 502)
    assert env.get("/api/admin/usage/ai-costs").json()["totals"]["requests"] == 0
    diagnostic = env.get("/api/admin/models/diagnostics").json()
    assert diagnostic["usage"]["models"][model_id]["monthly_requests"] == 0
    assert diagnostic["telemetry"]["models"][model_id]["error_count"] == 1


def test_reported_zero_and_omitted_completion_count_remain_distinct(env, monkeypatch):
    model_id = _admin_with_model(env)
    calls = iter(({"prompt_tokens": 100, "completion_tokens": 0}, {"prompt_tokens": 100}, {"total_tokens": 100}))

    async def provider(*args, **kwargs):
        return {**_azure_reply(), "usage": next(calls)}

    monkeypatch.setattr(authoring, "fetch_json", provider)
    assert env.patch(f"/api/admin/models/{model_id}", json={"parameters": {"input_cost_per_1m_usd": 0}}).is_success
    for _ in range(3):
        assert _ask(env).is_success
    log = env.get("/api/admin/usage/ai-costs").json()
    assert log["totals"]["estimated_requests"] == 1 and log["totals"]["missing_usage_requests"] == 2
    assert log["totals"]["cost_usd"] == 0
    assert [row["estimate_status"] for row in log["recent"]] == ["missing_usage", "missing_usage", "estimated"]


def test_cost_log_is_for_admins_only(env, monkeypatch):
    assert env.get("/api/admin/usage/ai-costs").status_code in (401, 403)
    assert env.get("/api/admin/usage/ai-costs.csv").status_code in (401, 403)
    member = env.post("/api/integrations/access/signup", json={"email": "member@acme.example", "password": "strong-password-2"})
    assert member.status_code == 200
    assert env.get("/api/admin/usage/ai-costs").status_code == 403


def test_unsplit_usage_counts_toward_token_guard_without_assigning_a_price(env, monkeypatch):
    model_id = _admin_with_model(env)
    # Existing model has unequal input and output prices. Two calls exhaust its token limit.
    assert env.patch(f"/api/admin/models/{model_id}", json={"parameters": {"daily_token_limit": 2000}}).is_success

    async def fetch(*args, **kwargs):
        return {**_azure_reply(), "usage": {"total_tokens": 1000}}

    monkeypatch.setattr(authoring, "fetch_json", fetch)
    monkeypatch.setattr(provider_http, "fetch_json", fetch)
    assert _ask(env).is_success
    payload = {"model_ids": [model_id], "system_prompt": "Summarize.", "user_input": "Sample."}
    result = env.post("/api/admin/models/playground/run", json=payload).json()["results"][0]
    assert (result["input_tokens"], result["output_tokens"], result["unsplit_tokens"]) == (0, 0, 1000)
    assert result["estimated_cost_usd"] == 0 and result["estimate_status"] == "missing_usage"
    assert _ask(env).status_code == 429
    report = env.get("/api/admin/usage/ai-costs").json()
    for row in report["recent"]:
        assert (row["input_tokens"], row["output_tokens"], row["unsplit_tokens"], row["cost_usd"]) == (0, 0, 1000, 0)
    totals = report["totals"]
    assert (totals["unsplit_tokens"], totals["missing_usage_requests"], totals["cost_usd"]) == (2000, 2, 0)
    exported = list(csv.DictReader(StringIO(env.get("/api/admin/usage/ai-costs.csv").text)))
    assert len(exported) == 2
    for row in exported:
        assert (row["input_tokens"], row["output_tokens"], row["unsplit_tokens"]) == ("0", "0", "1000")
        assert row["estimate_status"] == "missing_usage" and float(row["cost_usd"]) == 0
    daily = env.get("/api/admin/models/diagnostics").json()["usage"]["models"][model_id]
    assert daily["daily_tokens"] == daily["daily_unsplit_tokens"] == daily["monthly_tokens"] == 2000
    assert daily["daily_cost_usd"] == daily["monthly_cost_usd"] == 0
    assert daily["daily_input_tokens"] == daily["daily_output_tokens"] == 0


def test_playground_costs_match_known_usage_and_skip_budget_denials(env, monkeypatch):
    model_id = _admin_with_model(env)
    limit = env.patch(f"/api/admin/models/{model_id}", json={"parameters": {"monthly_cost_limit_usd": 0.01}})
    assert limit.status_code == 200
    payload = {"model_ids": [model_id], "system_prompt": "Use the sample.", "user_input": "Private example text"}
    attempts = []

    async def fetch(*args, **kwargs):
        attempts.append(args[0])
        reply = _azure_reply()
        if len(attempts) == 2:
            reply["choices"][0]["finish_reason"] = "length"
        return reply

    monkeypatch.setattr(provider_http, "fetch_json", fetch)
    for expected_status, expected_cost in ((200, 0.007), (502, 0.007), (429, 0.0)):
        response = env.post("/api/admin/models/playground/run", json=payload)
        assert response.status_code == 200
        result = response.json()["results"][0]
        assert result["http_status"] == expected_status
        assert result["estimated_cost_usd"] == pytest.approx(expected_cost)
        assert result["estimate_status"] == ("not_called" if expected_status == 429 else "estimated")

    assert len(attempts) == 2
    log = env.get("/api/admin/usage/ai-costs").json()
    assert log["totals"] == {
        "requests": 2, "errors": 1, "input_tokens": 2000, "output_tokens": 1000, "unsplit_tokens": 0, "cost_usd": 0.014,
        "estimated_requests": 2, "missing_rate_requests": 0, "missing_usage_requests": 0, "unknown_requests": 0,
    }
    assert [(c["ok"], c["http_status"]) for c in log["recent"]] == [(0, 502), (1, 200)]
    for entry in log["recent"]:
        assert (entry["account_email"], entry["company"], entry["capability"], entry["provider"], entry["model_id"]) == (
            "owner@acme.example", "acme.example", "playground", "azure_openai", "team-gpt-dep",
        )
    diagnostics = env.get("/api/admin/models/diagnostics").json()["usage"]["models"][model_id]
    assert diagnostics["monthly_requests"] == 2 and diagnostics["monthly_cost_usd"] == 0.014
    csv = env.get("/api/admin/usage/ai-costs.csv")
    assert csv.status_code == 200 and csv.text.count(",playground,") == 2
    assert payload["user_input"] not in csv.text and payload["system_prompt"] not in csv.text


def test_playground_local_endpoint_rejection_is_absent_from_cost_log(env, monkeypatch):
    model_id = _admin_with_model(env)

    async def reject(*args, **kwargs):
        raise ssrf_guard.SSRFValidationError("Endpoint unavailable.")

    monkeypatch.setattr(ssrf_guard, "validate_endpoint_url_async", reject)
    response = env.post("/api/admin/models/playground/run", json={
        "model_ids": [model_id], "system_prompt": "Use the sample.", "user_input": "Private example",
    })
    assert response.status_code == 200 and response.json()["results"][0]["http_status"] == 400
    assert response.json()["results"][0]["estimate_status"] == "not_called"
    assert env.get("/api/admin/usage/ai-costs").json()["totals"]["requests"] == 0
    diagnostics = env.get("/api/admin/models/diagnostics").json()
    assert diagnostics["usage"]["models"][model_id]["monthly_requests"] == 0
    assert diagnostics["telemetry"]["models"][model_id]["error_count"] == 1


@pytest.mark.parametrize(("rates", "usage", "status", "cost"), (
    ({"output_cost_per_1m_usd": None}, {"prompt_tokens": 100, "completion_tokens": 5}, "missing_rates", 0.0002),
    ({}, {"prompt_tokens": 100}, "missing_usage", 0.0002),
    ({}, {}, "missing_usage", 0.0),
    ({"input_cost_per_1m_usd": 0, "output_cost_per_1m_usd": 0},
     {"prompt_tokens": 100, "completion_tokens": 5}, "estimated", 0.0),
))
def test_playground_returns_the_estimate_status_stored_in_usage(env, monkeypatch, rates, usage, status, cost):
    model_id = _admin_with_model(env)
    if rates:
        assert env.patch(f"/api/admin/models/{model_id}", json={"parameters": rates}).is_success

    async def provider(*args, **kwargs):
        return {**_azure_reply(), "usage": usage}

    monkeypatch.setattr(provider_http, "fetch_json", provider)
    response = env.post("/api/admin/models/playground/run", json={
        "model_ids": [model_id], "system_prompt": "Use the sample.", "user_input": "Example",
    })
    assert response.is_success
    result = response.json()["results"][0]
    logged = env.get("/api/admin/usage/ai-costs").json()["recent"][0]
    assert result["estimate_status"] == logged["estimate_status"] == status
    assert result["estimated_cost_usd"] == logged["cost_usd"] == pytest.approx(cost)


def test_cost_window_matches_all_groups_and_csv(env, monkeypatch):
    from api import usage_events

    _admin_with_model(env)
    monkeypatch.setattr(usage_events, "today", lambda: "2026-12-02")
    rows = [
        ("2026-11-25", "selected.test", 0, "before"),
        ("2026-11-26", "selected.test", 0, "=model"),
        ("2026-11-29", "selected.test", 1, "ok"),
        ("2026-12-02", "selected.test", 0, "latest"),
        ("2026-12-02", "other.test", 0, "other"),
        ("2026-12-03", "selected.test", 0, "after"),
    ]
    with store.connection(write=True) as db:
        db.executemany("""INSERT INTO ai_cost_log(at,company,ok,model_id,day,capability,provider)
                          VALUES(?,?,?,?,?,'judge','openai')""",
                       [(day, company, ok, model, day) for day, company, ok, model in rows])
    params = {"company": "selected.test", "days": 7, "failed_only": "true"}
    route = "/api/admin/usage/ai-costs"
    result = env.get(route, params=params).json()
    assert result["first_day"] == "2026-11-26" and result["last_day"] == "2026-12-02"
    assert result["companies"] == ["other.test", "selected.test"]
    assert result["totals"]["requests"] == result["totals"]["errors"] == 2
    for group in ("by_company", "by_company_model", "by_provider_model", "by_month"):
        assert sum(row["requests"] for row in result[group]) == 2
    assert [row["month"] for row in result["by_month"]] == ["2026-12", "2026-11"]
    assert [row["model_id"] for row in result["recent"]] == ["latest", "=model"]
    with store.connection(write=True) as db:
        db.execute("""INSERT INTO ai_cost_log(at,day,company,ok,model_id,capability,provider)
                      VALUES ('2026-12-02','2026-12-02','selected.test',0,'after-view','judge','openai')""")
    monkeypatch.setattr(usage_events, "today", lambda: "2026-12-03")
    receipt = {**params, "end_day": result["last_day"], "through_id": result["through_id"]}
    response = env.get(route + ".csv", params=receipt)
    assert response.headers["cache-control"] == "no-store"
    exported = list(csv.DictReader(StringIO(response.text)))
    assert [row["model_id"] for row in exported] == ["'=model", "latest"]
    empty = env.get(route, params={"company": "unknown.test"}).json()
    assert empty["totals"]["requests"] == 0 and empty["recent"] == []


def test_csv_preserves_the_last_call_in_large_period(env, monkeypatch):
    from api import usage_events

    _admin_with_model(env)
    monkeypatch.setattr(usage_events, "today", lambda: "2026-12-02")
    with store.connection(write=True) as db:
        db.execute("""WITH RECURSIVE seq(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM seq WHERE n<100001)
                      INSERT INTO ai_cost_log(at,day,company,capability,provider,model_id,ok)
                      SELECT '2026-12-02','2026-12-02','bulk.test','judge','openai','model-' || n,1 FROM seq""")
    response = env.get("/api/admin/usage/ai-costs.csv", params={"days": 1, "company": "bulk.test"})
    assert response.status_code == 200
    assert response.content.count(b"\r\n") == 100002
    assert b"model-100001," in response.content
