"""Tests for M24-W1: diagnostic bundle export, rubric templates, and role cloning."""
from datetime import datetime, timedelta, timezone
import json
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import (
    access, account_db, alert_rules, model_budgets, model_circuit,
    model_registry, model_telemetry, rate_limit, secret_box, store,
)
from api.main import app
from api.models import RubricCriterion


def _seed_user(*, email: str, role: str = "admin") -> str:
    uid, ts = str(uuid4()), account_db.now()
    with account_db.connection(write=True) as db:
        db.execute(
            "INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,0,?,?)",
            (uid, email, account_db.DECOY, role, ts, ts),
        )
        return account_db.issue(db, uid, "pytest")


def _signup_entitled(client: TestClient, email: str) -> None:
    client.post(
        "/api/integrations/access/signup",
        json={"email": email, "password": "strong-password-123"},
    ).raise_for_status()


@pytest.fixture
def env(tmp_path, monkeypatch):
    rate_limit.reset_all()
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "m24-super-secret-master-key")
    for key in (
        "INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL",
        "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_PUBLIC_ORIGIN",
    ):
        monkeypatch.delenv(key, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def test_diagnostics_bundle_auth_gates_and_headers(env, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("TRIAL_DAYS", "7")

    assert env.get("/api/admin/diagnostics/bundle").status_code == 401
    forged = {"Cookie": f"{access.COOKIE}=mm_forged_cookie_value_1234567890"}
    assert env.get("/api/admin/diagnostics/bundle", headers=forged).status_code == 401

    user_cookie = _seed_user(email="viewer@example.invalid", role="user")
    assert env.get("/api/admin/diagnostics/bundle", headers={"Cookie": f"{access.COOKIE}={user_cookie}"}).status_code == 403

    admin_cookie = _seed_user(email="admin@example.invalid", role="admin")
    resp = env.get("/api/admin/diagnostics/bundle", headers={"Cookie": f"{access.COOKIE}={admin_cookie}"})
    assert resp.status_code == 200
    assert resp.headers.get("cache-control") == "no-store"
    assert resp.headers.get("content-disposition") == 'attachment; filename="interviewcheck-diagnostics.json"'


def test_diagnostics_bundle_contents_audit_and_zero_secrets(env):
    env.cookies.set(access.COOKIE, _seed_user(email="admin@example.invalid", role="admin"))
    raw_api_key = "sk-m24-live-secret-99887766"
    raw_signing_secret = "whsec_m24_webhook_secret_443322"
    mid = str(uuid4())
    enc_key = secret_box.encrypt_secret(raw_api_key, aad=mid)
    now = datetime.now(timezone.utc)

    with store.connection(write=True) as db:
        model_registry.create_model(
            db, model_uuid=mid, slug="m24-primary", display_name="M24 Primary",
            provider="openai", capability="reference", model_id="gpt-4o",
            endpoint=None, api_version=None, parameters={"daily_token_limit": 50000},
            encrypted_api_key=enc_key, key_hint="...7766", enabled=True, is_default=True,
        )
        for idx in range(12):
            checked_at = (now - timedelta(minutes=12 - idx)).isoformat()
            ok = idx % 3 != 0
            err = None if ok else f"Upstream failed with Bearer {raw_api_key}"
            model_telemetry.record_check(
                db, mid, source="live", ok=ok, http_status=200 if ok else 502,
                latency_ms=100 + idx * 10, error=err, checked_at=checked_at,
            )
        model_budgets.record_usage(db, mid, input_tokens=120, output_tokens=80, ok=True, config={})
        model_circuit.record_outcome(db, mid, ok=False, error=f"secret={raw_api_key}")

        rid = str(uuid4())
        enc_sig = secret_box.encrypt_secret(raw_signing_secret, aad=rid)
        db.execute(
            "INSERT INTO alert_rules(id, name, trigger_type, threshold_value, capability_filter, webhook_url, "
            "encrypted_signing_secret, secret_hint, enabled, cooldown_minutes, created_at, updated_at) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (rid, "Latency Alert", "model_error_streak", 2, "reference", "https://hooks.example.com/a",
             enc_sig, "...3322", 1, 15, now.isoformat(), now.isoformat()),
        )
        alert_rules._record_delivery(db, rid, "evt:recent:ok", True, 200, None, (now - timedelta(hours=1)).isoformat())
        alert_rules._record_delivery(db, rid, "evt:recent:fail", False, 500, "Timeout", (now - timedelta(hours=2)).isoformat())
        alert_rules._record_delivery(db, rid, "evt:old:ok", True, 200, None, (now - timedelta(hours=30)).isoformat())

        for rank in range(12):
            directive = f"directive-{rank:02d}"
            for _ in range(12 - rank):
                db.execute(
                    "INSERT INTO csp_violations(received_at, document_uri, violated_directive, effective_directive, "
                    "blocked_uri, source_file, disposition) VALUES (?,?,?,?,?,?,?)",
                    (now.isoformat(), "https://app.example.com/", directive, directive, "https://evil.invalid", "", "enforce"),
                )

    resp = env.get("/api/admin/diagnostics/bundle")
    assert resp.status_code == 200
    raw_text = resp.text
    for forbidden in (
        raw_api_key, raw_signing_secret, "m24-super-secret-master-key",
        "encrypted_api_key", "encrypted_signing_secret", "token_hash", "totp_secret", "password_hash",
    ):
        assert forbidden not in raw_text

    body = json.loads(raw_text)
    assert body["probes"]["checks"]["review_db"] == "ok"
    assert len(body["models"]) == 1
    m_entry = body["models"][0]
    assert m_entry["slug"] == "m24-primary"
    assert m_entry["circuit"]["failure_streak"] == 1
    assert m_entry["usage"]["daily_input_tokens"] == 120
    assert m_entry["usage"]["daily_output_tokens"] == 80
    assert len(m_entry["recent_checks"]) == 10
    assert body["prompt_templates"]["total_slots"] == 5
    assert body["prompt_templates"]["slots"]["judge_rubric"]["active_version"] == 1
    assert body["prompt_templates"]["slots"]["judge_rubric"]["version_count"] >= 1
    assert body["alerts"] == {
        "rule_count": 1, "enabled_rule_count": 1,
        "deliveries_24h_total": 2, "deliveries_24h_ok": 1, "deliveries_24h_failed": 1,
    }
    assert body["csp_summary"]["total"] == 78
    assert len(body["csp_summary"]["top_directives"]) == 10
    assert body["csp_summary"]["top_directives"][0] == {"directive": "directive-00", "count": 12}

    with account_db.connection() as adb:
        audit = adb.execute(
            "SELECT action, target_user_id FROM audit_log WHERE action='admin.diagnostics.bundle_export'"
        ).fetchall()
    assert len(audit) == 1
    assert audit[0]["target_user_id"] == "diagnostics"


def test_diagnostics_bundle_defensive_when_optional_tables_missing(env):
    env.cookies.set(access.COOKIE, _seed_user(email="admin@example.invalid", role="admin"))
    with store.connection(write=True) as db:
        for table in (
            "model_circuit_state", "model_health_checks", "model_usage_daily",
            "prompt_template_versions", "prompt_templates",
            "alert_deliveries", "alert_rules", "csp_violations",
        ):
            db.execute(f"DROP TABLE IF EXISTS {table}")

    resp = env.get("/api/admin/diagnostics/bundle")
    assert resp.status_code == 200
    body = resp.json()
    assert body["models"] == []
    assert body["prompt_templates"] == {"table_present": False, "total_slots": 0, "slots": {}}
    assert body["alerts"]["rule_count"] == 0 and body["alerts"]["deliveries_24h_total"] == 0
    assert body["csp_summary"] == {"table_present": False, "total": 0, "top_directives": []}


def test_rubric_templates_listing_weights_and_auth(env, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("TRIAL_DAYS", "7")

    assert env.get("/api/roles/rubric-templates").status_code == 401
    unentitled = _seed_user(email="noplan@example.invalid", role="user")
    assert env.get("/api/roles/rubric-templates", headers={"Cookie": f"{access.COOKIE}={unentitled}"}).status_code == 402

    _signup_entitled(env, "entitled@example.invalid")
    resp = env.get("/api/roles/rubric-templates")
    assert resp.status_code == 200
    templates = resp.json()["templates"]
    assert {t["id"] for t in templates} == {
        "backend-systems", "frontend-accessibility", "security-threat-modeling",
        "production-reliability", "technical-leadership",
    }
    for tpl in templates:
        assert tpl["title"] and tpl["category"] and tpl["summary"] and tpl["default_policy"]
        assert len(tpl["suggested_questions"]) >= 3
        assert sum(item["weight"] for item in tpl["rubric"]) == 100
        for crit in tpl["rubric"]:
            RubricCriterion.model_validate(crit)
            assert len(crit["expected_signals"]) >= 1 and len(crit["red_flags"]) >= 1

    first = templates[0]
    created = env.post("/api/roles", json={
        "name": first["title"], "description": first["summary"],
        "questions": first["suggested_questions"], "policy": first["default_policy"],
        "rubric": first["rubric"],
    })
    assert created.status_code == 201


def test_role_clone_unique_naming_version_snapshot_and_errors(env, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("TRIAL_DAYS", "7")
    assert env.post(f"/api/roles/{uuid4()}/clone").status_code == 401

    _signup_entitled(env, "owner@example.invalid")
    assert env.post(f"/api/roles/{uuid4()}/clone").status_code == 404

    source_payload = {
        "name": "Principal Security Engineer",
        "description": "Threat modeling and auth review",
        "questions": ["How do you mitigate SSRF?"],
        "policy": "Closed book.",
        "permitted_sources": [{"label": "Threat brief", "text": "Allowed boundary notes."}],
        "rubric": [{
            "id": "sec-1", "criterion": "Boundary analysis", "weight": 100,
            "expected_signals": ["Checks DNS resolution"], "red_flags": ["Skips private IP checks"],
        }],
        "change_note": "Initial v1",
    }
    source = env.post("/api/roles", json=source_payload).json()
    env.put(f"/api/roles/{source['id']}", json={
        **source_payload, "version": source["version"], "version_number": 1,
        "description": "Updated description v2", "change_note": "Refined scope",
    }).raise_for_status()

    c1 = env.post(f"/api/roles/{source['id']}/clone")
    assert c1.status_code == 201
    b1 = c1.json()
    assert b1["id"] != source["id"]
    assert b1["name"] == "Principal Security Engineer (Copy)"
    assert b1["version_number"] == 1
    assert b1["description"] == "Updated description v2"
    assert b1["questions"] == source_payload["questions"]
    assert b1["policy"] == source_payload["policy"]
    assert b1["permitted_sources"] == source_payload["permitted_sources"]
    assert b1["rubric"] == source_payload["rubric"]

    versions = env.get(f"/api/roles/{b1['id']}/versions").json()["versions"]
    assert len(versions) == 1 and versions[0]["version_number"] == 1
    assert versions[0]["change_note"] == "Cloned from Principal Security Engineer"

    c2 = env.post(f"/api/roles/{source['id']}/clone", json={})
    assert c2.status_code == 201 and c2.json()["name"] == "Principal Security Engineer (Copy 2)"

    c3 = env.post(f"/api/roles/{source['id']}/clone", json={"name": "Custom Fork", "change_note": "Team B fork"})
    assert c3.status_code == 201 and c3.json()["name"] == "Custom Fork"
    assert env.get(f"/api/roles/{c3.json()['id']}/versions").json()["versions"][0]["change_note"] == "Team B fork"
    assert env.post(f"/api/roles/{source['id']}/clone", json={"name": "   "}).status_code == 422
