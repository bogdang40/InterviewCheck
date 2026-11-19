"""Tests for M13-W1 Secret Box v2 envelope, key rotation CLI, and admin rotation endpoints."""
import json
import os
import sqlite3
import stat
import subprocess
import sys
from unittest.mock import AsyncMock
from uuid import uuid4

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest

from api import access, account_db, key_rotation, model_registry, rate_limit, secret_box, ssrf_guard, store
from api.main import app


def _seed_user(*, email: str = "m13-admin@example.invalid", role: str = "admin") -> str:
    uid, ts = str(uuid4()), account_db.now()
    with account_db.connection(write=True) as db:
        db.execute(
            "INSERT INTO users(id, email, password_hash, role, disabled, created_at, updated_at) VALUES (?,?,?,?,0,?,?)",
            (uid, email, account_db.DECOY, role, ts, ts),
        )
        return account_db.issue(db, uid, "pytest")


def _insert_model(slug: str, secret: str | None, *, envelope: str = "v1") -> str:
    uid = str(uuid4())
    enc = secret_box.encrypt_secret(secret, aad=uid, envelope=envelope) if secret else None
    hint = secret_box.mask_key_hint(secret) if secret else None
    with store.connection(write=True) as db:
        model_registry.create_model(
            db, model_uuid=uid, slug=slug, display_name=f"Model {slug}", provider="openai",
            capability="reference", model_id="gpt-4o", endpoint=None, api_version=None,
            parameters={}, encrypted_api_key=enc, key_hint=hint, enabled=True, is_default=False,
        )
    return uid


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "m13-active-key-1")
    for key in (
        "INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS",
        "INTERVIEWCHECK_MODEL_SECRET_FILE",
        "INTERVIEWCHECK_ACCESS_MODE",
        "INTERVIEWCHECK_ACCESS_URL",
        "INTERVIEWCHECK_OPERATOR_EMAIL",
        "INTERVIEWCHECK_PUBLIC_ORIGIN",
    ):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])
    rate_limit.reset_all()
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def test_v1_v2_envelopes_kid_binding_and_previous_keyring(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.delenv("INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS", raising=False)
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "alpha-key-v1")

    tok_v1 = secret_box.encrypt_secret("sk-alpha-1111", aad="row-1")
    tok_v2 = secret_box.encrypt_secret("sk-alpha-2222", aad="row-1", envelope="v2")
    kid_alpha = secret_box.active_key_id()
    assert tok_v1.startswith("v1:") and secret_box.token_key_info(tok_v1) == ("v1", None)
    assert tok_v2.startswith(f"v2:{kid_alpha}:") and secret_box.token_key_info(tok_v2) == ("v2", kid_alpha)
    assert len(kid_alpha) == 8 and secret_box.key_source() == "env"
    assert secret_box.decrypt_secret(tok_v2, aad="row-1") == "sk-alpha-2222"

    # Binding check: swapping kid or AAD or malformed v2 fails cleanly.
    with pytest.raises(secret_box.SecretBoxError):
        secret_box.decrypt_secret(tok_v2, aad="row-2")
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "beta-key-v2")
    kid_beta = secret_box.active_key_id()
    swapped_kid = f"v2:{kid_beta}:" + tok_v2.split(":", 2)[2]
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS", "alpha-key-v1, gamma-key-v0 , alpha-key-v1")
    assert secret_box.previous_key_count() == 2
    assert len(secret_box.keyring()) == 3
    with pytest.raises(secret_box.SecretBoxError):
        secret_box.decrypt_secret(swapped_kid, aad="row-1")
    for bad in ("v2:not-supported", "v2:1234567:abc", "v2:ABCDEF12:abc", f"v2:{kid_beta}:", "v3:abc"):
        with pytest.raises(secret_box.SecretBoxError):
            secret_box.decrypt_secret(bad, aad="row-1")

    # Multi-key rotation decryption + reencrypt_secret into active v2 envelope.
    assert secret_box.decrypt_secret(tok_v1, aad="row-1") == "sk-alpha-1111"
    assert secret_box.decrypt_secret(tok_v2, aad="row-1") == "sk-alpha-2222"
    rotated_v2 = secret_box.reencrypt_secret(tok_v1, aad="row-1")
    assert secret_box.token_key_info(rotated_v2) == ("v2", kid_beta)
    monkeypatch.delenv("INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS", raising=False)
    assert secret_box.decrypt_secret(rotated_v2, aad="row-1") == "sk-alpha-1111"


def test_atomic_db_rotation_rollback_on_corrupt_ciphertext(env, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "old-env-key")
    m1 = _insert_model("ok-v1", "sk-secret-alpha-1111", envelope="v1")
    m2 = _insert_model("bad-v2", "sk-secret-beta-2222", envelope="v2")
    with store.connection() as db:
        before_m1 = db.execute("SELECT encrypted_api_key FROM connected_models WHERE id=?", (m1,)).fetchone()[0]
    with store.connection(write=True) as db:
        db.execute("UPDATE connected_models SET encrypted_api_key=? WHERE id=?", ("v2:deadbeef:not_valid!", m2))

    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "new-env-key")
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS", "old-env-key")
    with store.connection(write=True) as db:
        with pytest.raises(secret_box.SecretBoxError):
            key_rotation.rotate_database_secrets(db)

    # Zero partial updates: m1 still holds its original v1 ciphertext.
    with store.connection() as db:
        after_m1 = db.execute("SELECT encrypted_api_key FROM connected_models WHERE id=?", (m1,)).fetchone()[0]
    assert after_m1 == before_m1


def test_cli_dry_run_old_keys_and_atomic_file_key_rotation(tmp_path, monkeypatch):
    db_file = tmp_path / "review.sqlite3"
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(db_file))
    monkeypatch.delenv("INTERVIEWCHECK_MODEL_SECRET_KEY", raising=False)
    monkeypatch.delenv("INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS", raising=False)
    store.initialize(db_file)

    secret_a = "sk-cli-secret-alpha-1111"
    secret_b = "sk-cli-secret-beta-2222"
    m_a = _insert_model("cli-a", secret_a, envelope="v1")
    m_b = _insert_model("cli-b", secret_b, envelope="v2")
    _insert_model("cli-nokey", None)
    key_file = tmp_path / ".model_secret.key"
    old_kid = secret_box.active_key_id()
    old_file_bytes = key_file.read_bytes()

    # Dry-run with --rotate-file-key must not modify DB or key file or leak secrets.
    dry = subprocess.run(
        [sys.executable, "-m", "api.key_rotation", "--db", str(db_file), "--rotate-file-key", "--dry-run", "--json"],
        cwd=str(tmp_path.parent),
        env={**os.environ, "PYTHONPATH": str(os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))},
        capture_output=True, text=True, check=False,
    )
    assert dry.returncode == 0, dry.stderr
    dry_json = json.loads(dry.stdout)
    assert dry_json["dry_run"] is True and dry_json["rotated_file_key"] is False
    assert dry_json["total_with_keys"] == 2 and dry_json["rotated_count"] == 2
    assert key_file.read_bytes() == old_file_bytes
    assert secret_a not in dry.stdout and secret_b not in dry.stdout

    # Actual --rotate-file-key replaces .model_secret.key atomically with 0600 and no .tmp leftover.
    rot = key_rotation.main(["--db", str(db_file), "--rotate-file-key", "--json"])
    assert rot == 0
    assert not (tmp_path / ".model_secret.key.tmp").exists()
    assert key_file.read_bytes() != old_file_bytes
    if os.name != "nt":
        assert stat.S_IMODE(key_file.stat().st_mode) == 0o600
    new_kid = secret_box.active_key_id()
    assert new_kid != old_kid

    with sqlite3.connect(db_file) as db:
        rows = dict(db.execute("SELECT id, encrypted_api_key FROM connected_models").fetchall())
    assert secret_box.token_key_info(rows[m_a]) == ("v2", new_kid)
    assert secret_box.token_key_info(rows[m_b]) == ("v2", new_kid)
    assert secret_box.decrypt_secret(rows[m_a], aad=m_a) == secret_a
    assert secret_box.decrypt_secret(rows[m_b], aad=m_b) == secret_b

    # Migrate from retired file key (--old-key-file) + retired env key (--old-key-env) to new env key.
    old_backup = tmp_path / "retired.key"
    old_backup.write_bytes(key_file.read_bytes())
    old_backup.chmod(0o600)
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "retired-env-pass")
    m_c = _insert_model("cli-c", "sk-cli-secret-gamma-3333", envelope="v1")
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "final-prod-pass")
    assert key_rotation.main([
        "--db", str(db_file),
        "--old-key-file", str(old_backup),
        "--old-key-env", "retired-env-pass",
    ]) == 0
    final_kid = secret_box.active_key_id()
    with sqlite3.connect(db_file) as db:
        rows = dict(db.execute("SELECT id, encrypted_api_key FROM connected_models").fetchall())
    assert secret_box.token_key_info(rows[m_a]) == ("v2", final_kid)
    assert secret_box.token_key_info(rows[m_c]) == ("v2", final_kid)
    assert secret_box.decrypt_secret(rows[m_a], aad=m_a) == secret_a
    assert secret_box.decrypt_secret(rows[m_c], aad=m_c) == "sk-cli-secret-gamma-3333"


@pytest.mark.parametrize("mode", [None, "embedded", "remote"])
def test_admin_key_endpoints_auth_csrf_and_no_raw_key_body(env, monkeypatch, mode):
    if mode == "embedded":
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    elif mode == "remote":
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://accounts.example.invalid")
        monkeypatch.setattr(access, "upstream", AsyncMock(side_effect=HTTPException(401, "Expired")))

    assert env.get("/api/admin/models/key-status").status_code == 401
    assert env.post("/api/admin/models/rotate-keys").status_code == 401
    forged = {"Cookie": f"{access.COOKIE}=mm_forged_cookie_value_12345678901234567890"}
    assert env.get("/api/admin/models/key-status", headers=forged).status_code == 401
    assert env.post("/api/admin/models/rotate-keys", headers=forged).status_code == 401

    if mode == "remote":
        monkeypatch.setattr(access, "upstream", AsyncMock(return_value={
            "user": {"id": str(uuid4()), "email": "u@example.invalid", "role": "user", "disabled": False},
            "entitlement": {"active": True},
        }))
        user_hdr = {"Cookie": f"{access.COOKIE}=remote-user"}
    else:
        user_hdr = {"Cookie": f"{access.COOKIE}={_seed_user(email='u@example.invalid', role='user')}"}
    assert env.get("/api/admin/models/key-status", headers=user_hdr).status_code == 403
    assert env.post("/api/admin/models/rotate-keys", headers=user_hdr).status_code == 403

    if mode != "remote":
        admin_tok = _seed_user(email="admin@example.invalid", role="admin")
        with TestClient(app, base_url="http://127.0.0.1") as raw:
            raw.cookies.set(access.COOKIE, admin_tok)
            assert raw.post("/api/admin/models/rotate-keys").status_code == 403
        env.cookies.set(access.COOKIE, admin_tok)
        assert env.post("/api/admin/models/rotate-keys", json={"apiKey": "sk-forbidden-in-body"}).status_code == 422
        assert env.post("/api/admin/models/rotate-keys", json={"previous_keys": ["old"]}).status_code == 422


def test_admin_key_status_rotate_keys_audit_and_permission_error(env, tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "api-key-old")
    s1, s2 = "sk-api-secret-one-1111", "sk-api-secret-two-2222"
    m1 = _insert_model("api-m1", s1, envelope="v1")
    m2 = _insert_model("api-m2", s2, envelope="v2")
    _insert_model("api-m3", None)

    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "api-key-new")
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS", "api-key-old")
    env.cookies.set(access.COOKIE, _seed_user())

    st0 = env.get("/api/admin/models/key-status")
    assert st0.status_code == 200
    b0 = st0.json()
    assert b0["key_source"] == "env" and b0["previous_keys_configured"] == 1
    assert b0["total_with_keys"] == 2 and b0["current_v2_count"] == 0 and b0["needs_rotation_count"] == 2

    dry = env.post("/api/admin/models/rotate-keys", json={"dry_run": True})
    assert dry.status_code == 200 and dry.json()["dry_run"] is True and dry.json()["rotated_count"] == 2
    assert env.get("/api/admin/models/key-status").json()["needs_rotation_count"] == 2

    rot = env.post("/api/admin/models/rotate-keys")
    assert rot.status_code == 200
    rb = rot.json()
    assert rb["rotated_count"] == 2 and rb["already_current_count"] == 0 and rb["dry_run"] is False
    assert s1 not in rot.text and s2 not in rot.text and "api-key-new" not in rot.text and "api-key-old" not in rot.text

    st1 = env.get("/api/admin/models/key-status").json()
    assert st1["current_v2_count"] == 2 and st1["needs_rotation_count"] == 0

    # Idempotent second rotation rotates 0 rows.
    rot2 = env.post("/api/admin/models/rotate-keys").json()
    assert rot2["rotated_count"] == 0 and rot2["already_current_count"] == 2

    with account_db.connection() as adb:
        audits = adb.execute("SELECT action, details FROM audit_log WHERE action='admin.model.rotate_keys'").fetchall()
    assert len(audits) == 2
    assert s1 not in (audits[0]["details"] or "") and "api-key-old" not in (audits[0]["details"] or "")

    # File permission error (0644) on key-status surfaces 503 without leaking path.
    if os.name != "nt":
        monkeypatch.delenv("INTERVIEWCHECK_MODEL_SECRET_KEY", raising=False)
        bad_file = tmp_path / ".model_secret.key"
        bad_file.write_bytes(b"A" * 44)
        bad_file.chmod(0o644)
        bad_res = env.get("/api/admin/models/key-status")
        assert bad_res.status_code == 503
        assert str(tmp_path) not in bad_res.text


def test_admin_create_and_patch_store_v2_envelopes(env, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "crud-v2-master-key")
    kid = secret_box.active_key_id()
    env.cookies.set(access.COOKIE, _seed_user(email="crud-v2@example.invalid"))

    create_res = env.post("/api/admin/models", json={
        "slug": "crud-v2-openai",
        "display_name": "CRUD V2 OpenAI",
        "provider": "openai",
        "capability": "reference",
        "model_id": "gpt-4o",
        "apiKey": "sk-create-v2-secret-1111",
    })
    assert create_res.status_code == 201
    model_id = create_res.json()["model"]["id"]

    with store.connection() as db:
        enc_create = db.execute("SELECT encrypted_api_key FROM connected_models WHERE id=?", (model_id,)).fetchone()[0]
    assert enc_create.startswith(f"v2:{kid}:")
    assert secret_box.decrypt_secret(enc_create, aad=model_id) == "sk-create-v2-secret-1111"
    st_create = env.get("/api/admin/models/key-status").json()
    assert st_create["current_v2_count"] == 1 and st_create["needs_rotation_count"] == 0

    patch_res = env.patch(f"/api/admin/models/{model_id}", json={"apiKey": "sk-patch-v2-secret-2222"})
    assert patch_res.status_code == 200
    with store.connection() as db:
        enc_patch = db.execute("SELECT encrypted_api_key FROM connected_models WHERE id=?", (model_id,)).fetchone()[0]
    assert enc_patch.startswith(f"v2:{kid}:") and enc_patch != enc_create
    assert secret_box.decrypt_secret(enc_patch, aad=model_id) == "sk-patch-v2-secret-2222"
    st_patch = env.get("/api/admin/models/key-status").json()
    assert st_patch["current_v2_count"] == 1 and st_patch["needs_rotation_count"] == 0


def test_rotate_file_key_atomicity_and_old_key_env_resolution(tmp_path, monkeypatch):
    db_file = tmp_path / "review.sqlite3"
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(db_file))
    monkeypatch.delenv("INTERVIEWCHECK_MODEL_SECRET_KEY", raising=False)
    monkeypatch.delenv("INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS", raising=False)
    store.initialize(db_file)

    secret_val = "sk-atomic-file-rot-1234"
    mid = _insert_model("atomic-m1", secret_val, envelope="v2")
    key_file = tmp_path / ".model_secret.key"
    orig_bytes = key_file.read_bytes()

    # (a) os.replace PermissionError leaves DB & .model_secret.key intact and cleans temp files.
    def _deny_replace(src, dst):
        raise PermissionError("simulated os.replace failure")

    with monkeypatch.context() as mp:
        mp.setattr(os, "replace", _deny_replace)
        with sqlite3.connect(db_file, timeout=10) as db:
            with pytest.raises(PermissionError):
                key_rotation.rotate_database_secrets(db, rotate_file_key=True)
    assert key_file.read_bytes() == orig_bytes
    assert not (tmp_path / ".model_secret.key.tmp").exists()
    assert not (tmp_path / ".model_secret.key.bak").exists()
    with sqlite3.connect(db_file) as db:
        enc_after_perm = db.execute("SELECT encrypted_api_key FROM connected_models WHERE id=?", (mid,)).fetchone()[0]
    assert secret_box.decrypt_secret(enc_after_perm, aad=mid) == secret_val

    # (b) db.commit() failure restores .model_secret.key from .bak and rolls back DB.
    class _FailingCommitConn:
        def __init__(self, inner: sqlite3.Connection):
            self._inner = inner

        def __getattr__(self, name: str):
            return getattr(self._inner, name)

        def commit(self) -> None:
            raise sqlite3.OperationalError("simulated commit failure")

    with sqlite3.connect(db_file, timeout=10) as raw_db:
        proxy_db = _FailingCommitConn(raw_db)
        with pytest.raises(sqlite3.OperationalError):
            key_rotation.rotate_database_secrets(proxy_db, rotate_file_key=True)
    assert key_file.read_bytes() == orig_bytes
    assert not (tmp_path / ".model_secret.key.tmp").exists()
    assert not (tmp_path / ".model_secret.key.bak").exists()
    with sqlite3.connect(db_file) as db:
        enc_after_commit_err = db.execute("SELECT encrypted_api_key FROM connected_models WHERE id=?", (mid,)).fetchone()[0]
    assert secret_box.decrypt_secret(enc_after_commit_err, aad=mid) == secret_val

    # (c) was_in_tx=True with rotate_file_key=True is rejected.
    with sqlite3.connect(db_file, timeout=10) as db:
        db.execute("BEGIN IMMEDIATE")
        with pytest.raises(secret_box.SecretBoxError, match="transaction"):
            key_rotation.rotate_database_secrets(db, rotate_file_key=True)
        db.rollback()

    # (d) --old-key-env OLD_SECRET_VAR_NAME reads from os.environ and rejects missing var names.
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "env_secret_alpha")
    m_env = _insert_model("env-var-m", "sk-env-var-secret-9999", envelope="v2")
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "env_secret_beta")
    assert key_rotation.main(["--db", str(db_file), "--old-key-env", "MISSING_OLD_SECRET_VAR"]) == 1
    monkeypatch.setenv("OLD_SECRET_VAR_NAME", "env_secret_alpha")
    old_file = tmp_path / "old_file.key"
    old_file.write_bytes(orig_bytes)
    old_file.chmod(0o600)
    assert key_rotation.main([
        "--db", str(db_file),
        "--old-key-file", str(old_file),
        "--old-key-env", "OLD_SECRET_VAR_NAME",
    ]) == 0
    beta_kid = secret_box.active_key_id()
    with sqlite3.connect(db_file) as db:
        rows = dict(db.execute("SELECT id, encrypted_api_key FROM connected_models").fetchall())
    assert secret_box.token_key_info(rows[m_env]) == ("v2", beta_kid)
    assert secret_box.decrypt_secret(rows[m_env], aad=m_env) == "sk-env-var-secret-9999"

    # OSError during key file creation raises SecretBoxError without leaking paths.
    monkeypatch.delenv("INTERVIEWCHECK_MODEL_SECRET_KEY", raising=False)
    monkeypatch.setattr(os, "open", lambda *a, **kw: (_ for _ in ()).throw(PermissionError(str(tmp_path))))
    with pytest.raises(secret_box.SecretBoxError, match="initialized"):
        secret_box._load_or_create_file_key(tmp_path / "never_created.key")

