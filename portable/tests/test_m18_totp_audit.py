"""Tests for M18-W2: v8 schema, RFC 6238 TOTP 2FA, backup codes, lockouts, and SHA-256 audit hash chain."""
import hashlib
import re
import sqlite3
from unittest.mock import AsyncMock

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest

from api import access, account_db, rate_limit, totp_service
from api.account_server import app as standalone
from api.main import app


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "m18-totp-test-master-key")
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
    body = {"email": email, "password": password, "deviceName": "PyTest"}
    if admin:
        body["adminSecret"] = "bootstrap-secret"
    res = client.post("/v1/auth/signup", json=body)
    assert res.status_code == 201, res.text
    return res.json()


def test_v8_migration_from_v7_and_unsupported_v9(env, tmp_path, monkeypatch):
    v7_path = tmp_path / "v7.sqlite3"
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(v7_path))
    with sqlite3.connect(v7_path) as raw:
        for sql in account_db.SCHEMA:
            raw.execute(sql.replace(",prev_hash TEXT,entry_hash TEXT", ""))
        raw.execute("CREATE TABLE login_windows (address TEXT PRIMARY KEY, start INTEGER NOT NULL, hits INTEGER NOT NULL)")
        raw.execute("CREATE TABLE login_email_windows (email TEXT PRIMARY KEY, start INTEGER NOT NULL, hits INTEGER NOT NULL)")
        raw.execute("INSERT INTO audit_log(at,actor_user_id,action,target_user_id,details) VALUES (1000,'u1','legacy.v7','u1',NULL)")
        raw.execute("PRAGMA user_version=7")

    with account_db.connection() as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == 8
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        assert {"user_totp", "user_backup_codes"}.issubset(tables)
        idx = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='index'")}
        assert "idx_backup_codes_user" in idx
        cols = {r[1] for r in db.execute("PRAGMA table_info('audit_log')").fetchall()}
        assert {"prev_hash", "entry_hash"}.issubset(cols)
        totp_cols = {r[1] for r in db.execute("PRAGMA table_info('user_totp')").fetchall()}
        assert "last_used_step" in totp_cols
        legacy = db.execute("SELECT prev_hash, entry_hash FROM audit_log WHERE action='legacy.v7'").fetchone()
        assert tuple(legacy) == (None, None)

    with sqlite3.connect(v7_path) as raw:
        raw.execute("PRAGMA user_version=9")
    with pytest.raises(HTTPException) as exc:
        with account_db.connection():
            pass
    assert exc.value.status_code == 503

    # Interim DB with user_version=4, existing audit_log hash columns, and user_totp missing last_used_step upgrades idempotently
    interim_path = tmp_path / "interim.sqlite3"
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(interim_path))
    with sqlite3.connect(interim_path) as raw:
        for sql in account_db.SCHEMA:
            raw.execute(sql)
        raw.execute("CREATE TABLE user_totp (user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE, secret_enc TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 0, verified_at INTEGER, created_at INTEGER NOT NULL)")
        raw.execute("PRAGMA user_version=4")
    with account_db.connection() as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == 8
        assert "last_used_step" in {r[1] for r in db.execute("PRAGMA table_info('user_totp')").fetchall()}


def test_rfc6238_vectors_and_window():
    # RFC 6238 Appendix B SHA1 secret ("12345678901234567890")
    rfc_secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    assert totp_service.generate_totp_code(rfc_secret, 59_000) == "287082"
    assert totp_service.generate_totp_code(rfc_secret, 1_111_111_109_000) == "081804"
    assert totp_service.generate_totp_code(rfc_secret, 1_234_567_890_000) == "005924"

    now_ms = 1_700_000_010_000
    assert totp_service.verify_totp_code(rfc_secret, totp_service.generate_totp_code(rfc_secret, now_ms - 30_000), now_ms)
    assert totp_service.verify_totp_code(rfc_secret, totp_service.generate_totp_code(rfc_secret, now_ms), now_ms)
    assert totp_service.verify_totp_code(rfc_secret, totp_service.generate_totp_code(rfc_secret, now_ms + 30_000), now_ms)
    assert not totp_service.verify_totp_code(rfc_secret, totp_service.generate_totp_code(rfc_secret, now_ms - 60_000), now_ms)
    assert not totp_service.verify_totp_code(rfc_secret, totp_service.generate_totp_code(rfc_secret, now_ms + 60_000), now_ms)
    assert not totp_service.verify_totp_code(rfc_secret, "12345", now_ms)
    assert not totp_service.verify_totp_code(rfc_secret, "abcdef", now_ms)


def test_totp_lifecycle_aad_and_proxy_routes(env, monkeypatch):
    admin = _signup(env, "admin@example.invalid", admin=True)
    member = _signup(env, "member@example.invalid")
    member_h = {"Authorization": f"Bearer {member['token']}"}
    member_id = member["user"]["id"]

    assert env.get("/v1/auth/totp/status").status_code == 401
    assert env.get("/api/integrations/security/totp/status").status_code == 401
    tok_res = env.post("/v1/auth/tokens", json={"name": "ApiTok", "scopes": ["read:interviews"]}, headers=member_h)
    assert tok_res.status_code == 201
    assert env.get("/v1/auth/totp/status", headers={"Authorization": f"Bearer {tok_res.json()['token']}"}).status_code == 401

    assert env.get("/v1/auth/totp/status", headers=member_h).json() == {
        "enabled": False, "verifiedAt": None, "remainingBackupCodes": 0,
    }
    assert env.post("/v1/auth/totp/verify", json={"code": "123456"}, headers=member_h).status_code == 400

    # Proxy cookie auth works for setup/status/verify/regenerate/disable
    env.cookies.set(access.COOKIE, member["token"])
    setup = env.post("/api/integrations/security/totp/setup").json()
    assert setup["issuer"] == "InterviewCheck"
    assert re.fullmatch(r"[A-Z2-7]{32}", setup["secret"])
    assert "otpauth://totp/InterviewCheck:member%40example.invalid" in setup["otpauthUri"]
    assert f"secret={setup['secret']}" in setup["otpauthUri"]

    with account_db.connection() as db:
        row = db.execute("SELECT secret_enc, enabled FROM user_totp WHERE user_id=?", (member_id,)).fetchone()
        assert row["enabled"] == 0 and row["secret_enc"].startswith("v1:") and setup["secret"] not in row["secret_enc"]

    assert env.post("/api/integrations/security/totp/verify", json={"code": "000000"}).status_code == 400
    fixed_ms = 1_760_000_010_000
    monkeypatch.setattr(account_db, "now", lambda: fixed_ms)
    code = totp_service.generate_totp_code(setup["secret"], fixed_ms)
    verified = env.post("/api/integrations/security/totp/verify", json={"code": code})
    assert verified.status_code == 200
    v_body = verified.json()
    assert v_body["enabled"] is True and v_body["verifiedAt"] == account_db.iso(fixed_ms)
    assert len(v_body["backupCodes"]) == 8 and len(set(v_body["backupCodes"])) == 8
    with account_db.connection() as db:
        for bcode in v_body["backupCodes"]:
            assert re.fullmatch(r"[A-Z2-9]{4}-[A-Z2-9]{4}", bcode)
            digest = hashlib.sha256(bcode.encode("utf-8")).hexdigest()
            assert db.execute("SELECT 1 FROM user_backup_codes WHERE user_id=? AND code_hash=?", (member_id, digest)).fetchone()

    assert env.post("/v1/auth/totp/setup", json={}, headers=member_h).status_code == 409
    assert env.get("/api/integrations/security/totp/status").json() == {
        "enabled": True, "verifiedAt": account_db.iso(fixed_ms), "remainingBackupCodes": 8,
    }

    # AAD binding check: moving ciphertext to admin user_id fails decryption
    with account_db.connection(write=True) as db:
        enc = db.execute("SELECT secret_enc FROM user_totp WHERE user_id=?", (member_id,)).fetchone()["secret_enc"]
        db.execute("INSERT INTO user_totp(user_id,secret_enc,enabled,verified_at,created_at) VALUES (?,?,1,?,?)",
                   (admin["user"]["id"], enc, fixed_ms, fixed_ms))
        assert totp_service.verify_login_factor(db, admin["user"]["id"], code, fixed_ms) is None
        db.execute("DELETE FROM user_totp WHERE user_id=?", (admin["user"]["id"],))

    # Regenerate requires valid TOTP in a newer 30s step
    fixed_ms += 30_000
    code = totp_service.generate_totp_code(setup["secret"], fixed_ms)
    assert env.post("/api/integrations/security/totp/backup-codes/regenerate", json={"code": "000000"}).status_code == 401
    regen = env.post("/api/integrations/security/totp/backup-codes/regenerate", json={"code": code})
    assert regen.status_code == 200 and len(regen.json()["backupCodes"]) == 8
    assert regen.json()["backupCodes"][0] != v_body["backupCodes"][0]

    # Disable requires valid password + TOTP or current unused backup code
    assert env.post("/api/integrations/security/totp/disable", json={"currentPassword": "wrong-password!", "code": code}).status_code == 401
    assert env.post("/api/integrations/security/totp/disable", json={"currentPassword": "StrongPass-1234", "code": v_body["backupCodes"][0]}).status_code == 401
    disabled = env.post("/api/integrations/security/totp/disable", json={"currentPassword": "StrongPass-1234", "code": regen.json()["backupCodes"][0]})
    assert disabled.status_code == 200 and disabled.json() == {"enabled": False}
    assert env.get("/api/integrations/security/totp/status").json() == {"enabled": False, "verifiedAt": None, "remainingBackupCodes": 0}


def test_login_totp_enforcement_backup_tx_and_lockouts(env, monkeypatch):
    member = _signup(env, "member@example.invalid")
    member_h = {"Authorization": f"Bearer {member['token']}"}
    fixed_ms = 1_760_000_010_000
    monkeypatch.setattr(account_db, "now", lambda: fixed_ms)
    setup = env.post("/v1/auth/totp/setup", json={}, headers=member_h).json()
    code = totp_service.generate_totp_code(setup["secret"], fixed_ms)
    backup_codes = env.post("/v1/auth/totp/verify", json={"code": code}, headers=member_h).json()["backupCodes"]

    # Missing totpCode -> 401 totp_required + X-InterviewCheck-TOTP: required on both /v1 and /api/integrations
    v1_missing = env.post("/v1/auth/login", json={"email": "member@example.invalid", "password": "StrongPass-1234"})
    assert v1_missing.status_code == 401
    assert v1_missing.headers.get("x-interviewcheck-totp") == "required"
    assert v1_missing.json()["error"]["code"] == "totp_required"

    px_missing = env.post("/api/integrations/access/login", json={"email": "member@example.invalid", "password": "StrongPass-1234"})
    assert px_missing.status_code == 401
    assert px_missing.headers.get("x-interviewcheck-totp") == "required"
    assert access.COOKIE not in env.cookies

    # Invalid totpCode increments IP + email lockout windows
    bad = env.post("/api/integrations/access/login", json={"email": "member@example.invalid", "password": "StrongPass-1234", "totpCode": "000000"})
    assert bad.status_code == 401
    with account_db.connection() as db:
        assert db.execute("SELECT hits FROM login_email_windows WHERE email=?", ("member@example.invalid",)).fetchone()["hits"] == 1

    # Valid TOTP login in next 30s step clears email window and sets cookie
    fixed_ms += 30_000
    code = totp_service.generate_totp_code(setup["secret"], fixed_ms)
    ok = env.post("/api/integrations/access/login", json={"email": "member@example.invalid", "password": "StrongPass-1234", "totpCode": code})
    assert ok.status_code == 200 and ok.json()["email"] == "member@example.invalid"
    assert access.COOKIE in env.cookies
    with account_db.connection() as db:
        assert db.execute("SELECT 1 FROM login_email_windows WHERE email=?", ("member@example.invalid",)).fetchone() is None

    # Transactional rollback if session insertion fails during backup code login
    backup = backup_codes[0]
    with account_db.connection(write=True) as db:
        db.execute("CREATE TRIGGER abort_session BEFORE INSERT ON sessions BEGIN SELECT RAISE(ABORT, 'db fail'); END")
    with TestClient(standalone, raise_server_exceptions=False) as sa:
        assert sa.post("/v1/auth/login", json={"email": "member@example.invalid", "password": "StrongPass-1234", "totpCode": backup}).status_code == 500
    with account_db.connection(write=True) as db:
        db.execute("DROP TRIGGER abort_session")
    assert env.get("/v1/auth/totp/status", headers=member_h).json()["remainingBackupCodes"] == 8

    # Backup code single-use redemption (case/hyphen insensitive)
    env.cookies.clear()
    b_ok = env.post("/api/integrations/access/login", json={
        "email": "member@example.invalid", "password": "StrongPass-1234", "totpCode": backup.replace("-", "").lower(),
    })
    assert b_ok.status_code == 200 and env.get("/v1/auth/totp/status", headers=member_h).json()["remainingBackupCodes"] == 7
    assert env.post("/v1/auth/login", json={"email": "member@example.invalid", "password": "StrongPass-1234", "totpCode": backup}).status_code == 401

    # 9 more invalid TOTP attempts (total 10 with backupReuse) across distinct IPs triggers 429 email lockout
    monkeypatch.setenv("INTERVIEWCHECK_PUBLIC_ORIGIN", "https://review.example.test")
    monkeypatch.setenv("INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP", "1")
    pub_h = {"Origin": "https://review.example.test", "X-Forwarded-Host": "review.example.test", "X-InterviewCheck": "1"}
    with TestClient(app, base_url="https://127.0.0.1:8000", client=("127.0.0.1", 52000), headers=pub_h) as pub:
        for i in range(9):
            r = pub.post("/v1/auth/login", json={"email": "member@example.invalid", "password": "StrongPass-1234", "totpCode": "000000"},
                         headers={"X-InterviewCheck-Client-IP": f"198.51.100.{i + 1}"})
            assert r.status_code == 401
        locked = pub.post("/v1/auth/login", json={"email": "member@example.invalid", "password": "StrongPass-1234", "totpCode": code},
                          headers={"X-InterviewCheck-Client-IP": "198.51.100.99"})
        assert locked.status_code == 429

        # Same-IP invalid TOTP attempts also trigger 429 IP lockout in login_windows
        for i in range(10):
            r = pub.post("/v1/auth/login", json={"email": f"other{i}@example.invalid", "password": "StrongPass-1234", "totpCode": "000000"},
                         headers={"X-InterviewCheck-Client-IP": "198.51.100.200"})
            assert r.status_code == 401
        ip_locked = pub.post("/v1/auth/login", json={"email": "other99@example.invalid", "password": "StrongPass-1234"},
                             headers={"X-InterviewCheck-Client-IP": "198.51.100.200"})
        assert ip_locked.status_code == 429

    # Remote access mode propagates totp_required via upstream mock
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://accounts.example.invalid")
    monkeypatch.setattr(access, "upstream", AsyncMock(side_effect=HTTPException(401, "TOTP required.", headers={"X-InterviewCheck-TOTP": "required"})))
    remote_res = env.post("/api/integrations/access/login", json={"email": "member@example.invalid", "password": "StrongPass-1234"})
    assert remote_res.status_code == 401 and remote_res.headers.get("x-interviewcheck-totp") == "required"


def test_audit_hash_chain_verification_and_tamper_detection(env):
    admin = _signup(env, "admin@example.invalid", admin=True)
    member = _signup(env, "member@example.invalid")
    admin_h = {"Authorization": f"Bearer {admin['token']}"}
    member_h = {"Authorization": f"Bearer {member['token']}"}

    assert env.get("/v1/admin/audit/verify").status_code == 401
    assert env.get("/v1/admin/audit/verify", headers=member_h).status_code == 403
    assert env.get("/api/integrations/admin/audit/verify").status_code == 401
    env.cookies.set(access.COOKIE, member["token"])
    assert env.get("/api/integrations/admin/audit/verify").status_code == 403

    env.cookies.set(access.COOKIE, admin["token"])
    for path, hdrs in (("/v1/admin/audit/verify", admin_h), ("/api/integrations/admin/audit/verify", {})):
        res = env.get(path, headers=hdrs)
        assert res.status_code == 200 and res.headers["cache-control"] == "no-store"
        body = res.json()
        assert body["ok"] is True and body["verifiedCount"] == 2 and body["legacyUnchainedCount"] == 0
        assert body["firstBrokenId"] is None and re.fullmatch(r"[a-f0-9]{64}", body["headHash"])

    with account_db.connection() as db:
        rows = db.execute("SELECT * FROM audit_log ORDER BY id ASC").fetchall()
        first, second = rows[0], rows[1]
        expected_payload = f"GENESIS|{first['at']}|{first['actor_user_id'] or ''}|{first['action']}|{first['target_user_id'] or ''}|{first['details'] or ''}"
        assert first["prev_hash"] is None
        assert first["entry_hash"] == hashlib.sha256(expected_payload.encode("utf-8")).hexdigest()
        assert second["prev_hash"] == first["entry_hash"]

    # Tamper details on first row -> break at first.id
    with account_db.connection(write=True) as db:
        db.execute("UPDATE audit_log SET details=? WHERE id=?", ('{"role":"admin"}', first["id"]))
    assert env.get("/api/integrations/admin/audit/verify").json() == {
        "ok": False, "verifiedCount": 0, "legacyUnchainedCount": 0, "firstBrokenId": first["id"], "headHash": None,
    }

    # Legacy unchained prefix followed by chained rows -> ok=True; deleting middle chained row -> ok=False
    with account_db.connection(write=True) as db:
        db.execute("DELETE FROM audit_log")
        db.execute("INSERT INTO audit_log(at,actor_user_id,action,target_user_id,details,prev_hash,entry_hash) VALUES (1000,'u1','legacy.event','u1',NULL,NULL,NULL)")
        account_db.audit(db, "post_v8.one", member["user"]["id"], member["user"]["id"])
        account_db.audit(db, "post_v8.two", member["user"]["id"], member["user"]["id"])
    with_legacy = env.get("/v1/admin/audit/verify", headers=admin_h).json()
    assert with_legacy["ok"] is True and with_legacy["legacyUnchainedCount"] == 1 and with_legacy["verifiedCount"] == 2

    with account_db.connection(write=True) as db:
        chained_ids = [r[0] for r in db.execute("SELECT id FROM audit_log WHERE entry_hash IS NOT NULL ORDER BY id ASC").fetchall()]
        db.execute("DELETE FROM audit_log WHERE id=?", (chained_ids[0],))
    assert env.get("/v1/admin/audit/verify", headers=admin_h).json() == {
        "ok": False, "verifiedCount": 0, "legacyUnchainedCount": 1, "firstBrokenId": chained_ids[1], "headHash": None,
    }

    # Unchained row injected after chaining started fails verification
    with account_db.connection(write=True) as db:
        db.execute("DELETE FROM audit_log")
        account_db.audit(db, "post_v8.valid", member["user"]["id"], member["user"]["id"])
        db.execute("INSERT INTO audit_log(at,actor_user_id,action,target_user_id,details,prev_hash,entry_hash) VALUES (2000,'u1','injected',NULL,NULL,NULL,NULL)")
        inj_id = db.execute("SELECT id FROM audit_log WHERE action='injected'").fetchone()[0]
    assert env.get("/v1/admin/audit/verify", headers=admin_h).json()["firstBrokenId"] == inj_id


def test_totp_same_step_replay_rejection_and_step_zero(env, monkeypatch):
    rfc_secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    assert totp_service.match_totp_step(rfc_secret, totp_service.generate_totp_code(rfc_secret, 0), 0) == 0
    assert totp_service.verify_totp_code(rfc_secret, totp_service.generate_totp_code(rfc_secret, 0), 0) is True

    member = _signup(env, "replay@example.invalid")
    hdrs = {"Authorization": f"Bearer {member['token']}"}
    fixed_ms = 1_760_000_010_000
    monkeypatch.setattr(account_db, "now", lambda: fixed_ms)
    setup = env.post("/v1/auth/totp/setup", json={}, headers=hdrs).json()
    with account_db.connection() as db:
        assert db.execute("SELECT last_used_step FROM user_totp WHERE user_id=?", (member["user"]["id"],)).fetchone()[0] is None

    c1 = totp_service.generate_totp_code(setup["secret"], fixed_ms)
    assert env.post("/v1/auth/totp/verify", json={"code": c1}, headers=hdrs).status_code == 200
    # Immediate same-step replay fails across login, regenerate, and disable (even with -1/+1 window codes <= step)
    assert env.post("/v1/auth/login", json={"email": "replay@example.invalid", "password": "StrongPass-1234", "totpCode": c1}).status_code == 401
    assert env.post("/v1/auth/totp/backup-codes/regenerate", json={"code": c1}, headers=hdrs).status_code == 401
    assert env.post("/v1/auth/totp/disable", json={"currentPassword": "StrongPass-1234", "code": c1}, headers=hdrs).status_code == 401

    fixed_ms += 30_000
    assert env.post("/v1/auth/login", json={"email": "replay@example.invalid", "password": "StrongPass-1234", "totpCode": c1}).status_code == 401
    c2 = totp_service.generate_totp_code(setup["secret"], fixed_ms)
    assert env.post("/v1/auth/login", json={"email": "replay@example.invalid", "password": "StrongPass-1234", "totpCode": c2}).status_code == 200
    assert env.post("/v1/auth/login", json={"email": "replay@example.invalid", "password": "StrongPass-1234", "totpCode": c2}).status_code == 401
    assert env.post("/v1/auth/totp/disable", json={"currentPassword": "StrongPass-1234", "code": c2}, headers=hdrs).status_code == 401

    fixed_ms += 30_000
    c3 = totp_service.generate_totp_code(setup["secret"], fixed_ms)
    assert env.post("/v1/auth/totp/backup-codes/regenerate", json={"code": c3}, headers=hdrs).status_code == 200
    assert env.post("/v1/auth/totp/backup-codes/regenerate", json={"code": c3}, headers=hdrs).status_code == 401

    fixed_ms += 30_000
    c4 = totp_service.generate_totp_code(setup["secret"], fixed_ms)
    assert env.post("/v1/auth/totp/disable", json={"currentPassword": "StrongPass-1234", "code": c4}, headers=hdrs).status_code == 200


def test_totp_endpoint_rate_limiting_and_admin_unlock(env, monkeypatch):
    admin = _signup(env, "admin@example.invalid", admin=True)
    u1 = _signup(env, "u1@example.invalid")
    u2 = _signup(env, "u2@example.invalid")
    admin_h = {"Authorization": f"Bearer {admin['token']}"}
    u1_h = {"Authorization": f"Bearer {u1['token']}"}
    u2_h = {"Authorization": f"Bearer {u2['token']}"}

    rate_limit.TOTP_ACTION.reset()
    assert [env.post("/v1/auth/totp/verify", json={"code": "000000"}, headers=u1_h).status_code for _ in range(10)] == [400] * 10
    blocked = env.post("/v1/auth/totp/verify", json={"code": "000000"}, headers=u1_h)
    assert blocked.status_code == 429 and int(blocked.headers["retry-after"]) >= 1
    assert blocked.json()["error"]["code"] == "rate_limited"
    assert env.post("/v1/auth/totp/disable", json={"currentPassword": "StrongPass-1234", "code": "000000"}, headers=u1_h).status_code == 429
    assert env.post("/v1/auth/totp/backup-codes/regenerate", json={"code": "000000"}, headers=u1_h).status_code == 429

    # Per-user isolation: u2 is unaffected and embedded proxy delegates rate limiting without double-counting
    env.cookies.set(access.COOKIE, u2["token"])
    assert [env.post("/api/integrations/security/totp/verify", json={"code": "000000"}).status_code for _ in range(10)] == [400] * 10
    assert env.post("/api/integrations/security/totp/verify", json={"code": "000000"}).status_code == 429

    entries = env.get("/v1/admin/rate-limits", headers=admin_h).json()["entries"]
    assert any(e["limiter"] == "totp" and e["maskedKey"].startswith("us***") for e in entries)
    assert env.delete("/v1/admin/rate-limits?limiter=totp", headers=admin_h).json()["cleared"] >= 2
    assert env.post("/v1/auth/totp/verify", json={"code": "000000"}, headers=u1_h).status_code == 400
    assert env.post("/v1/auth/totp/verify", json={"code": "000000"}, headers=u2_h).status_code == 400

    env.cookies.clear()
    assert [env.post("/api/integrations/security/totp/verify", json={"code": "000000"}).status_code for _ in range(11)] == [401] * 11
    env.cookies.set(access.COOKIE, u2["token"])
    assert [env.post("/api/integrations/security/totp/verify", json={"code": "000000"}).status_code for _ in range(9)] == [400] * 9
    assert env.post("/api/integrations/security/totp/verify", json={"code": "000000"}).status_code == 429
    env.cookies.set(access.COOKIE, u1["token"])
    assert env.post("/api/integrations/security/totp/verify", json={"code": "000000"}).status_code == 400

    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://accounts.example.invalid")
    monkeypatch.setattr(access, "upstream", AsyncMock(side_effect=lambda p, *a, token=None, **k: {"user": {"id": token, "role": "user"}, "entitlement": {"active": True}} if p == "me" else {}))
    env.cookies.set(access.COOKIE, "r2")
    assert [env.post("/api/integrations/security/totp/verify", json={"code": "000000"}).status_code for _ in range(10)] == [200] * 10
    assert env.post("/api/integrations/security/totp/verify", json={"code": "000000"}).status_code == 429
    env.cookies.set(access.COOKIE, "r1")
    assert env.post("/api/integrations/security/totp/verify", json={"code": "000000"}).status_code == 200
