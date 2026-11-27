"""Verify local refusal attribution and admission precedence at the actual transport boundary."""
import asyncio
from datetime import datetime, timezone
from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException

from api import model_budgets, model_circuit, model_execution, model_resolver, provider_allowance, provider_http, ssrf_guard, store
from test_provider_allowance import ROUTE, set_limit, sign_in, web


def registered(web, *, key="synthetic-model-secret", **params):
    response = web.post("/api/admin/models", json={"slug": "guarded", "display_name": "Guarded",
        "provider": "openai", "capability": "reference", "model_id": "synthetic", "apiKey": key,
        "parameters": {"rpm_limit": 1, **params}})
    return response.raise_for_status().json()["model"]["id"]


def simulate(web):
    return web.post("/api/admin/models/simulate-chain", json={"capability": "reference", "provider": "guarded"}).raise_for_status().json()


def execute(fetch):
    return asyncio.run(model_execution.execute_reference_chain("synthetic instructions", "synthetic input", fetch_fn=fetch))


@pytest.mark.parametrize(("source", "key"), [("registered", "synthetic-Snowman-☃"), ("registered", "synthetic\ninternal-control"),
                                            ("environment", "synthetic-environment-☃")])
def test_invalid_local_headers_never_debit_meter_or_reveal_the_key(web, monkeypatch, source, key):
    sign_in(web)
    set_limit(web, 1)
    if source == "registered":
        mid = registered(web, key=key)
    else:
        monkeypatch.setenv("OPENAI_API_KEY", key)
        monkeypatch.setenv("INTERVIEWCHECK_REFERENCE_MODEL", "synthetic")
    fetch = AsyncMock(side_effect=AssertionError("Invalid header reached the provider transport"))
    with pytest.raises(provider_allowance.InvalidHeaders) as refused:
        execute(fetch)
    assert refused.value.status_code == 503 and key not in str(refused.value.detail)
    if source == "registered":
        monkeypatch.setattr(provider_http, "fetch_json", fetch)
        result = web.post("/api/admin/models/playground/run", json={"model_ids": [mid], "system_prompt": "Example",
                                                                    "user_input": "Fixture"}).json()["results"][0]
        assert result["http_status"] == 503 and result["estimate_status"] == "not_called" and key not in result["error"]
        assert simulate(web)["active_chain"][0]["rpm_remaining"] == 1
        with store.connection() as db:
            assert db.execute("SELECT count(*) FROM model_usage_daily WHERE model_id=?", (mid,)).fetchone()[0] == 0
    fetch.assert_not_awaited()
    assert web.get(ROUTE).json()["used"] == 0
    assert web.get("/api/admin/usage/ai-costs").json()["totals"]["requests"] == 0


def circuit_state(mid, retry):
    with store.connection(write=True) as db:
        db.execute("""INSERT INTO model_circuit_state(model_id,state,next_retry_at,updated_at)
                      VALUES (?,'open',?,?) ON CONFLICT(model_id) DO UPDATE SET state='open',
                      next_retry_at=excluded.next_retry_at,half_open_probe_until=NULL""", (mid, retry, store.timestamp()))


def test_old_local_refusal_keeps_newly_claimed_probe_and_local_health(web, monkeypatch):
    sign_in(web)
    mid = registered(web)
    set_limit(web, 1)
    circuit_state(mid, "2000-01-01T00:00:00Z")
    claim = []
    original = model_execution._record_outcome
    def interleave(target, **kwargs):
        assert kwargs["provider_attempted"] is False
        with store.connection(write=True) as db:
            next_call = model_circuit.can_execute(db, mid)
            assert next_call.allowed and next_call.probe_until
            claim.append(next_call.probe_until)
        return original(target, **kwargs)
    monkeypatch.setattr(model_execution, "_record_outcome", interleave)
    with pytest.raises(HTTPException) as blocked:
        execute(AsyncMock(side_effect=ssrf_guard.SSRFValidationError("Synthetic local refusal")))
    assert blocked.value.status_code == 400 and web.get(ROUTE).json()["used"] == 0
    with store.connection() as db:
        row = db.execute("SELECT state,half_open_probe_until,failure_streak FROM model_circuit_state WHERE model_id=?", (mid,)).fetchone()
        assert tuple(row) == ("half_open", claim[0], 0)
        assert not model_circuit.can_execute(db, mid, claim=False).allowed
        assert db.execute("SELECT count(*) FROM model_health_checks WHERE model_id=? AND source='live' AND ok=0", (mid,)).fetchone()[0] == 1


def test_transient_last_slot_gives_bounded_retry_advice_and_can_reopen(web, monkeypatch):
    sign_in(web)
    registered(web)
    set_limit(web, 1)
    monkeypatch.setattr(provider_allowance, "utc_now", lambda: datetime(2034, 2, 1, tzinfo=timezone.utc))
    target = model_resolver.resolve_or_503("reference", provider="guarded")
    model_execution.QUOTA_LIMITER.consume(target.id, 1)
    async def compete():
        entered, allow = asyncio.Event(), asyncio.Event()
        async def wait():
            entered.set()
            await allow.wait()
        blocked_transport = AsyncMock()
        first = asyncio.create_task(provider_allowance.send(blocked_transport, admission_target=target, before_send=wait))
        await asyncio.wait_for(entered.wait(), 3)
        try:
            with pytest.raises(provider_allowance.AdmissionError) as denied:
                await provider_allowance.send(blocked_transport)
            assert 1 <= int(denied.value.headers["Retry-After"]) <= 60
        finally:
            allow.set()
        with pytest.raises(provider_allowance.TargetRefusal):
            await first
        blocked_transport.assert_not_awaited()
        assert await provider_allowance.send(AsyncMock(return_value="eligible")) == "eligible"
    asyncio.run(compete())
    assert web.get(ROUTE).json()["used"] == 1


def test_simulator_reports_actual_overlapping_limits_without_spending(web):
    sign_in(web)
    mid = registered(web, monthly_cost_limit_usd=1, input_cost_per_1m_usd=1000)
    set_limit(web, 0)
    model_execution.QUOTA_LIMITER.consume(mid, 1)
    fetch = AsyncMock(side_effect=AssertionError("A paused or exhausted model must not contact its provider"))
    def compare(expected, code, header=None):
        result = simulate(web)
        assert result["failure_reason"] == expected and not result["active_chain"]
        assert result["would_fail_429"] == (code == 429) and result["would_fail_503"] == (code == 503)
        with pytest.raises(HTTPException) as response:
            execute(fetch)
        assert response.value.status_code == code
        if header:
            assert response.value.headers["X-InterviewCheck-Limit"] == header
        assert web.get(ROUTE).json()["used"] == 0
    compare("workspace_allowance", 429, "ai-attempts")
    set_limit(web, None)
    compare("model_rpm", 429)
    set_limit(web, 0)
    circuit_state(mid, "2100-01-01T00:00:00Z")
    compare("circuit_open", 503)
    with store.connection(write=True) as db:
        model_budgets.record_usage(db, mid, input_tokens=2000, output_tokens=0, ok=True,
                                   config={"input_cost_per_1m_usd": 1000})
    compare("model_budget", 429, "model-budget")
    fetch.assert_not_awaited()
