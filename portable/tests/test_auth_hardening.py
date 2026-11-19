"""Tests for M2 F7: multi-admin auth, production mode, fail-closed admin gates, and password rotation."""
from unittest.mock import AsyncMock
from uuid import uuid4

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest
from starlette.websockets import WebSocketDisconnect

from api import access, account_db
from api.account_server import app as standalone
from api.main import app


@pytest.fixture
def clean_env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("TRIAL_DAYS", "2")
    for key in (
        "INTERVIEWCHECK_ACCESS_MODE",
        "INTERVIEWCHECK_ACCESS_URL",
        "INTERVIEWCHECK_OPERATOR_EMAIL",
        "INTERVIEWCHECK_OPERATOR_ID",
        "INTERVIEWCHECK_PUBLIC_ORIGIN",
        "INTERVIEWCHECK_PRODUCTION",
        "INTERVIEWCHECK_SIGNUP_SECRET",
        "ADMIN_EMAILS",
        "ADMIN_BOOTSTRAP_SECRET",
    ):
        monkeypatch.delenv(key, raising=False)
    return tmp_path


@pytest.mark.parametrize("mode", [None, "embedded", "remote"])
def test_all_admin_routes_fail_closed_across_modes(clean_env, monkeypatch, mode):
    if mode == "embedded":
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    elif mode == "remote":
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://accounts.example.invalid")
        monkeypatch.setattr(access, "upstream", AsyncMock(side_effect=HTTPException(401, "Session expired.")))

    uid = str(uuid4())
    admin_paths = [
        ("GET", "/api/admin/models", None),
        ("GET", "/api/admin/unknown", None),
        ("GET", "/api/integrations/admin/users", None),
        ("GET", "/api/integrations/admin/audit", None),
        ("PATCH", f"/api/integrations/admin/users/{uid}", {"role": "admin"}),
        ("GET", "/api/integrations/admin/unknown", None),
    ]
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        for method, path, body in admin_paths:
            assert client.request(method, path, json=body).status_code == 401
            forged = {access.COOKIE: "mm_forged_token_value_12345678901234567890"}
            assert client.request(method, path, json=body, cookies=forged).status_code == 401

        if mode == "remote":
            monkeypatch.setattr(
                access,
                "upstream",
                AsyncMock(return_value={"user": {"id": uid, "email": "member@example.invalid", "role": "user", "disabled": False}, "entitlement": {"active": True}}),
            )
            cookies = {access.COOKIE: "remote-member-token"}
        else:
            with account_db.connection(write=True) as db:
                ts = account_db.now()
                db.execute(
                    "INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,0,?,?)",
                    (uid, "member@example.invalid", account_db.DECOY, "user", ts, ts),
                )
                tok = account_db.issue(db, uid, "pytest")
            cookies = {access.COOKIE: tok}

        for method, path, body in admin_paths:
            assert client.request(method, path, json=body, cookies=cookies).status_code == 403

        if mode == "remote":
            monkeypatch.setattr(
                access,
                "upstream",
                AsyncMock(return_value={"user": {"id": uid, "email": "admin@example.invalid", "role": "admin", "disabled": True}, "entitlement": {"active": True}}),
            )
            for method, path, body in admin_paths:
                assert client.request(method, path, json=body, cookies=cookies).status_code == 401

        if mode != "embedded":
            assert client.get("/v1/admin/stats").status_code == 404
            assert client.get("/v1/admin/users").status_code == 404
        else:
            assert client.get("/v1/admin/stats").status_code == 401
            assert client.get("/v1/admin/unknown").status_code == 401
            assert client.get("/v1/admin/stats", headers={"Authorization": f"Bearer {cookies[access.COOKIE]}"}).status_code == 403


def test_production_mode_requires_auth_and_blocks_open_signup(clean_env, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_PRODUCTION", "1")
    with pytest.raises(ValueError, match="Production mode"):
        with TestClient(app, base_url="http://127.0.0.1"):
            pass

    monkeypatch.setattr("api.main.validate_runtime_exposure", lambda: None)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        for method, path, body in (
            ("GET", "/api/sessions", None),
            ("GET", "/api/roles", None),
            ("GET", "/api/authoring/models", None),
            ("POST", "/api/scoring/semantic", {"answer": "x", "references": [{"label": "r", "text": "t"}]}),
            ("GET", "/api/integrations/catalog", None),
        ):
            assert client.request(method, path, json=body).status_code == 503
        with pytest.raises(WebSocketDisconnect):
            with client.websocket_connect("ws://127.0.0.1/api/integrations/live", headers={"Origin": "http://127.0.0.1"}):
                pass

    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        assert client.get("/api/integrations/status").json()["inviteRequired"] is True
        assert client.post("/api/integrations/access/signup", json={"email": "u@example.invalid", "password": "strong-password-1"}).status_code == 403
        assert client.get("/api/sessions").status_code == 401


def test_multi_admin_promotion_demotion_revokes_sessions_without_operator_email(clean_env, monkeypatch):
    public = "https://review.example.test"
    monkeypatch.setenv("INTERVIEWCHECK_PUBLIC_ORIGIN", public)
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("INTERVIEWCHECK_SIGNUP_SECRET", "invite-secret")
    monkeypatch.setenv("ADMIN_EMAILS", "admin1@example.invalid")
    monkeypatch.setenv("ADMIN_BOOTSTRAP_SECRET", "bootstrap-secret")
    headers = {"Origin": public, "X-Forwarded-Host": "review.example.test", "X-InterviewCheck": "1"}

    with TestClient(app, base_url="https://127.0.0.1", headers=headers) as admin1_client:
        s1 = admin1_client.post(
            "/api/integrations/access/signup",
            json={"email": "admin1@example.invalid", "password": "admin-password-1", "inviteCode": "invite-secret", "adminSecret": "bootstrap-secret"},
        )
        assert s1.status_code == 200 and s1.json()["admin"] is True

        with TestClient(app, base_url="https://127.0.0.1", headers=headers) as member_client:
            s2 = member_client.post(
                "/api/integrations/access/signup",
                json={"email": "member@example.invalid", "password": "member-password-1", "inviteCode": "invite-secret"},
            )
            assert s2.status_code == 200 and "admin" not in s2.json()
            member_old_token = member_client.cookies[access.COOKIE]
            member_id = member_client.get("/v1/me", headers={"Authorization": f"Bearer {member_old_token}"}).json()["user"]["id"]

            # Promote member -> old member session is immediately revoked (401)
            assert admin1_client.patch(f"/api/integrations/admin/users/{member_id}", json={"role": "admin"}).status_code == 200
            assert member_client.get("/api/integrations/account").status_code == 401
            assert member_client.get("/v1/me", headers={"Authorization": f"Bearer {member_old_token}"}).status_code == 401

            # Re-login as newly promoted Admin 2
            l2 = member_client.post("/api/integrations/access/login", json={"email": "member@example.invalid", "password": "member-password-1"})
            assert l2.status_code == 200 and l2.json()["admin"] is True
            assert member_client.get("/api/admin/models").status_code == 200

            # Admin 2 demotes Admin 1 -> Admin 1's session is revoked; Admin 2 cannot demote self as last admin
            admin1_id = admin1_client.get("/v1/me", headers={"Authorization": f"Bearer {admin1_client.cookies[access.COOKIE]}"}).json()["user"]["id"]
            assert member_client.patch(f"/api/integrations/admin/users/{admin1_id}", json={"role": "user"}).status_code == 200
            assert admin1_client.get("/api/integrations/account").status_code == 401
            assert member_client.patch(f"/api/integrations/admin/users/{member_id}", json={"role": "user"}).status_code == 409


def test_password_change_rotates_cookie_and_revokes_prior_sessions(clean_env, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as c1:
        c1.post("/api/integrations/access/signup", json={"email": "rot@example.invalid", "password": "old-password-123"}).raise_for_status()
        old_tok1 = c1.cookies[access.COOKIE]

        with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as c2:
            c2.post("/api/integrations/access/login", json={"email": "rot@example.invalid", "password": "old-password-123"}).raise_for_status()
            old_tok2 = c2.cookies[access.COOKIE]

            assert c1.post("/api/integrations/access/password", json={"currentPassword": "wrong-password-1", "newPassword": "new-password-123"}).status_code == 401
            assert c1.get("/api/integrations/account").status_code == 200

            changed = c1.post("/api/integrations/access/password", json={"currentPassword": "old-password-123", "newPassword": "new-password-123"})
            assert changed.status_code == 200
            new_tok = c1.cookies[access.COOKIE]
            assert new_tok != old_tok1

            assert c1.get("/v1/me", headers={"Authorization": f"Bearer {old_tok1}"}).status_code == 401
            assert c2.get("/v1/me", headers={"Authorization": f"Bearer {old_tok2}"}).status_code == 401
            assert c1.get("/api/integrations/account").status_code == 200
            assert c1.post("/api/integrations/access/login", json={"email": "rot@example.invalid", "password": "old-password-123"}).status_code == 401
            assert c1.post("/api/integrations/access/login", json={"email": "rot@example.invalid", "password": "new-password-123"}).status_code == 200

    with TestClient(standalone) as s:
        login = s.post("/v1/auth/login", json={"email": "rot@example.invalid", "password": "new-password-123"}).json()
        assert s.post(
            "/v1/auth/password",
            json={"currentPassword": "new-password-123", "newPassword": "third-password-1"},
            headers={"Authorization": f"Bearer {login['token']}"},
        ).status_code == 200
        with account_db.connection() as db:
            actions = [r["action"] for r in db.execute("SELECT action FROM audit_log ORDER BY id ASC").fetchall()]
        assert actions.count("auth.password_change") == 2
