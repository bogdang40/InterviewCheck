"""Tests for M14-W2 admin model playground, schema benchmarker, and security gates."""
import asyncio
import json
from unittest.mock import AsyncMock
from uuid import uuid4

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
import pytest

from api import (
    access, account_db, main, model_budgets, model_execution, model_playground,
    model_registry, model_resolver, model_telemetry, prompt_framing, provider_http,
    rate_limit, secret_box, ssrf_guard, store,
)
from api.local_boundary import LocalBoundary
from api.security_headers import SecurityHeadersMiddleware


def _build_app():
    if any(getattr(r, "path", "") == "/api/admin/models/playground/run" for r in main.app.routes):
        return main.app
    test_app = FastAPI(lifespan=main.lifespan)
    test_app.add_middleware(LocalBoundary)
    test_app.add_middleware(SecurityHeadersMiddleware, static_dir=None)
    for exc_type, handler in main.app.exception_handlers.items():
        test_app.add_exception_handler(exc_type, handler)
    test_app.include_router(model_playground.router)
    test_app.include_router(main.model_admin.router)
    return test_app


def _seed_user(*, email: str = "pg-admin@example.invalid", role: str = "admin") -> str:
    uid, ts = str(uuid4()), account_db.now()
    with account_db.connection(write=True) as db:
        db.execute(
            "INSERT INTO users(id, email, password_hash, role, disabled, created_at, updated_at) VALUES (?,?,?,?,0,?,?)",
            (uid, email, account_db.DECOY, role, ts, ts),
        )
        return account_db.issue(db, uid, "pytest")


def _register(
    *, slug: str, provider: str = "openai", capability: str = "reference", model_id: str = "gpt-4o",
    secret: str = "sk-m14-pg-secret-9999", endpoint: str | None = None, parameters: dict | None = None,
) -> dict:
    uid = str(uuid4())
    enc = secret_box.encrypt_secret(secret, aad=uid) if secret else None
    hint = secret_box.mask_key_hint(secret) if secret else None
    with store.connection(write=True) as db:
        return model_registry.create_model(
            db, model_uuid=uid, slug=slug, display_name=f"Model {slug}", provider=provider,
            capability=capability, model_id=model_id, endpoint=endpoint, api_version=None,
            parameters=parameters or {}, encrypted_api_key=enc, key_hint=hint, enabled=True, is_default=False,
        )


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "fixture-m14-pg-key")
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])
    model_execution.reset_quotas()
    rate_limit.reset_all()
    with TestClient(_build_app(), base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


@pytest.mark.parametrize("mode", [None, "embedded", "remote"])
def test_playground_auth_csrf_and_input_validation(env, monkeypatch, mode):
    m_ref = _register(slug="pg-val-ref", capability="reference")
    m_emb = _register(slug="pg-val-emb", capability="embedding", model_id="text-embedding-3-small")
    m_tx = _register(slug="pg-val-tx", provider="deepgram", capability="transcription", model_id="nova-2")
    payload = {"model_ids": [m_ref["id"]], "system_prompt": "Be concise.", "user_input": "Hello"}

    if mode == "embedded":
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    elif mode == "remote":
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://accounts.example.invalid")
        monkeypatch.setattr(access, "upstream", AsyncMock(side_effect=HTTPException(401, "Expired")))

    assert env.get("/api/admin/models/playground/presets").status_code == 401
    assert env.post("/api/admin/models/playground/run", json=payload).status_code == 401
    forged = {"Cookie": f"{access.COOKIE}=mm_forged_cookie_value_12345678901234567890"}
    assert env.get("/api/admin/models/playground/presets", headers=forged).status_code == 401
    assert env.post("/api/admin/models/playground/run", json=payload, headers=forged).status_code == 401

    if mode == "remote":
        monkeypatch.setattr(access, "upstream", AsyncMock(return_value={
            "user": {"id": str(uuid4()), "email": "u@example.invalid", "role": "user", "disabled": False},
            "entitlement": {"active": True},
        }))
        user_hdr = {"Cookie": f"{access.COOKIE}=remote-user"}
    else:
        user_hdr = {"Cookie": f"{access.COOKIE}={_seed_user(email='u@example.invalid', role='user')}"}
    assert env.get("/api/admin/models/playground/presets", headers=user_hdr).status_code == 403
    assert env.post("/api/admin/models/playground/run", json=payload, headers=user_hdr).status_code == 403

    if mode != "remote":
        admin_tok = _seed_user(email="a@example.invalid", role="admin")
        with TestClient(_build_app(), base_url="http://127.0.0.1") as raw:
            raw.cookies.set(access.COOKIE, admin_tok)
            assert raw.post("/api/admin/models/playground/run", json=payload).status_code == 403

        env.cookies.set(access.COOKIE, admin_tok)
        for bad_body in (
            {**payload, "model_ids": [m_emb["id"]]}, {**payload, "model_ids": [m_tx["id"]]},
            {**payload, "model_ids": [m_ref["id"], m_ref["id"]]}, {**payload, "model_ids": [m_ref["id"]] * 4},
            {**payload, "extra": 1}, {**payload, "expected_schema": "xml"},
            {**payload, "temperature": 2.5}, {**payload, "max_tokens": 0},
        ):
            assert env.post("/api/admin/models/playground/run", json=bad_body).status_code == 422
        assert env.post("/api/admin/models/playground/run", json={**payload, "model_ids": [str(uuid4())]}).status_code == 404


def test_presets_and_concurrent_multi_model_benchmark_telemetry_and_audit(env, monkeypatch):
    env.cookies.set(access.COOKIE, _seed_user())
    presets_res = env.get("/api/admin/models/playground/presets")
    assert presets_res.status_code == 200
    presets = {p["id"]: p for p in presets_res.json()["presets"]}
    assert set(presets) == {"authoring_questions", "ai_judge_rubric", "prompt_injection_probe"}
    assert presets["authoring_questions"]["expected_schema"] == "json_string_array"
    assert presets["ai_judge_rubric"]["expected_schema"] == "judge_verdict"

    s1, s2, s3 = "sk-secret-alpha-1111", "sk-secret-beta-2222", "sk-secret-gamma-3333"
    m1 = _register(slug="pg-oa", provider="openai", capability="reference", model_id="gpt-4o", secret=s1, parameters={"input_cost_per_1m_usd": 2.0, "output_cost_per_1m_usd": 8.0})
    m2 = _register(slug="pg-ant", provider="anthropic", capability="judge", model_id="claude-sonnet-4-6", secret=s2, parameters={"input_cost_per_1m_usd": 3.0, "output_cost_per_1m_usd": 15.0})
    m3 = _register(slug="pg-compat", provider="openai_compatible", capability="question_planning", model_id="qwen-2.5", secret=s3, endpoint="https://llm.example.com/v1")
    with store.connection() as db:
        enc1 = db.execute("SELECT encrypted_api_key FROM connected_models WHERE id=?", (m1["id"],)).fetchone()[0]

    in_flight = max_in_flight = 0
    captured_calls = []

    async def fake_fetch(name, method, url, **kwargs):
        nonlocal in_flight, max_in_flight
        in_flight += 1
        max_in_flight = max(max_in_flight, in_flight)
        await asyncio.sleep(0.02)
        in_flight -= 1
        captured_calls.append((name, url, kwargs["json"]))
        if name == "Anthropic":
            return {"stop_reason": "end_turn", "content": [{"type": "text", "text": f'["Q1?", "{s2}"]'}], "usage": {"input_tokens": 50, "output_tokens": 20}}
        echoed = s1 if name == "OpenAI" else s3
        return {"choices": [{"finish_reason": "stop", "message": {"content": f'["Q from {name} {echoed}"]'}}], "usage": {"prompt_tokens": 100, "completion_tokens": 40}}

    monkeypatch.setattr(provider_http, "fetch_json", fake_fetch)
    res = env.post("/api/admin/models/playground/run", json={
        "model_ids": [m1["id"], m2["id"], m3["id"]], "preset": "authoring_questions",
        "system_prompt": presets["authoring_questions"]["system_prompt"], "user_input": presets["authoring_questions"]["user_input"],
        "frame_as_untrusted": True, "expected_schema": "json_string_array", "max_tokens": 250, "temperature": 0.2,
    })
    assert res.status_code == 200
    body = res.json()
    assert max_in_flight == 3 and body["ok_count"] == 3 and len(body["results"]) == 3
    assert all(r["ok"] and r["schema_valid"] for r in body["results"])
    assert body["results"][0]["input_tokens"] == 100 and body["results"][0]["output_tokens"] == 40
    assert body["results"][0]["estimated_cost_usd"] == pytest.approx(0.00052)
    assert body["results"][1]["parsed_json"] == ["Q1?", "[redacted]"]
    assert s1 not in res.text and s2 not in res.text and s3 not in res.text and enc1 not in res.text
    assert all(call[2]["temperature"] == 0.2 for call in captured_calls)
    assert all(prompt_framing.BOUNDARY_CLAUSE in (call[2].get("system") or call[2]["messages"][0]["content"]) for call in captured_calls)

    with store.connection() as db:
        fleet, tel = model_budgets.fleet_usage_summary(db), model_telemetry.fleet_telemetry(db)
    assert fleet["models"][m1["id"]]["daily_tokens"] == 140
    assert tel["models"][m2["id"]]["ok_count"] == 1 and tel["models"][m2["id"]]["last_source"] == "live"

    with account_db.connection() as adb:
        audit = adb.execute("SELECT details FROM audit_log WHERE action='admin.model.playground'").fetchone()
    assert audit is not None and json.loads(audit["details"]) == {
        "model_ids": [m1["id"], m2["id"], m3["id"]], "preset": "authoring_questions",
        "expected_schema": "json_string_array", "ok_count": 3,
    }


def test_untrusted_framing_toggle_and_all_four_schema_modes(env, monkeypatch):
    env.cookies.set(access.COOKIE, _seed_user())
    m = _register(slug="pg-schema", capability="judge")
    seen_calls = []
    next_reply = {"text": "Freeform prose response."}

    async def fake_dispatch(target, instructions, prompt, **kwargs):
        seen_calls.append((instructions, prompt))
        return target.model_id, next_reply["text"]

    monkeypatch.setattr(model_resolver, "dispatch_completion", fake_dispatch)

    r_unframed = env.post("/api/admin/models/playground/run", json={
        "model_ids": [m["id"]], "system_prompt": "SYS_RAW", "user_input": "USR_RAW",
        "frame_as_untrusted": False, "expected_schema": "none",
    })
    assert r_unframed.status_code == 200 and r_unframed.json()["results"][0]["schema_valid"] is True
    assert seen_calls[-1] == ("SYS_RAW", "USR_RAW")

    r_framed = env.post("/api/admin/models/playground/run", json={
        "model_ids": [m["id"]], "system_prompt": "SYS_RAW", "user_input": "USR_RAW\x00",
        "frame_as_untrusted": True, "expected_schema": "json_object",
    })
    assert prompt_framing.BOUNDARY_CLAUSE in seen_calls[-1][0]
    assert seen_calls[-1][1] == '{"input": "USR_RAW"}'
    assert r_framed.json()["results"][0]["schema_valid"] is False

    cases = [
        ("json_object", '```json\n{"summary": "ok", "injection_detected": true}\n```', True),
        ("json_object", '["not", "an", "object"]', False),
        ("json_string_array", '["Q1", "Q2"]', True),
        ("json_string_array", "[]", False),
        ("json_string_array", '["valid", 123]', False),
        ("judge_verdict", '{"likelihood": 85, "confidence": "high", "evidence": ["e1"], "follow_up_questions": ["f1"]}', True),
        ("judge_verdict", '{"likelihood": 105, "confidence": "maybe", "evidence": "bad", "follow_up_questions": []}', False),
    ]
    for schema_mode, reply_text, expected_valid in cases:
        next_reply["text"] = reply_text
        resp = env.post("/api/admin/models/playground/run", json={
            "model_ids": [m["id"]], "system_prompt": "Sys", "user_input": "Usr", "expected_schema": schema_mode,
        })
        assert resp.status_code == 200
        item = resp.json()["results"][0]
        assert item["ok"] is True and item["schema_valid"] is expected_valid
        assert (len(item["schema_errors"]) == 0) is expected_valid


def test_ssrf_block_budget_quota_rate_limit_and_error_redaction(env, monkeypatch):
    env.cookies.set(access.COOKIE, _seed_user())
    m_ssrf = _register(
        slug="pg-ssrf", provider="openai_compatible", capability="reference",
        model_id="local", endpoint="https://compat.example.com/v1", secret="sk-ssrf-secret-1111",
    )
    with store.connection(write=True) as db:
        db.execute("UPDATE connected_models SET endpoint=? WHERE id=?", ("http://127.0.0.1/v1", m_ssrf["id"]))
    m_dns = _register(
        slug="pg-dns", provider="openai_compatible", capability="reference",
        model_id="dns", endpoint="https://rebind.example.com/v1", secret="sk-dns-secret-3333",
    )
    m_ok = _register(
        slug="pg-budget-rpm", provider="openai", capability="reference", model_id="gpt-4o",
        secret="sk-budget-secret-2222", parameters={"daily_token_limit": 100, "rpm_limit": 1},
    )

    # DNS resolution check when transport is unpatched
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda *a, **kw: (_ for _ in ()).throw(ssrf_guard.SSRFValidationError("Endpoint resolves to a restricted network address.")))
    r_dns = env.post("/api/admin/models/playground/run", json={"model_ids": [m_dns["id"]], "system_prompt": "S", "user_input": "U"})
    assert r_dns.status_code == 200 and r_dns.json()["results"][0]["http_status"] == 400

    called = 0

    async def fake_fetch(name, method, url, **kwargs):
        nonlocal called
        called += 1
        return {"choices": [{"finish_reason": "stop", "message": {"content": "ok"}}], "usage": {"prompt_tokens": 10, "completion_tokens": 5}}

    monkeypatch.setattr(provider_http, "fetch_json", fake_fetch)
    res = env.post("/api/admin/models/playground/run", json={"model_ids": [m_ssrf["id"], m_ok["id"]], "system_prompt": "S", "user_input": "U"})
    assert res.status_code == 200 and called == 1 and res.json()["ok_count"] == 1
    assert res.json()["results"][0]["http_status"] == 400 and res.json()["results"][1]["ok"] is True

    # 2nd call hits RPM quota (rpm_limit=1) with zero provider calls
    res_rpm = env.post("/api/admin/models/playground/run", json={"model_ids": [m_ok["id"]], "system_prompt": "S", "user_input": "U"})
    assert res_rpm.status_code == 200 and called == 1 and res_rpm.json()["results"][0]["http_status"] == 429

    # Reset quota, exceed daily token budget -> 429 budget block with zero provider calls
    model_execution.reset_quotas()
    with store.connection(write=True) as db:
        model_budgets.record_usage(db, m_ok["id"], input_tokens=100, output_tokens=0, ok=True, config=m_ok["parameters"])
    res_bud = env.post("/api/admin/models/playground/run", json={"model_ids": [m_ok["id"]], "system_prompt": "S", "user_input": "U"})
    assert res_bud.status_code == 200 and called == 1 and res_bud.json()["results"][0]["http_status"] == 429

    # Clear budget and verify secret leakage prevention on provider error + ADMIN_PROBE rate limit
    with store.connection(write=True) as db:
        db.execute("DELETE FROM model_usage_daily")
    monkeypatch.setattr(provider_http, "fetch_json", AsyncMock(side_effect=HTTPException(502, "Upstream failed with Bearer sk-budget-secret-2222 at /Users/admin/secret")))
    res_err = env.post("/api/admin/models/playground/run", json={"model_ids": [m_ok["id"]], "system_prompt": "S", "user_input": "U"})
    assert res_err.status_code == 200 and res_err.json()["results"][0]["http_status"] == 502
    assert "sk-budget-secret-2222" not in res_err.text and "/Users/admin" not in res_err.text

    for _ in range(15):
        r_rl = env.post("/api/admin/models/playground/run", json={"model_ids": [m_ok["id"]], "system_prompt": "S", "user_input": "U"})
        if r_rl.status_code == 429:
            break
    assert r_rl.status_code == 429


def test_deeply_nested_json_output_returns_schema_error_without_recursion_crash(env, monkeypatch):
    env.cookies.set(access.COOKIE, _seed_user())
    m = _register(slug="pg-deep-json", capability="reference")
    reply = {"text": ""}

    async def fake_fetch(name, method, url, **kwargs):
        return {"choices": [{"finish_reason": "stop", "message": {"content": reply["text"]}}], "usage": {"prompt_tokens": 5, "completion_tokens": 5}}

    monkeypatch.setattr(provider_http, "fetch_json", fake_fetch)

    for payload_text in (
        "[" * 1500 + "1" + "]" * 1500,
        "[" * 3000 + "1" + "]" * 3000,
        '{"a":' * 65 + "1" + "}" * 65,
    ):
        reply["text"] = payload_text
        res = env.post("/api/admin/models/playground/run", json={
            "model_ids": [m["id"]], "system_prompt": "S", "user_input": "U", "expected_schema": "json_object",
        })
        assert res.status_code == 200
        item = res.json()["results"][0]
        assert item["ok"] is True
        assert item["schema_valid"] is False
        assert item["parsed_json"] is None
        assert len(item["schema_errors"]) > 0


def test_non_sk_api_key_redacted_in_error_response_and_health_checks(env, monkeypatch):
    env.cookies.set(access.COOKIE, _seed_user())
    hex_secret = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"
    m = _register(
        slug="pg-azure-secret", provider="azure_openai", capability="reference",
        model_id="gpt-4o-deploy", endpoint="https://pg-azure.openai.azure.com", secret=hex_secret,
    )
    monkeypatch.setattr(
        provider_http, "fetch_json",
        AsyncMock(side_effect=HTTPException(502, f"Azure gateway rejected credential {hex_secret} for deployment")),
    )
    res = env.post("/api/admin/models/playground/run", json={"model_ids": [m["id"]], "system_prompt": "S", "user_input": "U"})
    assert res.status_code == 200
    item = res.json()["results"][0]
    assert item["ok"] is False
    assert item["http_status"] == 502
    assert hex_secret not in res.text
    assert "[redacted]" in item["error"]

    with store.connection() as db:
        check = db.execute(
            "SELECT error FROM model_health_checks WHERE model_id=? ORDER BY id DESC LIMIT 1",
            (m["id"],),
        ).fetchone()
        row = db.execute("SELECT last_error FROM connected_models WHERE id=?", (m["id"],)).fetchone()
    assert check is not None and check["error"] is not None
    assert hex_secret not in check["error"] and "[redacted]" in check["error"]
    assert row is not None and row["last_error"] is not None
    assert hex_secret not in row["last_error"]


def test_overflowing_json_float_output_rejected_without_500(env, monkeypatch):
    tok = _seed_user()
    env.cookies.set(access.COOKIE, tok)
    m1 = _register(slug="pg-inf-1", capability="reference", model_id="gpt-4o")
    m2 = _register(slug="pg-inf-2", capability="judge", model_id="gpt-4o-mini")
    replies = {"gpt-4o": '{"score": 1e400}', "gpt-4o-mini": '{"ok": true}'}

    async def fake_fetch(name, method, url, **kwargs):
        text = replies[kwargs["json"]["model"]]
        return {"choices": [{"finish_reason": "stop", "message": {"content": text}}], "usage": {"prompt_tokens": 5, "completion_tokens": 5}}

    monkeypatch.setattr(provider_http, "fetch_json", fake_fetch)

    verdict_base = '"likelihood": 80, "confidence": "high", "evidence": ["e"], "follow_up_questions": ["f"]'
    for schema_mode, literal in (
        ("json_object", "1e400"), ("json_object", "-1e400"),
        ("json_string_array", "1e400"), ("json_string_array", "-1e400"),
        ("judge_verdict", "1e400"), ("judge_verdict", "-1e400"),
    ):
        if schema_mode == "json_object":
            replies["gpt-4o"] = f'{{"score": {literal}}}'
        elif schema_mode == "json_string_array":
            replies["gpt-4o"] = f"[{literal}]"
        else:
            replies["gpt-4o"] = f'{{{verdict_base}, "x": {literal}}}'
        res = env.post("/api/admin/models/playground/run", json={
            "model_ids": [m1["id"]], "system_prompt": "S", "user_input": "U", "expected_schema": schema_mode,
        })
        assert res.status_code == 200
        item = res.json()["results"][0]
        assert item["ok"] is True and item["schema_valid"] is False and item["parsed_json"] is None
        assert len(item["schema_errors"]) > 0 and "Non-finite JSON float" in item["schema_errors"][0]

    replies["gpt-4o"] = '{"a": 1e400}'
    batch = env.post("/api/admin/models/playground/run", json={
        "model_ids": [m1["id"], m2["id"]], "system_prompt": "S", "user_input": "U", "expected_schema": "json_object",
    })
    assert batch.status_code == 200 and batch.json()["ok_count"] == 2
    r1, r2 = batch.json()["results"]
    assert r1["ok"] is True and r1["schema_valid"] is False and r1["parsed_json"] is None and len(r1["schema_errors"]) > 0
    assert r2["ok"] is True and r2["schema_valid"] is True and r2["parsed_json"] == {"ok": True} and r2["schema_errors"] == []

    with TestClient(_build_app(), base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}, raise_server_exceptions=False) as raw_client:
        raw_client.cookies.set(access.COOKIE, tok)
        probe = raw_client.post("/api/admin/models/playground/run", json={
            "model_ids": [m1["id"]], "system_prompt": "S", "user_input": "U", "expected_schema": "json_object",
        })
        assert probe.status_code == 200
        p_item = probe.json()["results"][0]
        assert p_item["ok"] is True and p_item["schema_valid"] is False and p_item["parsed_json"] is None
        assert len(p_item["schema_errors"]) > 0
