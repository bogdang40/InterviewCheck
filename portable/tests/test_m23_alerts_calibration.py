"""Tests for M23-W2 alert delivery history/retry/export and calibration queue/export."""
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import json
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import access, account_db, alert_rules, role_analytics, ssrf_guard, store
from api.main import app


def _seed_user(*, email: str, role: str = "admin") -> str:
    uid, ts = str(uuid4()), account_db.now()
    with account_db.connection(write=True) as db:
        db.execute(
            "INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,0,?,?)",
            (uid, email, account_db.DECOY, role, ts, ts),
        )
        return account_db.issue(db, uid, "pytest")


def _rule_payload(**overrides):
    base = {
        "name": "Primary Webhook Rule",
        "trigger_type": "model_error_streak",
        "threshold_value": 2,
        "capability_filter": "reference",
        "webhook_url": "https://hooks.example.com/alerts",
        "signing_secret": "whsec_m23_secret_value_1234",
        "enabled": True,
        "cooldown_minutes": 15,
    }
    base.update(overrides)
    return base


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "fixture-m23-alerts-cal-key")
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])
    monkeypatch.setattr(alert_rules, "dispatch_fn", alert_rules._default_dispatch)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def _signup_embedded(client: TestClient, email: str) -> None:
    client.post("/api/integrations/access/signup", json={"email": email, "password": "strong-password-123"}).raise_for_status()


def _create_role(client: TestClient, name: str) -> dict:
    return client.post(
        "/api/roles",
        json={"name": name, "description": "Desc", "questions": ["Q1?"], "policy": "Closed book"},
    ).json()


def _create_session_and_answer(client: TestClient, *, role: dict, candidate: str, question: str) -> tuple[str, str]:
    sid = client.post(
        "/api/sessions",
        json={"candidate": candidate, "role": role["name"], "role_id": role["id"], "consent": True},
    ).json()["id"]
    aid = client.post(
        f"/api/sessions/{sid}/answers",
        json={"question": question, "answer": "Detailed engineering answer.", "references": []},
    ).json()["id"]
    return sid, aid


def test_alert_history_and_calibration_auth_csrf_gates(env, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("TRIAL_DAYS", "7")

    for method, path in (
        ("GET", "/api/admin/alerts/deliveries"),
        ("GET", "/api/admin/alerts/deliveries/export"),
        ("POST", "/api/admin/alerts/deliveries/1/retry"),
        ("GET", "/api/calibration/disagreements"),
        ("GET", "/api/calibration/export"),
    ):
        assert env.request(method, path).status_code == 401
        assert env.request(method, path, headers={"Cookie": f"{access.COOKIE}=forged-cookie-token"}).status_code == 401

    user_cookie = _seed_user(email="reviewer@example.invalid", role="user")
    user_hdr = {"Cookie": f"{access.COOKIE}={user_cookie}"}
    for method, path in (
        ("GET", "/api/admin/alerts/deliveries"),
        ("GET", "/api/admin/alerts/deliveries/export"),
        ("POST", "/api/admin/alerts/deliveries/1/retry"),
    ):
        assert env.request(method, path, headers=user_hdr).status_code == 403

    assert env.get("/api/calibration/disagreements", headers=user_hdr).status_code == 402
    assert env.get("/api/calibration/export", headers=user_hdr).status_code == 402

    _signup_embedded(env, "entitled@example.invalid")
    assert env.get("/api/calibration/disagreements").status_code == 200
    assert env.get("/api/calibration/export").status_code == 200
    assert env.get("/api/admin/alerts/deliveries").status_code == 403

    admin_cookie = _seed_user(email="admin@example.invalid", role="admin")
    with TestClient(app, base_url="http://127.0.0.1") as no_csrf:
        no_csrf.cookies.set(access.COOKIE, admin_cookie)
        assert no_csrf.post("/api/admin/alerts/deliveries/1/retry").status_code == 403


def test_alert_history_filtering_pagination_and_exports(env):
    env.cookies.set(access.COOKIE, _seed_user(email="admin@example.invalid", role="admin"))
    sec_a = "whsec_secret_alpha_5555"
    r1 = env.post("/api/admin/alerts", json=_rule_payload(name="=CMD|RuleA", signing_secret=sec_a)).json()["rule"]
    r2 = env.post("/api/admin/alerts", json=_rule_payload(name="RuleB", trigger_type="probe_failed", threshold_value=1, signing_secret=None)).json()["rule"]

    t0 = datetime(2026, 11, 19, 10, 0, 0, tzinfo=timezone.utc)
    with store.connection(write=True) as db:
        rows = [
            (r1["id"], "k1", 1, 200, None, t0.isoformat()),
            (r1["id"], "k2", 0, 502, "=1+1 bad gateway", (t0 + timedelta(minutes=10)).isoformat()),
            (r2["id"], "k3", 0, 500, "Timeout", (t0 + timedelta(minutes=20)).isoformat()),
            (r1["id"], "k4", 1, 202, None, (t0 + timedelta(minutes=30)).isoformat()),
        ]
        for row in rows:
            db.execute(
                "INSERT INTO alert_deliveries(rule_id,event_key,ok,http_status,error,delivered_at) VALUES (?,?,?,?,?,?)",
                row,
            )

    # Validation: naive timestamps and inverted window rejected with 422
    assert env.get("/api/admin/alerts/deliveries", params={"since": "2026-11-19T10:00:00"}).status_code == 422
    assert env.get(
        "/api/admin/alerts/deliveries",
        params={"since": (t0 + timedelta(minutes=30)).isoformat(), "until": t0.isoformat()},
    ).status_code == 422

    page1 = env.get("/api/admin/alerts/deliveries", params={"limit": 2})
    assert page1.status_code == 200
    assert page1.headers.get("cache-control") == "no-store"
    d1 = page1.json()
    assert d1["summary"] == {"total": 4, "ok_count": 2, "failed_count": 2, "success_rate_pct": 50.0, "failing_rules": 2}
    assert [item["event_key"] for item in d1["items"]] == ["k4", "k3"]
    assert d1["next_before_id"] == d1["items"][-1]["id"]
    assert sec_a not in page1.text and "encrypted_signing_secret" not in page1.text

    page2 = env.get("/api/admin/alerts/deliveries", params={"limit": 2, "before_id": d1["next_before_id"]})
    assert page2.status_code == 200
    d2 = page2.json()
    assert [item["event_key"] for item in d2["items"]] == ["k2", "k1"]
    assert d2["next_before_id"] is None

    filtered = env.get(
        "/api/admin/alerts/deliveries",
        params={
            "rule_id": r1["id"],
            "status": "failed",
            "since": (t0 + timedelta(minutes=5)).isoformat(),
            "until": (t0 + timedelta(minutes=25)).isoformat(),
        },
    ).json()
    assert filtered["summary"] == {"total": 1, "ok_count": 0, "failed_count": 1, "success_rate_pct": 0.0, "failing_rules": 1}
    assert [item["event_key"] for item in filtered["items"]] == ["k2"]
    assert filtered["items"][0]["rule_name"] == "=CMD|RuleA"

    csv_resp = env.get("/api/admin/alerts/deliveries/export", params={"format": "csv"})
    assert csv_resp.status_code == 200
    assert csv_resp.headers.get("cache-control") == "no-store"
    assert 'filename="alert-deliveries.csv"' in csv_resp.headers.get("content-disposition", "")
    assert csv_resp.text.startswith("\ufeff")
    assert "'=CMD|RuleA" in csv_resp.text and "'=1+1 bad gateway" in csv_resp.text
    assert sec_a not in csv_resp.text

    json_resp = env.get("/api/admin/alerts/deliveries/export", params={"format": "json", "status": "ok"})
    assert json_resp.status_code == 200
    assert json_resp.headers.get("cache-control") == "no-store"
    assert 'filename="alert-deliveries.json"' in json_resp.headers.get("content-disposition", "")
    jdata = json_resp.json()
    assert jdata["summary"]["ok_count"] == 2 and len(jdata["items"]) == 2
    assert sec_a not in json_resp.text


def test_alert_retry_ssrf_disabled_409_missing_404_and_audit(env, monkeypatch):
    env.cookies.set(access.COOKIE, _seed_user(email="admin@example.invalid", role="admin"))
    sec = "whsec_retry_hmac_secret_8888"
    rule = env.post("/api/admin/alerts", json=_rule_payload(name="Retry Rule", signing_secret=sec)).json()["rule"]
    off_rule = env.post("/api/admin/alerts", json=_rule_payload(name="Disabled Rule", enabled=False)).json()["rule"]

    with store.connection(write=True) as db:
        cur1 = db.execute(
            "INSERT INTO alert_deliveries(rule_id,event_key,ok,http_status,error,delivered_at) VALUES (?,?,?,?,?,?)",
            (rule["id"], "orig-fail", 0, 503, "Down", store.timestamp()),
        )
        deliv_ok_rule_id = cur1.lastrowid
        cur2 = db.execute(
            "INSERT INTO alert_deliveries(rule_id,event_key,ok,http_status,error,delivered_at) VALUES (?,?,?,?,?,?)",
            (off_rule["id"], "off-fail", 0, 500, "Down", store.timestamp()),
        )
        deliv_off_rule_id = cur2.lastrowid

    assert env.post("/api/admin/alerts/deliveries/0/retry").status_code == 422
    assert env.get("/api/admin/alerts/deliveries", params={"status": "bad"}).status_code == 422
    assert env.post("/api/admin/alerts/deliveries/999999/retry").status_code == 404
    assert env.post(f"/api/admin/alerts/deliveries/{deliv_off_rule_id}/retry").status_code == 409
    assert env.post("/api/admin/alerts/deliveries/99999999999999999999/retry").status_code == 422
    assert env.post("/api/admin/alerts/deliveries/9223372036854775807/retry").status_code == 404
    assert env.get("/api/admin/alerts/deliveries", params={"before_id": "99999999999999999999"}).status_code == 422
    assert env.get("/api/admin/alerts/deliveries", params={"before_id": "9223372036854775807"}).status_code == 200
    assert env.get("/api/admin/alerts/deliveries/export", params={"before_id": "99999999999999999999"}).status_code == 422
    assert env.get("/api/admin/alerts/deliveries/export", params={"before_id": "9223372036854775807"}).status_code == 200

    captured: list[tuple[str, bytes, dict[str, str]]] = []

    async def fake_dispatch(url: str, body: bytes, headers: dict[str, str]):
        captured.append((url, body, dict(headers)))
        return True, 202, None

    monkeypatch.setattr(alert_rules, "dispatch_fn", fake_dispatch)
    retried = env.post(f"/api/admin/alerts/deliveries/{deliv_ok_rule_id}/retry")
    assert retried.status_code == 200
    rdata = retried.json()
    assert rdata["ok"] is True
    assert rdata["delivery"]["rule_name"] == "Retry Rule"
    assert rdata["delivery"]["event_key"].startswith(f"retry:{deliv_ok_rule_id}:")
    assert sec not in retried.text
    assert len(captured) == 1
    assert captured[0][2]["X-InterviewCheck-Event"] == "alert.retry"
    expected_sig = "sha256=" + hmac.new(sec.encode("utf-8"), captured[0][1], hashlib.sha256).hexdigest()
    assert captured[0][2]["X-InterviewCheck-Signature"] == expected_sig

    # SSRF re-validation on retry using real transport blocks DNS rebinding to private IP
    monkeypatch.setattr(alert_rules, "dispatch_fn", alert_rules._default_dispatch)
    monkeypatch.setattr(
        ssrf_guard,
        "resolve_public_ips",
        lambda host, port=443: (_ for _ in ()).throw(ssrf_guard.SSRFValidationError("Endpoint resolves to a restricted network address.")),
    )
    ssrf_retry = env.post(f"/api/admin/alerts/deliveries/{deliv_ok_rule_id}/retry")
    assert ssrf_retry.status_code == 200
    assert ssrf_retry.json()["ok"] is False
    assert "restricted network address" in ssrf_retry.json()["delivery"]["error"]

    with account_db.connection() as adb:
        actions = [r["action"] for r in adb.execute("SELECT action FROM audit_log ORDER BY id ASC").fetchall()]
    assert actions.count("admin.alert.retry") == 2


def test_calibration_disagreements_anonymization_missing_tables_and_export(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "cal.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("TRIAL_DAYS", "7")
    for key in ("INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_PUBLIC_ORIGIN", "INTERVIEWCHECK_SIGNUP_SECRET"):
        monkeypatch.delenv(key, raising=False)

    hdr = {"X-InterviewCheck": "1"}
    with TestClient(app, base_url="http://127.0.0.1", headers=hdr) as alice, TestClient(
        app, base_url="http://127.0.0.1", headers=hdr
    ) as bob:
        _signup_embedded(alice, "alice@example.invalid")
        _signup_embedded(bob, "bob@example.invalid")

        r1 = _create_role(alice, "Backend Engineer")
        r2 = _create_role(alice, "Security Architect")

        s1, a1 = _create_session_and_answer(alice, role=r1, candidate="=HYPERLINK(\"https://bad\")", question="=Q1?")
        s2, a2 = _create_session_and_answer(alice, role=r1, candidate="Grace", question="Q2?")
        s3, a3 = _create_session_and_answer(alice, role=r2, candidate="Alan", question="Threat model?")
        s_anon, a_anon = _create_session_and_answer(alice, role=r1, candidate="Hidden", question="Redacted Q?")

        # Disagreement on a1 (alice=explained, bob=unresolved); consensus on a2; pending reset on a3; anonymized s_anon
        alice.patch(f"/api/sessions/{s1}/answers/{a1}", json={"disposition": "explained", "note": "ok"}).raise_for_status()
        bob.patch(f"/api/sessions/{s1}/answers/{a1}", json={"disposition": "unresolved", "note": "missed"}).raise_for_status()
        alice.patch(f"/api/sessions/{s2}/answers/{a2}", json={"disposition": "explained", "note": "ok"}).raise_for_status()
        bob.patch(f"/api/sessions/{s2}/answers/{a2}", json={"disposition": "explained", "note": "agree"}).raise_for_status()
        alice.patch(f"/api/sessions/{s3}/answers/{a3}", json={"disposition": "disclosed", "note": "c"}).raise_for_status()
        bob.patch(f"/api/sessions/{s3}/answers/{a3}", json={"disposition": "pending", "note": "recheck"}).raise_for_status()
        alice.patch(f"/api/sessions/{s_anon}/answers/{a_anon}", json={"disposition": "explained", "note": "a"}).raise_for_status()
        bob.patch(f"/api/sessions/{s_anon}/answers/{a_anon}", json={"disposition": "unresolved", "note": "b"}).raise_for_status()
        with store.connection(write=True) as db:
            db.execute(
                "INSERT INTO session_anonymizations(session_id, anonymized_at, anonymized_by) VALUES (?,?,?)",
                (s_anon, store.timestamp(), "admin@example.invalid"),
            )

        res_all = alice.get("/api/calibration/disagreements")
        assert res_all.status_code == 200
        body = res_all.json()
        assert body["summary"] == {"roles_with_disagreements": 1, "total_disagreed_answers": 1, "reviewer_count": 2}
        assert len(body["items"]) == 1
        item = body["items"][0]
        assert item["answer_id"] == a1 and item["role_id"] == r1["id"] and item["role_name"] == "Backend Engineer"
        assert item["current_disposition"] == "unresolved"
        assert [rev["reviewer_email"] for rev in item["reviewers"]] == ["alice@example.invalid", "bob@example.invalid"]

        assert alice.get("/api/calibration/disagreements", params={"role_id": r2["id"]}).json()["items"] == []

        csv_cal = alice.get("/api/calibration/export", params={"format": "csv", "role_id": r1["id"]})
        assert csv_cal.status_code == 200
        assert csv_cal.headers.get("cache-control") == "no-store"
        assert 'filename="calibration-queue.csv"' in csv_cal.headers.get("content-disposition", "")
        assert csv_cal.text.startswith("\ufeff")
        assert "reviewer_metric" in csv_cal.text and "disagreement" in csv_cal.text
        assert "'=HYPERLINK" in csv_cal.text and "'=Q1?" in csv_cal.text
        assert a_anon not in csv_cal.text

        json_cal = alice.get("/api/calibration/export", params={"format": "json"})
        assert json_cal.status_code == 200
        assert json_cal.headers.get("cache-control") == "no-store"
        assert 'filename="calibration-queue.json"' in json_cal.headers.get("content-disposition", "")
        jcal = json_cal.json()
        assert len(jcal["disagreements"]) == 1 and len(jcal["reviewer_metrics"]) >= 2

        # Defensive missing tables path
        with store.connection(write=True) as db:
            db.execute("DROP TABLE answer_review_events")
            db.execute("DROP TABLE session_anonymizations")
        empty_q = alice.get("/api/calibration/disagreements")
        assert empty_q.status_code == 200
        assert empty_q.json() == {"summary": {"roles_with_disagreements": 0, "total_disagreed_answers": 0, "reviewer_count": 0}, "items": []}
        assert alice.get("/api/calibration/export", params={"format": "json"}).status_code == 200


def test_alert_retry_returns_404_when_rule_deleted_in_flight(env, monkeypatch):
    env.cookies.set(access.COOKIE, _seed_user(email="admin@example.invalid", role="admin"))
    rule = env.post("/api/admin/alerts", json=_rule_payload(name="Race Rule")).json()["rule"]
    with store.connection(write=True) as db:
        deliv_id = db.execute(
            "INSERT INTO alert_deliveries(rule_id,event_key,ok,http_status,error,delivered_at) VALUES (?,?,?,?,?,?)",
            (rule["id"], "race-orig", 0, 502, "Gateway", store.timestamp()),
        ).lastrowid

    async def delete_rule_in_flight(url: str, body: bytes, headers: dict[str, str]):
        with store.connection(write=True) as db:
            db.execute("DELETE FROM alert_rules WHERE id=?", (rule["id"],))
        return True, 200, None

    monkeypatch.setattr(alert_rules, "dispatch_fn", delete_rule_in_flight)
    res = env.post(f"/api/admin/alerts/deliveries/{deliv_id}/retry")
    assert res.status_code == 404
    assert res.json()["detail"] == "Alert rule not found."
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM alert_deliveries").fetchone()[0] == 0
    with account_db.connection() as adb:
        assert adb.execute("SELECT count(*) FROM audit_log WHERE action='admin.alert.retry'").fetchone()[0] == 0


def test_calibration_consensus_resolves_for_2_and_3_reviewers(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "consensus.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("TRIAL_DAYS", "7")
    for key in ("INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_PUBLIC_ORIGIN", "INTERVIEWCHECK_SIGNUP_SECRET"):
        monkeypatch.delenv(key, raising=False)
    hdr = {"X-InterviewCheck": "1"}
    with (
        TestClient(app, base_url="http://127.0.0.1", headers=hdr) as alice,
        TestClient(app, base_url="http://127.0.0.1", headers=hdr) as bob,
        TestClient(app, base_url="http://127.0.0.1", headers=hdr) as carol,
    ):
        _signup_embedded(alice, "alice@example.invalid")
        _signup_embedded(bob, "bob@example.invalid")
        _signup_embedded(carol, "carol@example.invalid")
        role = _create_role(alice, "Consensus Role")
        s1, a1 = _create_session_and_answer(alice, role=role, candidate="C1", question="Q1?")
        s2, a2 = _create_session_and_answer(alice, role=role, candidate="C2", question="Q2?")
        s3, a3 = _create_session_and_answer(alice, role=role, candidate="C3", question="Q3?")

        # 2-reviewer deadlock with identical note on resolution
        alice.patch(f"/api/sessions/{s1}/answers/{a1}", json={"disposition": "explained", "note": "agree"}).raise_for_status()
        bob.patch(f"/api/sessions/{s1}/answers/{a1}", json={"disposition": "unresolved", "note": "agree"}).raise_for_status()
        assert alice.get("/api/calibration/disagreements").json()["summary"]["total_disagreed_answers"] == 1
        alice.patch(f"/api/sessions/{s1}/answers/{a1}", json={"disposition": "unresolved", "note": "agree"}).raise_for_status()
        q2 = alice.get("/api/calibration/disagreements").json()
        assert q2["summary"]["total_disagreed_answers"] == 0 and q2["items"] == []

        # 3-reviewer deadlock resolved to explained
        alice.patch(f"/api/sessions/{s2}/answers/{a2}", json={"disposition": "explained", "note": "a"}).raise_for_status()
        bob.patch(f"/api/sessions/{s2}/answers/{a2}", json={"disposition": "disclosed", "note": "b"}).raise_for_status()
        carol.patch(f"/api/sessions/{s2}/answers/{a2}", json={"disposition": "unresolved", "note": "c"}).raise_for_status()
        bob.patch(f"/api/sessions/{s2}/answers/{a2}", json={"disposition": "explained", "note": "agree-bob"}).raise_for_status()
        carol.patch(f"/api/sessions/{s2}/answers/{a2}", json={"disposition": "explained", "note": "agree-carol"}).raise_for_status()
        q3 = alice.get("/api/calibration/disagreements").json()
        assert q3["summary"]["total_disagreed_answers"] == 0 and q3["items"] == []

        # Immediate agreement with identical disposition and note still records Bob's review event
        alice.patch(f"/api/sessions/{s3}/answers/{a3}", json={"disposition": "explained", "note": "same"}).raise_for_status()
        bob.patch(f"/api/sessions/{s3}/answers/{a3}", json={"disposition": "explained", "note": "same"}).raise_for_status()
        summary = {r["reviewer_email"]: r for r in alice.get("/api/roles/analytics").json()["roles"][0]["reviewer_summary"]}
        assert summary["bob@example.invalid"]["total_reviews"] == 3
        assert summary["alice@example.invalid"]["total_reviews"] == 3
        assert summary["carol@example.invalid"]["total_reviews"] == 1

