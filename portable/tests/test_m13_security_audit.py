"""Tests for M13-W2 readiness probes and cross-wave M8/M12/health security audit."""
from contextlib import closing
import os
import sqlite3
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import access, account_db, health_probes, secret_box, store
from api.main import app

EXPECTED_KEYS = {"review_db", "access_db", "secret_box", "web_bundle"}


def _assert_security_headers(headers, *, expect_hsts: bool = False) -> None:
    assert headers["cache-control"] == "no-store"
    assert headers["x-content-type-options"] == "nosniff"
    assert headers["x-frame-options"] == "DENY"
    assert headers["referrer-policy"] == "no-referrer"
    assert "microphone=(self)" in headers["permissions-policy"]
    assert "camera=()" in headers["permissions-policy"]
    csp = headers["content-security-policy"]
    assert "default-src 'none'" in csp and "frame-ancestors 'none'" in csp
    if expect_hsts:
        assert "max-age=31536000" in headers["strict-transport-security"]


def _assert_minimized_readyz(res, tmp_path) -> dict:
    body = res.json()
    assert set(body.keys()) == {"ok", "checks"} and isinstance(body["ok"], bool)
    checks = body["checks"]
    assert set(checks.keys()) == EXPECTED_KEYS
    assert checks["review_db"] in {"ok", "error"}
    assert checks["access_db"] in {"ok", "skipped", "error"}
    assert checks["secret_box"] in {"ok", "error"}
    assert checks["web_bundle"] in {"ok", "missing"}
    raw = res.text
    assert str(tmp_path) not in raw
    for marker in ("Traceback", "Exception", "Error", ".sqlite", ".model_secret", "icbox", "v1:", "v2:"):
        assert marker not in raw
    _assert_security_headers(res.headers)
    return body


def _seed_user(role: str = "user", disabled: bool = False) -> tuple[str, str]:
    uid = str(uuid4())
    with account_db.connection(write=True) as db:
        ts = account_db.now()
        db.execute(
            "INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,?,?,?)",
            (uid, f"{uid[:8]}@example.invalid", account_db.DECOY, role, 1 if disabled else 0, ts, ts),
        )
        tok = account_db.issue(db, uid, "pytest")
    return uid, tok


@pytest.fixture
def probe_env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    for key in (
        "INTERVIEWCHECK_ACCESS_MODE",
        "INTERVIEWCHECK_ACCESS_URL",
        "INTERVIEWCHECK_MODEL_SECRET_KEY",
        "INTERVIEWCHECK_MODEL_SECRET_FILE",
        "INTERVIEWCHECK_OPERATOR_EMAIL",
        "INTERVIEWCHECK_OPERATOR_ID",
        "INTERVIEWCHECK_PUBLIC_ORIGIN",
        "INTERVIEWCHECK_PRODUCTION",
    ):
        monkeypatch.delenv(key, raising=False)
    dist_dir = tmp_path / "web_out"
    dist_dir.mkdir()
    (dist_dir / "index.html").write_text("<!doctype html><html></html>", encoding="utf-8")
    monkeypatch.setattr(health_probes, "DIST", dist_dir)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        yield client, tmp_path, dist_dir


def test_healthz_and_readyz_healthy_local_and_embedded(probe_env, monkeypatch):
    client, tmp_path, _ = probe_env
    assert client.get("/api/health").json() == {"ok": True}

    hz = client.get("/api/healthz")
    assert hz.status_code == 200 and hz.json() == {"ok": True, "service": "interviewcheck-api"}
    _assert_security_headers(hz.headers)

    rz_local = client.get("/api/readyz")
    assert rz_local.status_code == 200
    assert _assert_minimized_readyz(rz_local, tmp_path) == {
        "ok": True,
        "checks": {"review_db": "ok", "access_db": "skipped", "secret_box": "ok", "web_bundle": "ok"},
    }

    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    rz_missing_access = client.get("/api/readyz")
    assert rz_missing_access.status_code == 503
    assert not account_db.database().exists()
    assert _assert_minimized_readyz(rz_missing_access, tmp_path)["checks"]["access_db"] == "error"

    account_db.check_database()
    rz_emb = client.get("/api/readyz")
    assert rz_emb.status_code == 200
    assert _assert_minimized_readyz(rz_emb, tmp_path) == {
        "ok": True,
        "checks": {"review_db": "ok", "access_db": "ok", "secret_box": "ok", "web_bundle": "ok"},
    }


def test_readyz_degraded_web_bundle_and_secret_box_permissions(probe_env, monkeypatch):
    client, tmp_path, dist_dir = probe_env

    (dist_dir / "index.html").unlink()
    missing_bundle = client.get("/api/readyz")
    assert missing_bundle.status_code == 503
    assert _assert_minimized_readyz(missing_bundle, tmp_path) == {
        "ok": False,
        "checks": {"review_db": "ok", "access_db": "skipped", "secret_box": "ok", "web_bundle": "missing"},
    }
    next_server = dist_dir.parent / ".next-server"
    next_server.mkdir()
    (next_server / "routes-manifest.json").write_text('{"version":3}', encoding="utf-8")
    next_bundle = client.get("/api/readyz")
    assert next_bundle.status_code == 200
    assert _assert_minimized_readyz(next_bundle, tmp_path)["checks"]["web_bundle"] == "ok"
    (next_server / "routes-manifest.json").unlink()
    next_server.rmdir()
    (dist_dir / "index.html").write_text("<!doctype html><html></html>", encoding="utf-8")

    missing_key_dir = tmp_path / "uncreated_key_dir"
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_FILE", str(missing_key_dir / ".model_secret.key"))
    missing_key_res = client.get("/api/readyz")
    assert missing_key_res.status_code == 503
    assert not missing_key_dir.exists()
    assert _assert_minimized_readyz(missing_key_res, tmp_path)["checks"]["secret_box"] == "error"
    monkeypatch.delenv("INTERVIEWCHECK_MODEL_SECRET_FILE", raising=False)

    key_file = tmp_path / ".model_secret.key"
    assert key_file.is_file()
    if os.name != "nt":
        key_file.chmod(0o644)
        bad_perm = client.get("/api/readyz")
        assert bad_perm.status_code == 503
        assert _assert_minimized_readyz(bad_perm, tmp_path)["checks"]["secret_box"] == "error"
        key_file.chmod(0o600)
        assert client.get("/api/readyz").status_code == 200

    key_file.write_bytes(b"not-valid-base64!")
    bad_key = client.get("/api/readyz")
    assert bad_key.status_code == 503
    assert _assert_minimized_readyz(bad_key, tmp_path)["checks"]["secret_box"] == "error"

    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "fixture-secret-key")
    monkeypatch.setattr(secret_box, "active_key_id", lambda: "deadbeef", raising=False)
    assert client.get("/api/readyz").status_code == 200
    monkeypatch.setattr(secret_box, "active_key_id", lambda: (_ for _ in ()).throw(RuntimeError(str(tmp_path))), raising=False)
    err_active = client.get("/api/readyz")
    assert err_active.status_code == 503
    assert _assert_minimized_readyz(err_active, tmp_path)["checks"]["secret_box"] == "error"


def test_readyz_degraded_review_db_and_access_db(probe_env, monkeypatch):
    client, tmp_path, _ = probe_env
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "fixture-secret-key")

    missing_path = tmp_path / "does_not_exist.sqlite3"
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(missing_path))
    res_missing = client.get("/api/readyz")
    assert res_missing.status_code == 503
    assert _assert_minimized_readyz(res_missing, tmp_path)["checks"]["review_db"] == "error"
    assert not missing_path.exists()

    no_wal = tmp_path / "nowal.sqlite3"
    store.initialize(no_wal)
    with closing(sqlite3.connect(no_wal)) as db:
        db.execute("PRAGMA journal_mode=DELETE")
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(no_wal))
    res_nowal = client.get("/api/readyz")
    assert res_nowal.status_code == 503
    assert _assert_minimized_readyz(res_nowal, tmp_path)["checks"]["review_db"] == "error"

    partial_db = tmp_path / "partial.sqlite3"
    with closing(sqlite3.connect(partial_db)) as db:
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("CREATE TABLE sessions(id TEXT PRIMARY KEY)")
        db.execute("CREATE TABLE roles(id TEXT PRIMARY KEY)")
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(partial_db))
    res_partial = client.get("/api/readyz")
    assert res_partial.status_code == 503
    assert _assert_minimized_readyz(res_partial, tmp_path)["checks"]["review_db"] == "error"

    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    missing_access = tmp_path / "missing_access.sqlite3"
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(missing_access))
    res_no_access = client.get("/api/readyz")
    assert res_no_access.status_code == 503
    assert not missing_access.exists()
    assert _assert_minimized_readyz(res_no_access, tmp_path)["checks"]["access_db"] == "error"

    bad_access = tmp_path / "bad_access.sqlite3"
    with closing(sqlite3.connect(bad_access)) as db:
        db.execute("PRAGMA journal_mode=WAL")
        db.execute(f"PRAGMA user_version={account_db.VERSION}")
        db.execute("CREATE TABLE dummy(id TEXT PRIMARY KEY)")
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(bad_access))
    res_access = client.get("/api/readyz")
    assert res_access.status_code == 503
    assert _assert_minimized_readyz(res_access, tmp_path)["checks"]["access_db"] == "error"


def test_cross_wave_admin_auth_and_entitlement_gates(probe_env, monkeypatch):
    client, _, _ = probe_env
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    account_db.check_database()
    assert client.get("/api/readyz").status_code == 200

    _, tok_user = _seed_user(role="user")
    _, tok_disabled = _seed_user(role="admin", disabled=True)
    _, tok_admin = _seed_user(role="admin")

    admin_gets = (
        "/api/admin/models",
        "/api/admin/models/telemetry",
        "/api/integrations/admin/audit",
        "/api/integrations/admin/audit/export",
        "/api/integrations/admin/users",
    )
    model_body = {"slug": "s1", "display_name": "M", "provider": "openai", "capability": "reference", "model_id": "gpt-4o", "apiKey": "sk-test-123456"}
    admin_mutations = (("POST", "/api/admin/models", model_body), ("POST", f"/api/admin/models/{uuid4()}/probe", None), ("DELETE", f"/api/admin/models/{uuid4()}", None))

    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as caller:
        for path in admin_gets:
            r = caller.get(path)
            assert r.status_code == 401 and _assert_security_headers(r.headers) is None
        for method, path, body in admin_mutations:
            r = caller.request(method, path, json=body)
            assert r.status_code == 401 and _assert_security_headers(r.headers) is None
        for path in ("/api/roles/analytics", f"/api/roles/{uuid4()}/calibration", f"/api/roles/{uuid4()}/versions", "/api/backups/workspace"):
            r = caller.get(path)
            assert r.status_code == 401 and _assert_security_headers(r.headers) is None

        caller.cookies.set(access.COOKIE, tok_user)
        for path in admin_gets:
            assert caller.get(path).status_code == 403
        for method, path, body in admin_mutations:
            assert caller.request(method, path, json=body).status_code == 403

        caller.cookies.set(access.COOKIE, tok_disabled)
        for path in admin_gets:
            assert caller.get(path).status_code == 401

        caller.cookies.set(access.COOKIE, tok_admin)
        for path in admin_gets:
            r = caller.get(path)
            assert r.status_code == 200 and _assert_security_headers(r.headers) is None


def test_cross_wave_csrf_headers_and_hsts_across_m8_m12_health(probe_env, monkeypatch):
    client, _, _ = probe_env
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    _, tok_admin = _seed_user(role="admin")

    client.cookies.set(access.COOKIE, tok_admin)
    role = client.post("/api/roles", json={"name": "Security Audit Role", "questions": ["Q1?"]})
    assert role.status_code == 201
    role_data = role.json()
    _assert_security_headers(role.headers)

    for path in ("/api/roles/analytics", f"/api/roles/{role_data['id']}/versions", "/api/backups/workspace"):
        resp = client.get(path)
        assert resp.status_code == 200
        _assert_security_headers(resp.headers)

    with TestClient(app, base_url="http://127.0.0.1") as raw:
        raw.cookies.set(access.COOKIE, tok_admin)
        mutating_cases = (
            ("POST", "/api/admin/models", {"slug": "csrf-m", "display_name": "M", "provider": "openai", "capability": "reference", "model_id": "gpt-4o", "apiKey": "sk-test-123456"}),
            ("POST", "/api/roles", {"name": "Blocked", "questions": ["Q?"]}),
            ("POST", f"/api/roles/{role_data['id']}/versions/1/restore", {"expected_version": role_data["version"]}),
            ("POST", "/api/backups/preview", {"format": "interviewcheck.workspace", "version": 1, "roles": [], "sessions": []}),
            ("POST", "/api/backups/restore", {"format": "interviewcheck.workspace", "version": 1, "roles": [], "sessions": []}),
        )
        for method, path, payload in mutating_cases:
            no_hdr = raw.request(method, path, json=payload)
            assert no_hdr.status_code == 403 and _assert_security_headers(no_hdr.headers) is None
            bad_origin = raw.request(method, path, json=payload, headers={"X-InterviewCheck": "1", "Origin": "https://evil.example"})
            assert bad_origin.status_code == 403 and _assert_security_headers(bad_origin.headers) is None

    monkeypatch.setenv("INTERVIEWCHECK_PUBLIC_ORIGIN", "https://review.example.test")
    with TestClient(app, base_url="https://127.0.0.1", headers={"X-Forwarded-Host": "review.example.test"}) as pub:
        for path in ("/api/healthz", "/api/readyz"):
            r = pub.get(path)
            assert r.status_code == 200
            _assert_security_headers(r.headers, expect_hsts=True)
