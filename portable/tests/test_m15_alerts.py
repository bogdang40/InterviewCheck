"""Tests for M15 model and budget webhook alert rules, SSRF, HMAC, and cooldowns."""
from datetime import datetime, timedelta, timezone
import hashlib, hmac, json
from unittest.mock import AsyncMock
from uuid import uuid4

from fastapi import FastAPI, HTTPException
from fastapi.exceptions import RequestValidationError
from fastapi.testclient import TestClient
import httpx
import pytest

from api import access, account_db, alert_rules, model_budgets, model_registry, model_telemetry, secret_box, ssrf_guard, store
from api import main as main_mod
from api.local_boundary import LocalBoundary
from api.security_headers import SecurityHeadersMiddleware


def _make_test_app() -> FastAPI:
    test_app = FastAPI(lifespan=main_mod.lifespan)
    test_app.add_exception_handler(RequestValidationError, main_mod.invalid_input)
    test_app.add_middleware(LocalBoundary)
    test_app.add_middleware(SecurityHeadersMiddleware)
    test_app.include_router(alert_rules.router)
    test_app.include_router(main_mod.model_admin.router)
    test_app.include_router(main_mod.workspace)
    return test_app


def _seed_user(*, email: str, role: str = "admin") -> str:
    uid, ts = str(uuid4()), account_db.now()
    with account_db.connection(write=True) as db:
        db.execute("INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,0,?,?)",
                   (uid, email, account_db.DECOY, role, ts, ts))
        return account_db.issue(db, uid, "pytest")


def _seed_model(*, slug: str, capability: str = "reference", enabled: bool = True, status: str = "connected", parameters: dict | None = None) -> dict:
    uid = str(uuid4())
    with store.connection(write=True) as db:
        m = model_registry.create_model(
            db, model_uuid=uid, slug=slug, display_name=f"M {slug}", provider="openai", capability=capability,
            model_id="gpt-4o", endpoint=None, api_version=None, parameters=parameters or {},
            encrypted_api_key=secret_box.encrypt_secret("sk-test-1234", aad=uid), key_hint="...1234",
            enabled=enabled, is_default=False,
        )
        if status != m["status"]:
            db.execute("UPDATE connected_models SET status=? WHERE id=?", (status, uid))
            m["status"] = status
        return m


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "fixture-m15-alerts-key")
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])
    monkeypatch.setattr(alert_rules, "dispatch_fn", alert_rules._default_dispatch)
    with TestClient(_make_test_app(), base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def _rule_payload(**overrides):
    base = {"name": "Ref Error Streak", "trigger_type": "model_error_streak", "threshold_value": 2,
            "capability_filter": "reference", "webhook_url": "https://hooks.example.com/alerts",
            "signing_secret": "whsec_super_secret_9876", "enabled": True, "cooldown_minutes": 15}
    base.update(overrides)
    return base


@pytest.mark.parametrize("mode", [None, "embedded", "remote"])
def test_alert_auth_and_csrf_gates(env, monkeypatch, mode):
    if mode == "embedded":
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    elif mode == "remote":
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://accounts.example.invalid")
        monkeypatch.setattr(access, "upstream", AsyncMock(side_effect=HTTPException(401, "Session expired.")))
    rid = str(uuid4())
    routes = [("GET", "/api/admin/alerts", None), ("POST", "/api/admin/alerts", _rule_payload()),
              ("PATCH", f"/api/admin/alerts/{rid}", {"enabled": False}), ("DELETE", f"/api/admin/alerts/{rid}", None),
              ("POST", "/api/admin/alerts/evaluate", None), ("POST", f"/api/admin/alerts/{rid}/test", None)]
    for method, path, body in routes:
        assert env.request(method, path, json=body).status_code == 401
        assert env.request(method, path, json=body, headers={"Cookie": f"{access.COOKIE}=mm_forged_123456789012345678901234567890"}).status_code == 401
    if mode == "remote":
        monkeypatch.setattr(access, "upstream", AsyncMock(return_value={"user": {"id": str(uuid4()), "email": "u@example.invalid", "role": "user", "disabled": False}, "entitlement": {"active": True}}))
        hdr = {"Cookie": f"{access.COOKIE}=remote-user"}
    else:
        hdr = {"Cookie": f"{access.COOKIE}={_seed_user(email='u@example.invalid', role='user')}"}
    for method, path, body in routes:
        assert env.request(method, path, json=body, headers=hdr).status_code == 403
    if mode != "remote":
        with TestClient(_make_test_app(), base_url="http://127.0.0.1") as raw:
            raw.cookies.set(access.COOKIE, _seed_user(email="adm@example.invalid", role="admin"))
            assert raw.post("/api/admin/alerts", json=_rule_payload()).status_code == 403


def test_ssrf_validation_secret_encryption_masking_and_crud(env):
    env.cookies.set(access.COOKIE, _seed_user(email="admin@example.invalid", role="admin"))
    with store.connection() as db:
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert {"alert_rules", "alert_deliveries"}.issubset(tables)

    for bad_url in ("http://hooks.example.com/a", "https://127.0.0.1/a", "https://localhost/a",
                    "https://169.254.169.254/latest/meta-data", "https://10.0.0.5/hook", "https://hooks.example.com:8443/a"):
        assert env.post("/api/admin/alerts", json=_rule_payload(webhook_url=bad_url)).status_code == 400
    for bad in (_rule_payload(extra="x"), _rule_payload(threshold_value=0), _rule_payload(threshold_value=1.5),
                _rule_payload(trigger_type="model_uptime_below", threshold_value=0), _rule_payload(signing_secret="   ")):
        assert env.post("/api/admin/alerts", json=bad).status_code == 422
    assert env.post("/api/admin/alerts", content=b'{"name":"NaN","trigger_type":"budget_pct_threshold","threshold_value":NaN,"webhook_url":"https://hooks.example.com/a"}', headers={"Content-Type": "application/json"}).status_code == 422
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM alert_rules").fetchone()[0] == 0

    sec1, sec2 = "whsec_super_secret_9876", "whsec_rotated_secret_4321"
    created = env.post("/api/admin/alerts", json=_rule_payload(signing_secret=sec1))
    assert created.status_code == 201 and sec1 not in created.text
    rule = created.json()["rule"]
    rid = rule["id"]
    assert rule["has_signing_secret"] is True and rule["secret_hint"] == "...9876" and "encrypted_signing_secret" not in rule

    with store.connection() as db:
        enc = db.execute("SELECT encrypted_signing_secret FROM alert_rules WHERE id=?", (rid,)).fetchone()[0]
    assert enc.startswith("v1:") and secret_box.decrypt_secret(enc, aad=rid) == sec1
    with pytest.raises(secret_box.SecretBoxError):
        secret_box.decrypt_secret(enc, aad="wrong-id")

    # Blank signing_secret preserves secret; invalid SSRF PATCH fails atomically; rotation and clear work
    assert env.patch(f"/api/admin/alerts/{rid}", json={"webhook_url": "https://127.0.0.1/evil"}).status_code == 400
    assert env.patch(f"/api/admin/alerts/{rid}", json={"name": "Renamed", "signing_secret": "   "}).json()["rule"]["secret_hint"] == "...9876"
    rotated = env.patch(f"/api/admin/alerts/{rid}", json={"signing_secret": sec2})
    assert rotated.status_code == 200 and rotated.json()["rule"]["secret_hint"] == "...4321" and sec2 not in rotated.text
    listed = env.get("/api/admin/alerts")
    assert listed.status_code == 200 and sec1 not in listed.text and sec2 not in listed.text
    assert listed.headers["x-content-type-options"] == "nosniff"

    backup = env.get("/api/backups/workspace")
    assert backup.status_code == 200 and sec2 not in backup.text and "alert_rules" not in backup.text

    cleared = env.patch(f"/api/admin/alerts/{rid}", json={"clear_signing_secret": True})
    assert cleared.status_code == 200 and cleared.json()["rule"]["has_signing_secret"] is False and cleared.json()["rule"]["secret_hint"] is None
    assert env.delete(f"/api/admin/alerts/{rid}").status_code == 200
    assert env.delete(f"/api/admin/alerts/{rid}").status_code == 404


def test_trigger_evaluation_hmac_cooldown_and_test_delivery(env, monkeypatch):
    env.cookies.set(access.COOKIE, _seed_user(email="admin@example.invalid", role="admin"))
    m_ref = _seed_model(slug="ref-1", capability="reference", parameters={"daily_token_limit": 1000, "monthly_cost_limit_usd": 10.0, "input_cost_per_1m_usd": 1000.0})
    m_judge = _seed_model(slug="judge-1", capability="judge", status="error")
    _seed_model(slug="disabled-ref", capability="reference", enabled=False, status="error")

    with store.connection(write=True) as db:
        # m_ref: 1 ok then 2 consecutive errors -> error_streak=2, uptime=33.3% (1/3)
        model_telemetry.record_check(db, m_ref["id"], source="live", ok=True, http_status=200, latency_ms=20, error=None, checked_at="2026-11-19T01:00:00Z")
        model_telemetry.record_check(db, m_ref["id"], source="live", ok=False, http_status=503, latency_ms=30, error="Upstream 503", checked_at="2026-11-19T02:00:00Z")
        model_telemetry.record_check(db, m_ref["id"], source="live", ok=False, http_status=503, latency_ms=35, error="Upstream 503", checked_at="2026-11-19T03:00:00Z")
        # m_judge: probe failed
        model_telemetry.record_check(db, m_judge["id"], source="probe", ok=False, http_status=401, latency_ms=10, error="Bad key", checked_at="2026-11-19T03:00:00Z")
        # m_ref budget: 850 tokens (85% daily_token_limit)
        model_budgets.record_usage(db, m_ref["id"], input_tokens=850, output_tokens=0, ok=True, config=m_ref["parameters"])

    sec = "whsec_hmac_signing_key_7777"
    r_streak = env.post("/api/admin/alerts", json=_rule_payload(name="Streak", trigger_type="model_error_streak", threshold_value=2, capability_filter="reference", signing_secret=sec, cooldown_minutes=15)).json()["rule"]
    r_uptime = env.post("/api/admin/alerts", json=_rule_payload(name="Uptime", trigger_type="model_uptime_below", threshold_value=50.0, capability_filter="reference", signing_secret=None)).json()["rule"]
    r_budget = env.post("/api/admin/alerts", json=_rule_payload(name="Budget", trigger_type="budget_pct_threshold", threshold_value=80.0, capability_filter=None, signing_secret=None)).json()["rule"]
    r_probe = env.post("/api/admin/alerts", json=_rule_payload(name="Probe", trigger_type="probe_failed", threshold_value=1, capability_filter="judge", signing_secret=None)).json()["rule"]
    r_off = env.post("/api/admin/alerts", json=_rule_payload(name="Disabled", trigger_type="probe_failed", threshold_value=1, enabled=False)).json()["rule"]

    captured: list[tuple[str, bytes, dict[str, str]]] = []

    async def fake_dispatch(url: str, body: bytes, headers: dict[str, str]):
        captured.append((url, body, dict(headers)))
        return True, 202, None

    monkeypatch.setattr(alert_rules, "dispatch_fn", fake_dispatch)

    ev1 = env.post("/api/admin/alerts/evaluate")
    assert ev1.status_code == 200
    data1 = ev1.json()
    assert data1["evaluated"] == 4 and data1["triggered"] == 4 and data1["skipped_cooldown"] == 0
    assert {d["rule_id"] for d in data1["deliveries"]} == {r_streak["id"], r_uptime["id"], r_budget["id"], r_probe["id"]}
    assert all(d["ok"] and d["http_status"] == 202 for d in data1["deliveries"])

    # Verify HMAC signature and capability_filter isolation on captured payload
    streak_call = next(c for c in captured if json.loads(c[1])["rule"]["id"] == r_streak["id"])
    expected_sig = "sha256=" + hmac.new(sec.encode("utf-8"), streak_call[1], hashlib.sha256).hexdigest()
    assert streak_call[2]["X-InterviewCheck-Signature"] == expected_sig
    assert streak_call[2]["X-InterviewCheck-Event"] == "alert.triggered"
    assert [m["model_id"] for m in json.loads(streak_call[1])["matches"]] == [m_ref["id"]]

    # Immediate re-evaluate enforces cooldown; /test bypasses cooldown and preserves last_triggered_at
    captured.clear()
    ev2 = env.post("/api/admin/alerts/evaluate")
    assert ev2.status_code == 200 and ev2.json()["triggered"] == 0 and ev2.json()["skipped_cooldown"] == 4 and captured == []

    with store.connection() as db:
        before_last = db.execute("SELECT last_triggered_at FROM alert_rules WHERE id=?", (r_streak["id"],)).fetchone()[0]
    tested = env.post(f"/api/admin/alerts/{r_streak['id']}/test")
    assert tested.status_code == 200 and tested.json()["ok"] is True and len(captured) == 1
    assert captured[0][2]["X-InterviewCheck-Event"] == "alert.test"
    assert captured[0][2]["X-InterviewCheck-Signature"] == "sha256=" + hmac.new(sec.encode("utf-8"), captured[0][1], hashlib.sha256).hexdigest()
    with store.connection() as db:
        after_last = db.execute("SELECT last_triggered_at FROM alert_rules WHERE id=?", (r_streak["id"],)).fetchone()[0]
    assert after_last == before_last

    # Disabled rule can still be manually tested; expired cooldown allows re-trigger; ok check breaks streak
    assert env.post(f"/api/admin/alerts/{r_off['id']}/test").status_code == 200
    old_ts = (datetime.now(timezone.utc) - timedelta(minutes=20)).isoformat()
    with store.connection(write=True) as db:
        db.execute("UPDATE alert_rules SET last_triggered_at=? WHERE id=?", (old_ts, r_streak["id"]))
    ev3 = env.post("/api/admin/alerts/evaluate")
    assert ev3.status_code == 200 and ev3.json()["triggered"] == 1 and ev3.json()["skipped_cooldown"] == 3

    with store.connection(write=True) as db:
        model_telemetry.record_check(db, m_ref["id"], source="live", ok=True, http_status=200, latency_ms=12, error=None, checked_at="2026-11-19T04:00:00Z")
        db.execute("UPDATE alert_rules SET last_triggered_at=? WHERE id=?", (old_ts, r_streak["id"]))
    ev4 = env.post("/api/admin/alerts/evaluate")
    assert ev4.status_code == 200 and ev4.json()["triggered"] == 0

    assert env.delete(f"/api/admin/alerts/{r_streak['id']}").status_code == 200
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM alert_deliveries WHERE rule_id=?", (r_streak["id"],)).fetchone()[0] == 0

    with account_db.connection() as adb:
        actions = [r["action"] for r in adb.execute("SELECT action FROM audit_log ORDER BY id ASC").fetchall()]
        raw_audit = json.dumps([dict(r) for r in adb.execute("SELECT * FROM audit_log").fetchall()])
    assert "admin.alert.create" in actions and "admin.alert.evaluate" in actions and "admin.alert.test" in actions and "admin.alert.delete" in actions
    assert sec not in raw_audit


def test_real_transport_blocks_redirects_and_dns_rebind_and_fallback_audit(env, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://accounts.example.invalid")
    monkeypatch.setattr(access, "upstream", AsyncMock(return_value={"user": {"email": "r@example.invalid", "role": "admin", "disabled": False}, "entitlement": {"active": True}}))
    env.cookies.set(access.COOKIE, "remote-admin")

    rid = env.post("/api/admin/alerts", json=_rule_payload(signing_secret="whsec_remote_9999")).json()["rule"]["id"]
    assert not account_db.database().exists()

    # Real httpx client blocks 302 redirects without following
    monkeypatch.setattr(httpx.AsyncClient, "send", AsyncMock(return_value=httpx.Response(302, headers={"Location": "https://127.0.0.1/"})))
    redir = env.post(f"/api/admin/alerts/{rid}/test")
    assert redir.status_code == 200 and redir.json()["ok"] is False and redir.json()["delivery"]["http_status"] == 302
    assert "Redirects are blocked" in redir.json()["delivery"]["error"]

    # DNS rebinding to private IP at delivery time is blocked by real dispatch SSRF check
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: (_ for _ in ()).throw(ssrf_guard.SSRFValidationError("Endpoint resolves to a restricted network address.")))
    rebind = env.post(f"/api/admin/alerts/{rid}/test")
    assert rebind.status_code == 200 and rebind.json()["ok"] is False and "restricted network address" in rebind.json()["delivery"]["error"]

    with store.connection() as db:
        audit_actions = [r["action"] for r in db.execute("SELECT action FROM model_audit ORDER BY id ASC").fetchall()]
    assert audit_actions == ["admin.alert.create", "admin.alert.test", "admin.alert.test"]

    # ADMIN_PROBE rate limit (15/min) enforced on evaluate/test
    for _ in range(13):
        assert env.post("/api/admin/alerts/evaluate").status_code == 200
    assert env.post("/api/admin/alerts/evaluate").status_code == 429
