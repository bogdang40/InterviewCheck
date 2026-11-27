"""Workspace attempt authorization persists before a provider sees synthetic text."""
import asyncio
import json
import threading
from datetime import datetime, timezone
from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from api import account_db, authoring, model_execution, provider_allowance, provider_http
from api import rate_limit, ssrf_guard, store
from api.main import app

ROUTE = "/api/admin/usage/ai-allowance"
SIGNUP = "/api/integrations/access/signup"
OWNER = "operator@allowance.test"


@pytest.fixture
def web(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "accounts.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("ADMIN_EMAILS", OWNER)
    monkeypatch.setenv("ADMIN_BOOTSTRAP_SECRET", "allowance-fixture-bootstrap")
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "allowance-fixture-key-32-characters")
    for key in ("INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_PUBLIC_ORIGIN",
                "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "AZURE_OPENAI_API_KEY", "DEEPGRAM_API_KEY"):
        monkeypatch.delenv(key, raising=False)
    rate_limit.reset_all()
    model_execution.reset_quotas()
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        yield client


def sign_in(client):
    client.post(SIGNUP, json={"email": OWNER, "password": "fixture-password-11",
                              "adminSecret": "allowance-fixture-bootstrap"}).raise_for_status()


def set_limit(client, limit):
    current = client.get(ROUTE).json()
    result = client.put(ROUTE, json={"monthly_limit": limit, "expected_revision": current["revision"]})
    result.raise_for_status()
    return result.json()


def test_admin_access_and_atomic_audited_edits(web):
    edit = {"monthly_limit": 2, "expected_revision": 1}
    assert web.get(ROUTE).status_code == 401
    assert web.put(ROUTE, json=edit).status_code == 401
    sign_in(web)
    initial = web.get(ROUTE).json()
    assert initial["monthly_limit"] is None and initial["remaining"] is None and initial["used"] == 0
    assert web.put(ROUTE, json=edit).json()["remaining"] == 2
    assert web.put(ROUTE, json=edit).status_code == 409
    same = web.put(ROUTE, json={**edit, "expected_revision": 2})
    assert same.json()["revision"] == 2
    for value in (-1, True, 1.5, 1000001, "100"):
        assert web.put(ROUTE, json={"monthly_limit": value, "expected_revision": 2}).status_code == 422
    assert web.put(ROUTE, json={"expected_revision": 2}).status_code == 422
    with account_db.connection() as db:
        rows = db.execute("SELECT target_user_id,actor_user_id,details FROM audit_log WHERE action='admin.usage.allowance'").fetchall()
        actor_id = db.execute("SELECT id FROM users WHERE email=?", (OWNER,)).fetchone()[0]
    assert len(rows) == 1 and rows[0]["target_user_id"] is None and rows[0]["actor_user_id"] == actor_id
    assert json.loads(rows[0]["details"]) == {"scope": "workspace", "previous_limit": None, "monthly_limit": 2, "revision": 2}
    web.cookies.clear()
    web.post(SIGNUP, json={"email": "member@allowance.test", "password": "fixture-password-12"}).raise_for_status()
    assert web.get(ROUTE).status_code == web.put(ROUTE, json=edit).status_code == 403


def test_racing_sends_share_one_limit_and_inflight_attempts_survive_changes(web):
    sign_in(web)
    set_limit(web, 3)

    async def race():
        entered = asyncio.Event()
        release = asyncio.Event()
        sends = 0

        async def transport():
            nonlocal sends
            sends += 1
            if sends == 3:
                entered.set()
            await release.wait()
            return "sent"

        tasks = [asyncio.create_task(provider_allowance.send(transport)) for _ in range(12)]
        try:
            await asyncio.wait_for(entered.wait(), timeout=5)
            assert web.get(ROUTE).json()["remaining"] == 0
            # Lower below the used count. Current calls retain their authorizations.
            assert set_limit(web, 1)["used"] == 3
        finally:
            release.set()
        results = await asyncio.gather(*tasks, return_exceptions=True)
        assert results.count("sent") == 3 and sends == 3
        denials = [r for r in results if isinstance(r, provider_allowance.AdmissionError)]
        assert len(denials) == 9 and all(r.status_code == 429 for r in denials)

    asyncio.run(race())
    store.initialize(store.db_path())
    assert web.get(ROUTE).json()["used"] == 3
    assert set_limit(web, 4)["remaining"] == 1
    asyncio.run(provider_allowance.send(AsyncMock(return_value="ok")))
    assert set_limit(web, None)["used"] == 4


def test_calendar_rollover_and_local_refusals_use_original_period(web, monkeypatch):
    sign_in(web)
    before = datetime(2028, 12, 31, 23, 59, 58, tzinfo=timezone.utc)
    after = datetime(2029, 1, 1, tzinfo=timezone.utc)
    monkeypatch.setattr(provider_allowance, "utc_now", lambda: before)
    set_limit(web, 1)

    async def blocked():
        monkeypatch.setattr(provider_allowance, "utc_now", lambda: after)
        await provider_allowance.send(AsyncMock(return_value="ok"))
        cause = ssrf_guard.SSRFValidationError("Fixture transport refused locally.")
        raise HTTPException(502, "No connection made.") from cause

    with pytest.raises(HTTPException):
        asyncio.run(provider_allowance.send(blocked))
    assert web.get(ROUTE).json()["next_reset_at"] == "2029-02-01T00:00:00Z"
    assert web.get(ROUTE).json()["used"] == 1
    with store.connection() as db:
        assert dict(db.execute("SELECT month, used FROM ai_attempt_months")) == {"2028-12": 0, "2029-01": 1}


def test_uncertain_delivery_and_disabled_limits_keep_tracking(web):
    sign_in(web)
    attempt = AsyncMock(side_effect=HTTPException(504, "Fixture provider timeout."))
    with pytest.raises(HTTPException):
        asyncio.run(provider_allowance.send(attempt))
    with pytest.raises(asyncio.CancelledError):
        asyncio.run(provider_allowance.send(AsyncMock(side_effect=asyncio.CancelledError())))
    initial = web.get(ROUTE).json()
    assert initial["used"] == 2 and initial["monthly_limit"] is None
    assert set_limit(web, 1)["remaining"] == 0
    with pytest.raises(provider_allowance.AdmissionError):
        asyncio.run(provider_allowance.send(attempt))
    assert attempt.await_count == 1


def test_environment_retry_fallback_and_playground_share_attempts(web, monkeypatch):
    sign_in(web)
    created = web.post("/api/admin/models", json={
        "slug": "allowance-primary", "display_name": "Primary", "provider": "openai", "capability": "reference",
        "model_id": "synthetic", "apiKey": "synthetic-key-2222", "is_default": True,
        "parameters": {"max_retries": 1},
    })
    created.raise_for_status()
    mid = created.json()["model"]["id"]
    set_limit(web, 2)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "fixture-anthropic-2222")
    monkeypatch.setenv("INTERVIEWCHECK_ANTHROPIC_MODEL", "fixture-fallback")
    attempts = AsyncMock(side_effect=HTTPException(503, "Synthetic provider unavailable."))

    async def run_reference():
        return await model_execution.execute_reference_chain("instructions", "input", fetch_fn=attempts)

    with pytest.raises(provider_allowance.AdmissionError) as denied:
        asyncio.run(run_reference())
    assert denied.value.status_code == 429
    assert [call.args[0] for call in attempts.await_args_list] == ["OpenAI", "OpenAI"]
    no_send = AsyncMock(side_effect=AssertionError("denied before provider dispatch"))
    monkeypatch.setattr(provider_http, "fetch_json", no_send)
    blocked = web.post("/api/admin/models/playground/run", json={
        "model_ids": [mid], "system_prompt": "Synthetic", "user_input": "Text",
    }).json()["results"][0]
    assert blocked["http_status"] == 429 and blocked["estimate_status"] == "not_called"
    no_send.assert_not_awaited()
    assert web.get("/api/admin/usage/ai-costs").json()["totals"]["requests"] == 2
    assert web.get(ROUTE).json()["used"] == 2

    set_limit(web, 4)
    success = AsyncMock(return_value={"choices": [{"finish_reason": "stop", "message": {"content": "Sample"}}]})
    monkeypatch.setattr(authoring, "fetch_json", success)
    web.post("/api/authoring/reference", json={"provider": "OpenAI", "style": "Spoken answer",
                                               "question": "Explain a decision.", "role": "Engineer"}).raise_for_status()
    monkeypatch.setattr(provider_http, "fetch_json", success)
    p = web.post("/api/admin/models/playground/run", json={"model_ids": [mid], "system_prompt": "One", "user_input": "Two"})
    assert p.json()["results"][0]["ok"] and web.get(ROUTE).json()["used"] == 4


def test_embeddings_share_limit_and_transcription_remains_available(web, monkeypatch):
    sign_in(web)
    set_limit(web, 1)
    monkeypatch.setenv("OPENAI_API_KEY", "fixture-openai-key")
    monkeypatch.setenv("INTERVIEWCHECK_EMBEDDING_MODEL", "synthetic-embedding")
    monkeypatch.setenv("DEEPGRAM_API_KEY", "fixture-deepgram-key")
    fetch = AsyncMock(return_value={"data": [{"index": 0, "embedding": [0.1]}]})
    build = lambda _target, texts: ("https://example.test/embeddings", {}, {"input": texts})
    asyncio.run(model_execution.execute_embedding_chain(["example"], request_builder=build, fetch_fn=fetch))
    assert web.get(ROUTE).json()["remaining"] == 0
    audio = AsyncMock(return_value={"results": {"utterances": [{"speaker": "A", "transcript": "example"}]}})
    asyncio.run(model_execution.execute_transcription_chain(b"fake", "audio/wav", url_builder=lambda _: ("unused", ""),
                                                          fetch_fn=audio))
    assert audio.await_count == 1 and web.get(ROUTE).json()["used"] == 1


def test_storage_loss_refuses_before_fetch(web):
    sign_in(web)
    with store.connection(write=True) as db:
        db.execute("DROP TABLE ai_attempt_months")
    fetch = AsyncMock()
    with pytest.raises(provider_allowance.AdmissionError) as denied:
        asyncio.run(provider_allowance.send(fetch))
    assert denied.value.status_code == 503
    fetch.assert_not_awaited()


def test_changed_saved_evidence_before_send_returns_slot_and_preserves_conflict(web):
    sign_in(web)
    set_limit(web, 1)
    denied = AsyncMock(side_effect=HTTPException(409, "Saved evidence changed.", headers={"X-Reason": "changed"}))
    transport = AsyncMock()
    with pytest.raises(provider_allowance.AdmissionError) as error:
        asyncio.run(provider_allowance.send(transport, before_send=denied))
    assert error.value.status_code == 409 and error.value.headers == {"X-Reason": "changed"}
    transport.assert_not_awaited()
    assert web.get(ROUTE).json()["used"] == 0


def test_priced_failure_at_monthly_threshold_stops_retry_before_another_attempt(web, monkeypatch):
    sign_in(web)
    web.post("/api/admin/models", json={
        "slug": "priced-retry", "display_name": "Priced retry", "provider": "openai",
        "capability": "reference", "model_id": "synthetic", "apiKey": "synthetic-key-2222",
        "parameters": {"max_retries": 2, "monthly_cost_limit_usd": 0.01,
                       "input_cost_per_1m_usd": 10, "output_cost_per_1m_usd": 0},
    }).raise_for_status()
    fetch = AsyncMock(return_value={"choices": [{"finish_reason": "length"}],
                                    "usage": {"prompt_tokens": 1000, "completion_tokens": 5}})
    monkeypatch.setattr(authoring, "fetch_json", fetch)
    response = web.post("/api/authoring/reference", json={"provider": "OpenAI", "style": "Spoken answer",
                                                          "question": "Explain a choice.", "role": "Engineer"})
    assert response.status_code == 429 and response.json()["detail"] == "Model budget ceiling reached."
    fetch.assert_awaited_once()
    assert web.get(ROUTE).json()["used"] == 1
    totals = web.get("/api/admin/usage/ai-costs").json()["totals"]
    assert totals["errors"] == 1 and totals["cost_usd"] == pytest.approx(0.01)


def test_paused_workspace_preserves_rpm_and_half_open_probe_until_resumed(web, monkeypatch):
    sign_in(web)
    model = web.post("/api/admin/models", json={
        "slug": "probe-slot", "display_name": "Probe", "provider": "openai", "capability": "reference",
        "model_id": "synthetic", "apiKey": "synthetic-key-1111", "parameters": {"rpm_limit": 1},
    }).json()["model"]
    mid = model["id"]
    with store.connection(write=True) as db:
        db.execute("""INSERT INTO model_circuit_state(model_id,state,next_retry_at,updated_at)
                      VALUES (?,'open','2000-01-01T00:00:00Z','2000-01-01T00:00:00Z')
                      ON CONFLICT(model_id) DO UPDATE SET state='open',next_retry_at=excluded.next_retry_at,
                      half_open_probe_until=NULL""", (mid,))
    set_limit(web, 0)
    fetch = AsyncMock(return_value={"status": "completed", "output": [
        {"type": "message", "content": [{"type": "output_text", "text": "Synthetic reply"}]}]})
    async def reference():
        return await model_execution.execute_reference_chain("Instructions", "Fixture", fetch_fn=fetch)
    with pytest.raises(provider_allowance.AdmissionError) as denied:
        asyncio.run(reference())
    assert denied.value.headers["X-InterviewCheck-Limit"] == "ai-attempts"
    monkeypatch.setattr(provider_http, "fetch_json", fetch)
    blocked = web.post("/api/admin/models/playground/run", json={
        "model_ids": [mid], "system_prompt": "Fixture", "user_input": "Fixture",
    }).json()["results"][0]
    assert blocked["http_status"] == 429 and blocked["estimate_status"] == "not_called"
    for _ in range(2):
        sim = web.post("/api/admin/models/simulate-chain", json={"capability": "reference", "provider": "probe-slot"}).json()
        assert sim["would_fail_429"] and not sim["would_fail_503"] and not sim["active_chain"]
        assert sim["skipped"][0]["skip_reason"] == "workspace_attempt_allowance_exhausted"
        assert sim["skipped"][0]["rpm_remaining"] == 1
    with store.connection() as db:
        assert tuple(db.execute("SELECT state,half_open_probe_until FROM model_circuit_state WHERE model_id=?",
                                (mid,)).fetchone()) == ("open", None)
    fetch.assert_not_awaited()
    assert set_limit(web, 1)["used"] == 0
    from api import model_resolver
    target = model_resolver.resolve_or_503("reference", provider="probe-slot")
    stale = AsyncMock(side_effect=HTTPException(409, "Synthetic evidence changed."))
    with pytest.raises(provider_allowance.AdmissionError) as expired:
        asyncio.run(provider_allowance.send(fetch, admission_target=target, use_circuit=True, before_send=stale))
    assert expired.value.status_code == 409 and web.get(ROUTE).json()["used"] == 0
    with store.connection() as db:
        assert tuple(db.execute("SELECT state,half_open_probe_until FROM model_circuit_state WHERE model_id=?",
                                (mid,)).fetchone()) == ("half_open", None)
    fetch.assert_not_awaited()
    assert asyncio.run(reference())[0].id == mid
    fetch.assert_awaited_once()
    with store.connection() as db:
        assert tuple(db.execute("SELECT state,half_open_probe_until FROM model_circuit_state WHERE model_id=?",
                                (mid,)).fetchone()) == ("closed", None)


def test_cancellation_while_sqlite_writer_holds_lock_sends_nothing(web, monkeypatch):
    sign_in(web)
    set_limit(web, 1)
    entered, finished = threading.Event(), threading.Event()
    real = provider_allowance._admit
    def observed(*args):
        entered.set()
        try:
            return real(*args)
        finally:
            finished.set()
    monkeypatch.setattr(provider_allowance, "_admit", observed)
    fetch = AsyncMock(return_value="synthetic")
    async def test_cancellation():
        with store.connection(write=True):
            task = asyncio.create_task(provider_allowance.send(fetch))
            assert await asyncio.to_thread(entered.wait, 2)
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await asyncio.wait_for(task, 1)
        assert await asyncio.to_thread(finished.wait, 3)
    asyncio.run(test_cancellation())
    fetch.assert_not_awaited()
    assert web.get(ROUTE).json()["used"] == 0
    assert asyncio.run(provider_allowance.send(fetch)) == "synthetic"


def test_transcription_simulation_ignores_workspace_allowance(web, monkeypatch):
    sign_in(web)
    set_limit(web, 0)
    monkeypatch.setenv("DEEPGRAM_API_KEY", "synthetic-audio-key")
    sim = web.post("/api/admin/models/simulate-chain", json={"capability": "transcription"}).json()
    assert sim["active_chain"] and not sim["would_fail_429"] and not sim["would_fail_503"]
    assert web.get(ROUTE).json()["used"] == 0
