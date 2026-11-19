"""Tier 2 opaque-box boundary and corner-case tests for F7 and F8 (Auth, CSRF, Headers, Rate Limits)."""
import hashlib
import hmac
import json
import time
from uuid import uuid4

import pytest

from e2e_suite.harness import login_user, signup_user

ADMIN_EMAILS = ("admin1@example.test", "admin2@example.test")
BOOTSTRAP_SECRET = "e2e-bootstrap-secret-1234"


def _assert_security_headers(headers, *, expect_hsts: bool = False):
    assert headers["x-content-type-options"] == "nosniff"
    assert headers["x-frame-options"] == "DENY"
    assert headers["referrer-policy"] == "no-referrer"
    assert "microphone=(self)" in headers["permissions-policy"]
    assert "display-capture=(self)" in headers["permissions-policy"]
    assert "camera=()" in headers["permissions-policy"]
    assert "content-security-policy" in {k.lower() for k in headers.keys()}
    if expect_hsts:
        assert "max-age=31536000" in headers["strict-transport-security"]
    else:
        assert "strict-transport-security" not in headers


@pytest.mark.tier2
def test_unauth_and_non_admin_rejected_across_all_admin_surfaces(e2e_workspace):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)
    target_uid = str(uuid4())
    cookie_routes = (
        ("GET", "/api/admin", None),
        ("GET", "/api/admin/unknown-route", None),
        ("GET", "/api/admin/models", None),
        ("POST", "/api/admin/models", {"display_name": "X"}),
        ("GET", "/api/integrations/admin", None),
        ("GET", "/api/integrations/admin/unknown", None),
        ("GET", "/api/integrations/admin/users", None),
        ("GET", "/api/integrations/admin/audit", None),
        ("PATCH", f"/api/integrations/admin/users/{target_uid}", {"role": "admin"}),
    )
    bearer_routes = (
        ("GET", "/v1/admin/stats", None),
        ("GET", "/v1/admin/users", None),
        ("GET", f"/v1/admin/users/{target_uid}", None),
        ("PATCH", f"/v1/admin/users/{target_uid}", {"role": "admin"}),
        ("GET", "/v1/admin/audit", None),
        ("GET", "/v1/admin/unknown", None),
    )

    with e2e_workspace.client() as anon:
        for method, path, body in cookie_routes:
            assert anon.request(method, path, json=body).status_code == 401, (method, path)
            forged = anon.request(
                method, path, json=body,
                headers={"Cookie": "ic_access=mm_forged_token_abcdefghijklmnopqrstuvwxyz123456"},
            )
            assert forged.status_code == 401, (method, path)
        for method, path, body in bearer_routes:
            assert anon.request(method, path, json=body).status_code == 401, (method, path)
            forged = anon.request(
                method, path, json=body,
                headers={"Authorization": "Bearer mm_forged_token_abcdefghijklmnopqrstuvwxyz123456"},
            )
            assert forged.status_code == 401, (method, path)

    with e2e_workspace.client() as member:
        signup_user(member, email="member@example.test")
        token = member.cookies["ic_access"]
        for method, path, body in cookie_routes:
            assert member.request(method, path, json=body).status_code == 403, (method, path)
        for method, path, body in bearer_routes:
            resp = member.request(method, path, json=body, headers={"Authorization": f"Bearer {token}"})
            assert resp.status_code == 403, (method, path)

    with e2e_workspace.client() as admin:
        signup_user(admin, email="admin1@example.test", admin_secret=BOOTSTRAP_SECRET)
        admin_tok = admin.cookies["ic_access"]
        assert admin.get("/api/admin/unknown-route").status_code == 404
        assert admin.get("/api/integrations/admin/unknown").status_code == 404
        assert admin.get("/v1/admin/unknown", headers={"Authorization": f"Bearer {admin_tok}"}).status_code == 404
        assert admin.get("/v1/admin/stats", headers={"Authorization": f"Bearer {admin_tok}"}).status_code == 200


@pytest.mark.tier2
def test_role_change_and_disable_revoke_sessions_and_protect_last_admin(e2e_workspace):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as admin, e2e_workspace.client() as member:
        signup_user(admin, email="admin1@example.test", admin_secret=BOOTSTRAP_SECRET)
        signup_user(member, email="member@example.test")
        users = admin.get("/api/integrations/admin/users").json()["users"]
        by_email = {u["user"]["email"]: u["user"]["id"] for u in users}
        admin_id = by_email["admin1@example.test"]
        member_id = by_email["member@example.test"]

        assert admin.patch(f"/api/integrations/admin/users/{admin_id}", json={"role": "user"}).status_code == 409
        assert admin.patch(f"/api/integrations/admin/users/{admin_id}", json={"disabled": True}).status_code == 409

        # Promoting member revokes member's existing session immediately.
        assert member.get("/api/integrations/account").status_code == 200
        promoted = admin.patch(f"/api/integrations/admin/users/{member_id}", json={"role": "admin"})
        assert promoted.status_code == 200 and promoted.json()["user"]["role"] == "admin"
        assert member.get("/api/integrations/account").status_code == 401
        assert member.get("/api/admin/models").status_code == 401

        # Re-login grants admin access; demoting revokes the new session too.
        assert login_user(member, email="member@example.test").get("admin") is True
        assert member.get("/api/admin/models").status_code == 200
        demoted = admin.patch(f"/api/integrations/admin/users/{member_id}", json={"role": "user"})
        assert demoted.status_code == 200 and demoted.json()["user"]["role"] == "user"
        assert member.get("/api/integrations/account").status_code == 401
        assert login_user(member, email="member@example.test").get("admin") is None
        assert member.get("/api/admin/models").status_code == 403

        # Disabling member revokes active session and blocks re-login with 403.
        assert admin.patch(f"/api/integrations/admin/users/{member_id}", json={"disabled": True}).status_code == 200
        assert member.get("/api/integrations/account").status_code == 401
        relogin = member.post(
            "/api/integrations/access/login",
            json={"email": "member@example.test", "password": "Synthetic-E2E-Pass-9876"},
        )
        assert relogin.status_code == 403


@pytest.mark.tier2
def test_password_length_boundaries_and_session_revocation_on_change(e2e_workspace):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)
    pass_10 = "A" * 10
    pass_200 = "B" * 200

    with e2e_workspace.client() as client_a, e2e_workspace.client() as client_b:
        assert client_a.post(
            "/api/integrations/access/password",
            json={"currentPassword": pass_10, "newPassword": "C" * 10},
        ).status_code == 401
        assert client_a.post(
            "/api/integrations/access/signup",
            json={"email": "pw@example.test", "password": "A" * 9},
        ).status_code == 422
        assert client_a.post(
            "/api/integrations/access/signup",
            json={"email": "pw@example.test", "password": "A" * 201},
        ).status_code == 422

        signup_user(client_a, email="pw@example.test", password=pass_10)
        login_user(client_b, email="pw@example.test", password=pass_10)
        assert client_b.get("/api/integrations/account").status_code == 200

        assert client_a.post(
            "/api/integrations/access/password",
            json={"currentPassword": pass_10, "newPassword": "C" * 9},
        ).status_code == 422
        assert client_a.post(
            "/api/integrations/access/password",
            json={"currentPassword": pass_10, "newPassword": "C" * 201},
        ).status_code == 422
        assert client_a.post(
            "/api/integrations/access/password",
            json={"currentPassword": "Wrong-Password-123", "newPassword": pass_200},
        ).status_code == 401

        changed = client_a.post(
            "/api/integrations/access/password",
            json={"currentPassword": pass_10, "newPassword": pass_200},
        )
        assert changed.status_code == 200
        assert client_a.get("/api/integrations/account").status_code == 200
        assert client_b.get("/api/integrations/account").status_code == 401
        assert client_b.post(
            "/api/integrations/access/login",
            json={"email": "pw@example.test", "password": pass_10},
        ).status_code == 401
        login_user(client_b, email="pw@example.test", password=pass_200)


@pytest.mark.tier2
@pytest.mark.filterwarnings("ignore::pytest.PytestUnhandledThreadExceptionWarning")
def test_production_mode_fail_closed_startup_and_workspace_gating(e2e_workspace, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_PRODUCTION", "1")
    with pytest.raises(RuntimeError):
        e2e_workspace.restart()

    e2e_workspace.configure_embedded_auth(
        admin_emails=ADMIN_EMAILS,
        bootstrap_secret=BOOTSTRAP_SECRET,
        signup_secret="prod-invite-secret-42",
        trial_days="0",
    )
    e2e_workspace.restart()

    with e2e_workspace.client() as anon:
        for path in ("/api/sessions", "/api/roles", "/api/backups/workspace", "/api/authoring/models"):
            assert anon.get(path).status_code == 401
        assert anon.post("/api/sessions", json={"candidate": "A", "role": "B", "policy": "P", "consent": True}).status_code == 401
        assert anon.post(
            "/api/integrations/access/signup",
            json={"email": "u@example.test", "password": "Synthetic-E2E-Pass-9876"},
        ).status_code == 403

    with e2e_workspace.client() as unentitled:
        res = signup_user(unentitled, email="u@example.test", invite_code="prod-invite-secret-42")
        assert res["active"] is False
        assert unentitled.get("/api/sessions").status_code == 402
        assert unentitled.get("/api/integrations/catalog").status_code == 402

    with e2e_workspace.client() as admin:
        admin_res = signup_user(
            admin,
            email="admin1@example.test",
            admin_secret=BOOTSTRAP_SECRET,
            invite_code="prod-invite-secret-42",
        )
        assert admin_res["admin"] is True and admin_res["active"] is True
        assert admin.get("/api/sessions").status_code == 200


@pytest.mark.tier2
def test_v1_csrf_webhook_exemption_origin_host_security_headers_and_hsts(e2e_workspace, monkeypatch):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)
    monkeypatch.setenv("STRIPE_WEBHOOK_SECRET", "whsec_tier2_test")
    e2e_workspace.restart()

    with e2e_workspace.client(headers={"X-InterviewCheck": ""}) as raw:
        raw.headers.pop("X-InterviewCheck", None)
        missing = raw.post("/v1/auth/login", json={"email": "a@example.test", "password": "Synthetic-E2E-Pass-9876"})
        assert missing.status_code == 403
        _assert_security_headers(missing.headers)

        wrong = raw.post(
            "/v1/auth/login",
            json={"email": "a@example.test", "password": "Synthetic-E2E-Pass-9876"},
            headers={"X-InterviewCheck": "0"},
        )
        assert wrong.status_code == 403

        cross_origin = raw.get("/api/health", headers={"Origin": "https://evil.example", "X-InterviewCheck": "1"})
        assert cross_origin.status_code == 403

        bad_host = raw.get("/api/health", headers={"Host": "evil.example", "X-InterviewCheck": "1"})
        assert bad_host.status_code == 400

        event_bytes = json.dumps({"id": "evt_t2_csrf", "type": "unused.event", "data": {"object": {}}}).encode()
        ts = int(time.time())
        sig = hmac.new(b"whsec_tier2_test", f"{ts}.".encode() + event_bytes, hashlib.sha256).hexdigest()
        webhook = raw.post(
            "/v1/billing/webhook",
            content=event_bytes,
            headers={"Content-Type": "application/json", "Stripe-Signature": f"t={ts},v1={sig}", "Origin": e2e_workspace.base_url},
        )
        assert webhook.status_code == 200

    with e2e_workspace.client() as client:
        health = client.get("/api/health")
        assert health.status_code == 200
        _assert_security_headers(health.headers, expect_hsts=False)
        assert health.headers["cache-control"] == "no-store"
        assert "default-src 'none'" in health.headers["content-security-policy"]

        ret = client.get("/v1/billing/return")
        assert ret.status_code == 200
        _assert_security_headers(ret.headers)
        assert "default-src 'none'" in ret.headers["content-security-policy"]

        unauth_me = client.get("/v1/me")
        assert unauth_me.status_code == 401
        _assert_security_headers(unauth_me.headers)

    monkeypatch.setenv("INTERVIEWCHECK_PUBLIC_ORIGIN", "https://review.example.test")
    e2e_workspace.restart()
    with e2e_workspace.client(headers={"X-Forwarded-Host": "review.example.test"}) as pub:
        pub_health = pub.get("/api/health")
        assert pub_health.status_code == 200
        _assert_security_headers(pub_health.headers, expect_hsts=True)


@pytest.mark.tier2
def test_rate_limits_admin_probe_and_ai_request_without_cross_test_leaks(e2e_workspace):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)
    missing_id = "00000000-0000-4000-8000-000000000000"
    with e2e_workspace.client() as client:
        signup_user(client, email="admin1@example.test", admin_secret=BOOTSTRAP_SECRET)

        for _ in range(15):
            assert client.post(f"/api/admin/models/{missing_id}/probe").status_code == 404
        probe_limited = client.post(f"/api/admin/models/{missing_id}/probe")
        assert probe_limited.status_code == 429
        assert int(probe_limited.headers["retry-after"]) >= 1

        for _ in range(20):
            resp = client.post(
                "/api/authoring/questions",
                json={"provider": "OpenAI", "role": "Staff", "description": "Backend systems"},
            )
            assert resp.status_code == 503
        ai_limited = client.post(
            "/api/authoring/questions",
            json={"provider": "OpenAI", "role": "Staff", "description": "Backend systems"},
        )
        assert ai_limited.status_code == 429
        assert int(ai_limited.headers["retry-after"]) >= 1
        assert client.post("/api/integrations/reference", json={"role": "Eng", "question": "Q?"}).status_code == 429
        assert client.post("/api/scoring/judge", json={"question": "Q?", "answer": "Ans"}).status_code == 429

    e2e_workspace.restart()
    with e2e_workspace.client() as fresh:
        login_user(fresh, email="admin1@example.test")
        assert fresh.post(f"/api/admin/models/{missing_id}/probe").status_code == 404
        assert fresh.post(
            "/api/authoring/questions",
            json={"provider": "OpenAI", "role": "Staff", "description": "Backend systems"},
        ).status_code == 503
