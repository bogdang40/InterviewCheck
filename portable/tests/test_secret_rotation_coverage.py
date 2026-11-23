"""Key rotation re-encrypts TOTP and alert signing secrets and can be rerun after a partial failure."""
import sqlite3
from uuid import uuid4

import pytest

from api import account_db, key_rotation, model_registry, secret_box, store, totp_service

TOTP_SECRET = "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"
ALERT_SECRET = "whsec-rotation-coverage-1234"
MODEL_SECRET = "sk-rotation-coverage-5678"
NOW_MS = 1_760_000_010_000


@pytest.fixture
def stores(tmp_path, monkeypatch):
    review = tmp_path / "review.sqlite3"
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(review))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "coverage-old-key")
    for key in ("INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS", "INTERVIEWCHECK_MODEL_SECRET_FILE"):
        monkeypatch.delenv(key, raising=False)
    store.initialize(review)
    return review


def _seed_secrets() -> dict[str, str]:
    ids = {"model": str(uuid4()), "rule": str(uuid4()), "user": str(uuid4())}
    ts, now = account_db.now(), store.timestamp()
    with store.connection(write=True) as db:
        model_registry.create_model(
            db, model_uuid=ids["model"], slug="cov", display_name="Coverage", provider="openai", capability="reference",
            model_id="gpt-4o", endpoint=None, api_version=None, parameters={}, enabled=True, is_default=False,
            encrypted_api_key=secret_box.encrypt_secret(MODEL_SECRET, aad=ids["model"]), key_hint=None,
        )
        db.execute(
            "INSERT INTO alert_rules(id,name,trigger_type,threshold_value,webhook_url,encrypted_signing_secret,created_at,updated_at) "
            "VALUES (?,?,?,?,?,?,?,?)",
            (ids["rule"], "Errors", "model_error_streak", 3, "https://hooks.example.invalid/x",
             secret_box.encrypt_secret(ALERT_SECRET, aad=ids["rule"], envelope="v2"), now, now),
        )
    with account_db.connection(write=True) as db:
        db.execute("INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,0,?,?)",
                   (ids["user"], "totp@example.invalid", account_db.DECOY, "user", ts, ts))
        db.execute("INSERT INTO user_totp(user_id,secret_enc,enabled,verified_at,created_at) VALUES (?,?,1,?,?)",
                   (ids["user"], secret_box.encrypt_secret(TOTP_SECRET, aad=ids["user"]), ts, ts))
    return ids


def _switch_key(monkeypatch, *, keep_previous=True):
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "coverage-new-key")
    if keep_previous:
        monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS", "coverage-old-key")


def _assert_readable_without_previous(monkeypatch, ids):
    monkeypatch.delenv("INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS", raising=False)
    with store.connection() as db:
        rule = db.execute("SELECT encrypted_signing_secret FROM alert_rules WHERE id=?", (ids["rule"],)).fetchone()[0]
        model = db.execute("SELECT encrypted_api_key FROM connected_models WHERE id=?", (ids["model"],)).fetchone()[0]
        assert secret_box.decrypt_secret(rule, aad=ids["rule"]) == ALERT_SECRET
        assert secret_box.decrypt_secret(model, aad=ids["model"]) == MODEL_SECRET
        status = key_rotation.key_status(db)
    assert status["needs_rotation_count"] == 0 and status["current_v2_count"] == status["total_with_keys"] == 3
    with account_db.connection(write=True) as db:
        code = totp_service.generate_totp_code(TOTP_SECRET, NOW_MS)
        assert totp_service.verify_login_factor(db, ids["user"], code, NOW_MS) == "totp"


class _FailingCommit:
    def __init__(self, inner: sqlite3.Connection):
        self._inner = inner

    def __getattr__(self, name):
        return getattr(self._inner, name)

    def commit(self):
        raise sqlite3.OperationalError("simulated review commit failure")


def test_rotation_covers_totp_and_alert_secrets_and_status_reaches_zero(stores, monkeypatch):
    ids = _seed_secrets()
    _switch_key(monkeypatch)
    with store.connection() as db:
        before = key_rotation.key_status(db)
    assert before["needs_rotation_count"] == 3
    assert {name: t["needs_rotation_count"] for name, t in before["tables"].items()} == {
        "connected_models": 1, "alert_rules": 1, "user_totp": 1,
    }
    with store.connection(write=True) as db:
        dry = key_rotation.rotate_database_secrets(db, dry_run=True)
    assert dry.rotated_count == 3
    with store.connection() as db:
        assert key_rotation.key_status(db)["needs_rotation_count"] == 3
    with store.connection(write=True) as db:
        report = key_rotation.rotate_database_secrets(db)
    assert report.rotated_count == 3 and report.tables["user_totp"]["rotated_count"] == 1
    _assert_readable_without_previous(monkeypatch, ids)


def test_unreadable_row_aborts_every_table_before_writing(stores, monkeypatch):
    ids = _seed_secrets()
    with store.connection(write=True) as db:
        db.execute("UPDATE alert_rules SET encrypted_signing_secret='v2:deadbeef:broken' WHERE id=?", (ids["rule"],))
    with account_db.connection() as db:
        totp_before = db.execute("SELECT secret_enc FROM user_totp").fetchone()[0]
    _switch_key(monkeypatch)
    with store.connection(write=True) as db:
        with pytest.raises(secret_box.SecretBoxError):
            key_rotation.rotate_database_secrets(db)
    with account_db.connection() as db:
        assert db.execute("SELECT secret_enc FROM user_totp").fetchone()[0] == totp_before


def test_rerun_finishes_after_review_commit_fails_under_environment_key(stores, monkeypatch):
    ids = _seed_secrets()
    _switch_key(monkeypatch)
    with sqlite3.connect(stores, timeout=10) as raw:
        with pytest.raises(sqlite3.OperationalError):
            key_rotation.rotate_database_secrets(_FailingCommit(raw))
    with store.connection() as db:
        tables = key_rotation.key_status(db)["tables"]
    assert tables["user_totp"]["needs_rotation_count"] == 0 and tables["connected_models"]["needs_rotation_count"] == 1
    with store.connection(write=True) as db:
        assert key_rotation.rotate_database_secrets(db).rotated_count == 2
    _assert_readable_without_previous(monkeypatch, ids)


def test_file_key_partial_failure_keeps_old_key_for_the_rerun(stores, monkeypatch, tmp_path):
    monkeypatch.delenv("INTERVIEWCHECK_MODEL_SECRET_KEY", raising=False)
    ids = _seed_secrets()
    backup = tmp_path / ".model_secret.key.bak"
    with sqlite3.connect(stores, timeout=10) as raw:
        with pytest.raises(key_rotation.PartialRotationError, match=backup.name):
            key_rotation.rotate_database_secrets(_FailingCommit(raw), rotate_file_key=True)
    assert backup.is_file()
    assert key_rotation.main(["--db", str(stores), "--old-key-file", str(backup)]) == 0
    _assert_readable_without_previous(monkeypatch, ids)
