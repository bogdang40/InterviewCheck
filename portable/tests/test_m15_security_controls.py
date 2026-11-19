"""Tests for M15-W2: v7 schema, ic_tok_* tokens, IPv6/email lockouts, rate-limit unlock, login parity, and early boundary auth."""
import asyncio
import sqlite3
from uuid import uuid4

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
import pytest

from api import access, access_security, account_auth, account_db, local_boundary, rate_limit
from api.account_server import app as standalone
from api.main import app


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    for key in (
        "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_OPERATOR_ID",
        "INTERVIEWCHECK_PUBLIC_ORIGIN", "INTERVIEWCHECK_PRODUCTION", "INTERVIEWCHECK_SIGNUP_SECRET",
    ):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("ADMIN_EMAILS", "admin@example.invalid")
    monkeypatch.setenv("ADMIN_BOOTSTRAP_SECRET", "bootstrap-secret")
    monkeypatch.setenv("TRIAL_DAYS", "7")
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        yield client


def _signup(client: TestClient, email: str, password: str = "StrongPass-1234", *, admin: bool = False) -> dict:
    body = {"email": email, "password": password, "deviceName": "Test Device"}
    if admin:
        body["adminSecret"] = "bootstrap-secret"
    res = client.post("/v1/auth/signup", json=body)
    assert res.status_code == 201, res.text
    return res.json()


def test_v7_migration_and_unsupported_v8_rejected(env, tmp_path, monkeypatch):
    v6_path = tmp_path / "v6.sqlite3"
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(v6_path))
    with sqlite3.connect(v6_path) as raw:
        for sql in account_db.SCHEMA:
            raw.execute(sql)
        raw.execute("CREATE TABLE login_windows (address TEXT PRIMARY KEY, start INTEGER NOT NULL, hits INTEGER NOT NULL)")
        raw.execute("PRAGMA user_version=6")

    with account_db.connection() as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == account_db.VERSION
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        assert {"api_tokens", "login_email_windows"}.issubset(tables)
        idx = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='index'")}
        assert "idx_api_tokens_user" in idx

    with sqlite3.connect(v6_path) as raw:
        raw.execute(f"PRAGMA user_version={account_db.VERSION + 1}")
    with pytest.raises(HTTPException) as exc:
        with account_db.connection():
            pass
    assert exc.value.status_code == 503


def test_scoped_api_tokens_lifecycle_and_bearer_auth(env):
    admin = _signup(env, "admin@example.invalid", admin=True)
    member = _signup(env, "member@example.invalid")
    admin_h = {"Authorization": f"Bearer {admin['token']}"}
    member_h = {"Authorization": f"Bearer {member['token']}"}

    assert env.post("/v1/auth/tokens", json={"name": "escalate", "scopes": ["admin:models"]}, headers=member_h).status_code == 403
    assert env.post("/v1/auth/tokens", json={"name": "badttl", "scopes": ["read:interviews"], "ttlDays": 0}, headers=member_h).status_code == 422
    assert env.post("/v1/auth/tokens", json={"name": "badttl2", "scopes": ["read:interviews"], "ttlDays": 366}, headers=member_h).status_code == 422

    created = env.post(
        "/v1/auth/tokens",
        json={"name": "CI Reader", "scopes": ["read:interviews", "read:telemetry", "read:interviews"], "ttlDays": 30},
        headers=member_h,
    )
    assert created.status_code == 201
    raw_tok = created.json()["token"]
    tok_meta = created.json()["apiToken"]
    assert raw_tok.startswith("ic_tok_") and tok_meta["scopes"] == ["read:interviews", "read:telemetry"]
    assert tok_meta["expiresAt"] is not None and tok_meta["lastUsedAt"] is None

    listed = env.get("/v1/auth/tokens", headers=member_h).json()["tokens"]
    assert len(listed) == 1 and "token" not in listed[0] and "token_hash" not in str(listed[0])

    # Interactive endpoints reject ic_tok_*; authenticate_bearer validates scope & updates last_used_at
    assert env.get("/v1/auth/sessions", headers={"Authorization": f"Bearer {raw_tok}"}).status_code == 401
    assert env.get("/v1/me", headers={"Authorization": f"Bearer {raw_tok}"}).status_code == 401
    user, cred_id = account_auth.authenticate_bearer(f"Bearer {raw_tok}", required_scope="read:telemetry")
    assert user["id"] == member["user"]["id"] and cred_id == tok_meta["id"]
    with pytest.raises(HTTPException) as scope_exc:
        account_auth.authenticate_bearer(f"Bearer {raw_tok}", required_scope="write:interviews")
    assert scope_exc.value.status_code == 403
    assert env.get("/v1/auth/tokens", headers=member_h).json()["tokens"][0]["lastUsedAt"] is not None

    # Admin token stops working if admin is demoted; expired and disabled accounts rejected
    adm_tok = env.post("/v1/auth/tokens", json={"name": "Models", "scopes": ["admin:models"]}, headers=admin_h).json()["token"]
    assert account_auth.authenticate_bearer(f"Bearer {adm_tok}", required_scope="admin:models")[0]["id"] == admin["user"]["id"]
    with account_db.connection(write=True) as db:
        db.execute("UPDATE users SET role='user' WHERE id=?", (admin["user"]["id"],))
    with pytest.raises(HTTPException) as demoted:
        account_auth.authenticate_bearer(f"Bearer {adm_tok}", required_scope="admin:models")
    assert demoted.value.status_code == 403

    with account_db.connection(write=True) as db:
        db.execute("UPDATE api_tokens SET expires_at=? WHERE id=?", (account_db.now() - 1000, tok_meta["id"]))
    with pytest.raises(HTTPException) as expired:
        account_auth.authenticate_bearer(f"Bearer {raw_tok}")
    assert expired.value.status_code == 401
    with account_db.connection(write=True) as db:
        db.execute("UPDATE api_tokens SET expires_at=NULL WHERE id=?", (tok_meta["id"],))
    assert env.delete(f"/v1/auth/tokens/{tok_meta['id']}", headers=admin_h).status_code == 404
    assert env.delete(f"/v1/auth/tokens/{tok_meta['id']}", headers=member_h).status_code == 200
    with pytest.raises(HTTPException) as revoked:
        account_auth.authenticate_bearer(f"Bearer {raw_tok}")
    assert revoked.value.status_code == 401


def test_session_listing_revocation_and_admin_controls(env):
    admin = _signup(env, "admin@example.invalid", admin=True)
    member = _signup(env, "member@example.invalid", "StrongPass-1234")
    l2 = env.post("/v1/auth/login", json={"email": "member@example.invalid", "password": "StrongPass-1234", "deviceName": "Laptop"}).json()
    h1, h2 = {"Authorization": f"Bearer {member['token']}"}, {"Authorization": f"Bearer {l2['token']}"}
    admin_h = {"Authorization": f"Bearer {admin['token']}"}

    sessions = env.get("/v1/auth/sessions", headers=h1).json()["sessions"]
    assert len(sessions) == 2 and sum(s["isCurrent"] for s in sessions) == 1
    assert all("token_hash" not in str(s) for s in sessions)
    other_id = next(s["id"] for s in sessions if not s["isCurrent"])
    assert env.delete(f"/v1/auth/sessions/{other_id}", headers=h1).status_code == 200
    assert env.get("/v1/me", headers=h2).status_code == 401
    assert env.delete(f"/v1/auth/sessions/{other_id}", headers=admin_h).status_code == 404

    uid = member["user"]["id"]
    assert env.get(f"/v1/admin/users/{uid}/sessions", headers=h1).status_code == 403
    assert len(env.get(f"/v1/admin/users/{uid}/sessions", headers=admin_h).json()["sessions"]) == 1
    rev = env.post(f"/v1/admin/users/{uid}/revoke-sessions", json={}, headers=admin_h)
    assert rev.status_code == 200 and rev.json()["revokedCount"] == 1
    assert env.get("/v1/me", headers=h1).status_code == 401
    assert env.post("/v1/auth/login", json={"email": "member@example.invalid", "password": "StrongPass-1234"}).status_code == 200

    with account_db.connection() as db:
        actions = {r[0] for r in db.execute("SELECT action FROM audit_log").fetchall()}
    assert {"auth.session_revoke", "admin.revoke_sessions"}.issubset(actions)


def test_ipv6_slash64_email_lockouts_and_admin_rate_limit_unlock(env, monkeypatch):
    admin = _signup(env, "admin@example.invalid", admin=True)
    _signup(env, "victim@example.invalid", "VictimPass-1234")
    admin_h = {"Authorization": f"Bearer {admin['token']}"}

    assert account_auth.normalize_address("2001:db8:1:2::1") == "2001:db8:1:2::/64"
    assert account_auth.normalize_address("2001:db8:1:2:ffff::99") == "2001:db8:1:2::/64"
    assert account_auth.normalize_address("::ffff:192.0.2.10") == "192.0.2.10"

    public = "https://review.example.test"
    monkeypatch.setenv("INTERVIEWCHECK_PUBLIC_ORIGIN", public)
    monkeypatch.setenv("INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP", "1")
    pub_h = {"Origin": public, "X-Forwarded-Host": "review.example.test", "X-InterviewCheck": "1"}
    with TestClient(app, base_url="https://127.0.0.1:8000", client=("127.0.0.1", 52000), headers=pub_h) as pub:
        for i in range(10):
            res = pub.post("/v1/auth/login", json={"email": "nobody@example.invalid", "password": "WrongPass-1234"},
                           headers={"X-InterviewCheck-Client-IP": f"2001:db8:aa:bb::{i + 1:x}"})
            assert res.status_code == 401
        blocked_v6 = pub.post("/v1/auth/login", json={"email": "nobody@example.invalid", "password": "WrongPass-1234"},
                              headers={"X-InterviewCheck-Client-IP": "2001:db8:aa:bb:ffff::42"})
        assert blocked_v6.status_code == 429

        # Distributed stuffing across 10 distinct IPv4s triggers login_email_windows lockout on 11th IP
        for i in range(10):
            assert pub.post("/v1/auth/login", json={"email": "victim@example.invalid", "password": "WrongPass-1234"},
                            headers={"X-InterviewCheck-Client-IP": f"198.51.100.{i + 1}"}).status_code == 401
        assert pub.post("/v1/auth/login", json={"email": "victim@example.invalid", "password": "VictimPass-1234"},
                        headers={"X-InterviewCheck-Client-IP": "198.51.100.250"}).status_code == 429

        # In-memory limiter + SQLite windows are visible (masked) and unlockable via admin/rate-limits
        rate_limit.ADMIN_READ.hit("203.0.113.5")
        snapshot = pub.get("/v1/admin/rate-limits", headers=admin_h)
        assert snapshot.status_code == 200
        entries = snapshot.json()["entries"]
        assert "victim@example.invalid" not in snapshot.text and "203.0.113.5" not in snapshot.text
        sources = {e["source"] for e in entries}
        assert {"memory", "login_windows", "login_email_windows"}.issubset(sources)

        victim_hash = next(e["keyHash"] for e in entries if e["source"] == "login_email_windows" and e["maskedKey"].startswith("v***@"))
        assert pub.delete(f"/v1/admin/rate-limits?keyHash={victim_hash}", headers=admin_h).json()["cleared"] == 1
        assert pub.post("/v1/auth/login", json={"email": "victim@example.invalid", "password": "VictimPass-1234"},
                        headers={"X-InterviewCheck-Client-IP": "198.51.100.250"}).status_code == 200
        assert pub.delete("/v1/admin/rate-limits", headers=admin_h).json()["cleared"] >= 1
        assert pub.post("/v1/auth/login", json={"email": "victim@example.invalid", "password": "VictimPass-1234"},
                        headers={"X-InterviewCheck-Client-IP": "2001:db8:aa:bb:ffff::42"}).status_code == 200


def test_operator_email_login_parity_and_early_large_body_gate(env, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_OPERATOR_EMAIL", "op@example.invalid")
    assert env.post("/api/integrations/access/signup", json={"email": "other@example.invalid", "password": "StrongPass-1234"}).status_code == 403
    assert env.post("/api/integrations/access/signup", json={"email": "op@example.invalid", "password": "StrongPass-1234"}).status_code == 200

    wrong_op = env.post("/api/integrations/access/login", json={"email": "other@example.invalid", "password": "WrongPass-1234"})
    wrong_pw = env.post("/api/integrations/access/login", json={"email": "op@example.invalid", "password": "WrongPass-1234"})
    assert wrong_op.status_code == 401 and wrong_pw.status_code == 401
    assert wrong_op.json() == wrong_pw.json()

    # Existing non-operator user with valid password still blocked post-auth (403) with no cookie
    with account_db.connection(write=True) as db:
        ts = account_db.now()
        db.execute("INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,0,?,?)",
                   (str(uuid4()), "extra@example.invalid", account_db.hash_password("ExtraPass-1234"), "user", ts, ts))
    env.cookies.clear()
    blocked_extra = env.post("/api/integrations/access/login", json={"email": "extra@example.invalid", "password": "ExtraPass-1234"})
    assert blocked_extra.status_code == 403 and access.COOKIE not in env.cookies

    # LocalBoundary early 401 on >256 KiB workspace uploads without ic_access, preserving CSRF 403 first
    received_calls = 0

    async def run_boundary(path: str, headers: list[tuple[bytes, bytes]], chunks: list[dict]):
        nonlocal received_calls
        sent, queue = [], list(chunks)

        async def receive():
            nonlocal received_calls
            received_calls += 1
            return queue.pop(0) if queue else {"type": "http.disconnect"}

        mw = local_boundary.LocalBoundary(lambda s, r, se: se({"type": "http.response.start", "status": 200, "headers": []}))
        await mw({"type": "http", "method": "POST", "scheme": "http", "path": path, "headers": headers}, receive,
                 lambda m: asyncio.sleep(0, result=sent.append(m)))
        return sent[0]["status"]

    no_csrf = [(b"host", b"127.0.0.1"), (b"content-length", str(300 * 1024).encode())]
    assert asyncio.run(run_boundary("/api/integrations/transcribe", no_csrf, [])) == 403
    assert received_calls == 0

    unauth_big = [(b"host", b"127.0.0.1"), (b"x-interviewcheck", b"1"), (b"content-length", str(300 * 1024).encode())]
    assert asyncio.run(run_boundary("/api/integrations/transcribe", unauth_big, [])) == 401
    assert received_calls == 0

    chunked_big = [(b"host", b"127.0.0.1"), (b"x-interviewcheck", b"1")]
    chunks = [{"type": "http.request", "body": b"a" * (260 * 1024), "more_body": True}]
    assert asyncio.run(run_boundary("/api/integrations/transcribe", chunked_big, chunks)) == 401
    assert asyncio.run(run_boundary("/api/integrations/access/login", unauth_big, [{"type": "http.request", "body": b"{}", "more_body": False}])) == 200
    assert asyncio.run(run_boundary("/v1/auth/login", unauth_big, [])) == 413
    auth_big = unauth_big + [(b"cookie", b"ic_access=mm_fixture_cookie_token")]
    assert asyncio.run(run_boundary("/api/integrations/transcribe", auth_big, [{"type": "http.request", "body": b"ok", "more_body": False}])) == 200


def test_access_security_cookie_proxy_routes(env):
    proxy_app = FastAPI()
    proxy_app.include_router(access_security.router, prefix="/api/integrations")
    with TestClient(proxy_app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as px:
        assert px.get("/api/integrations/security/sessions").status_code == 401
        assert px.get("/api/integrations/admin/security/rate-limits").status_code == 401

        admin = _signup(env, "admin@example.invalid", admin=True)
        member = _signup(env, "member@example.invalid")

        px.cookies.set(access.COOKIE, member["token"])
        assert px.get("/api/integrations/admin/security/rate-limits").status_code == 403
        msess = px.get("/api/integrations/security/sessions").json()["sessions"]
        assert len(msess) == 1
        tok = px.post("/api/integrations/security/tokens", json={"name": "ProxyTok", "scopes": ["read:interviews"]})
        assert tok.status_code == 201 and tok.json()["token"].startswith("ic_tok_")
        tid = tok.json()["apiToken"]["id"]
        assert len(px.get("/api/integrations/security/tokens").json()["tokens"]) == 1
        assert px.delete(f"/api/integrations/security/tokens/{tid}").status_code == 200
        assert px.delete(f"/api/integrations/security/sessions/{msess[0]['id']}").status_code == 200
        assert px.get("/api/integrations/security/sessions").status_code == 401

        px.cookies.set(access.COOKIE, admin["token"])
        assert px.get(f"/api/integrations/admin/security/users/{member['user']['id']}/sessions").json()["sessions"] == []
        member2 = env.post("/v1/auth/login", json={"email": "member@example.invalid", "password": "StrongPass-1234"}).json()
        assert member2["token"].startswith("mm_")
        assert px.post(f"/api/integrations/admin/security/users/{member['user']['id']}/revoke-sessions").json()["revokedCount"] == 1
        rate_limit.ADMIN_READ.hit("203.0.113.9")
        rl = px.get("/api/integrations/admin/security/rate-limits").json()["entries"]
        target_hash = next(e["keyHash"] for e in rl if e["maskedKey"].startswith("203.0."))
        assert px.delete(f"/api/integrations/admin/security/rate-limits?keyHash={target_hash}").json()["cleared"] == 1
        assert px.delete("/api/integrations/admin/security/rate-limits").status_code == 200
