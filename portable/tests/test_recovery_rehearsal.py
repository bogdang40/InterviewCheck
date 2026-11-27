"""Rehearse extracted copies using only explicitly supplied recovery keys."""
import base64
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys

import pytest

from api import account_db, model_registry, recovery_rehearsal, recovery_snapshot, secret_box, store

ROOT = Path(__file__).resolve().parents[1]
FILE_MASTER = bytes(range(32))
ENV_MASTER = "synthetic archived passphrase"
MODEL_ID = "fixture-private-model-id"
RULE_ID = "fixture-private-rule-id"
USER_ID = "fixture-private-user-id"


@pytest.fixture
def copies(tmp_path, monkeypatch):
    live = tmp_path / "live"
    live.mkdir()
    extracted = tmp_path / "extracted ? #"
    extracted.mkdir()
    review, access = [live / name for name in ("review.sqlite3", "access.sqlite3")]
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(review))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(access))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", ENV_MASTER)
    monkeypatch.setenv("RECOVERED_PREVIOUS", ENV_MASTER)
    store.initialize(review)
    with store.connection(write=True) as db:
        model_registry.create_model(
            db, model_uuid=MODEL_ID, slug="example", display_name="Private label", provider="openai",
            capability="reference", model_id="private-deployment", endpoint=None, api_version=None,
            parameters={}, enabled=True, is_default=False,
            encrypted_api_key=secret_box.encrypt_with_master("private-model-plaintext", FILE_MASTER,
                                                            aad=MODEL_ID, envelope="v2"), key_hint=None,
        )
        db.execute("""INSERT INTO alert_rules
            (id,name,trigger_type,threshold_value,webhook_url,encrypted_signing_secret,created_at,updated_at)
            VALUES (?,?,?,2,?,?,?,?)""",
                   (RULE_ID, "Private alert", "model_error_streak", "https://example.invalid/secret-path",
                    secret_box.encrypt_secret("private-alert-plaintext", aad=RULE_ID), store.timestamp(), store.timestamp()))
    with account_db.connection(write=True) as db:
        db.execute("INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,'user',0,1,1)",
                   (USER_ID, "private@example.invalid", account_db.DECOY))
        db.execute("INSERT INTO user_totp(user_id,secret_enc,enabled,created_at) VALUES (?,?,1,1)", (
            USER_ID, secret_box.encrypt_with_master("JBSWY3DPEHPK3PXP", FILE_MASTER, aad=USER_ID)))
    for source in (review, access):
        with closing(sqlite3.connect(source)) as src, closing(sqlite3.connect(extracted / source.name)) as dst:
            src.backup(dst)
    key_file = tmp_path / "private-vault-entry"
    key_file.write_bytes(base64.urlsafe_b64encode(FILE_MASTER))
    key_file.chmod(0o600)
    return extracted / review.name, extracted / access.name, key_file


def _args(copies):
    review, access, key_file = copies
    return ["--review-db", str(review), "--access-db", str(access), "--key-file", str(key_file), "--json"]


def _run(*args):
    return subprocess.run([sys.executable, "-m", "api.recovery_rehearsal", *args], cwd=ROOT,
                          capture_output=True, text=True, timeout=30, check=False)


def _hashes(directory):
    return {p.name: hashlib.sha256(p.read_bytes()).digest() for p in directory.iterdir()}


def test_packaged_entry_verifies_both_snapshots_with_only_supplied_keys(copies, tmp_path, monkeypatch):
    review, access, key = copies
    # The ambient configuration has the right retained passphrase. It must not help a partial recovery.
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS", ENV_MASTER)
    would_create = tmp_path / "unexpected" / ".model_secret.key"
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_FILE", str(would_create))
    before = _hashes(review.parent)
    partial = _run(*_args(copies))
    assert partial.returncode == 1 and not partial.stderr
    r = json.loads(partial.stdout)
    assert r["databases"]["review"]["tables"]["alert_rules"] == {"encrypted": 1, "verified": 0, "failed": 1, "missing_required": 0}
    assert r["databases"]["access"]["tables"]["user_totp"]["verified"] == 1

    ok = _run(*_args(copies), "--key-env", "RECOVERED_PREVIOUS")
    assert ok.returncode == 0 and not ok.stderr
    report = json.loads(ok.stdout)
    assert report["version"] == 1 and report["status"] == "verified"
    assert report["databases"]["review"]["tables"]["connected_models"]["verified"] == 1
    assert report["databases"]["review"]["tables"]["alert_rules"]["verified"] == 1
    for value in (MODEL_ID, RULE_ID, USER_ID, ENV_MASTER, "private-vault-entry", "private@example.invalid",
                  "private-model-plaintext", "JBSWY3DPEHPK3PXP", key.read_text(), str(access), "private-deployment"):
        assert value not in ok.stdout + partial.stdout
    assert before == _hashes(review.parent)
    assert not would_create.parent.exists()


def test_empty_snapshots_leave_custody_unverified(copies, capsys):
    review, access, _ = copies
    with closing(sqlite3.connect(review)) as db, db:
        db.execute("UPDATE connected_models SET provider='openai_compatible', encrypted_api_key=NULL")
        db.execute("UPDATE alert_rules SET encrypted_signing_secret=NULL")
    with closing(sqlite3.connect(access)) as db, db:
        db.execute("DELETE FROM user_totp")
    assert recovery_rehearsal.main(_args(copies)) == 3
    report = json.loads(capsys.readouterr().out)
    assert report["status"] == "no_encrypted_records"
    assert report["databases"]["review"]["status"] == "checked"
    assert report["databases"]["access"]["tables"]["user_totp"]["encrypted"] == 0


def test_broken_totp_binding_and_missing_alerts_are_reported_independently(copies):
    review, access, key = copies
    with closing(sqlite3.connect(access)) as db, db:
        db.execute("UPDATE user_totp SET secret_enc=?", (secret_box.encrypt_secret("private-totp", aad="another-user"),))
    with closing(sqlite3.connect(review)) as db, db:
        db.execute("DROP TABLE alert_rules")
    report = recovery_rehearsal.rehearse(review, access, [key], ["RECOVERED_PREVIOUS"])
    assert report["status"] == "failed"
    assert report["databases"]["review"] == {"status": "schema_mismatch"}
    assert report["databases"]["access"]["tables"]["user_totp"]["failed"] == 1


def test_rejects_non_snapshot_inputs_and_unsupported_version(copies, tmp_path):
    review, access, key = copies
    orphan = tmp_path / "absent"
    report = recovery_rehearsal.rehearse(orphan, access, [key], [])
    assert report["databases"]["review"]["status"] == "snapshot_missing" and not orphan.exists()
    assert recovery_rehearsal.rehearse(review, review, [key], [])["error"] == "same_snapshot"
    with closing(sqlite3.connect(access)) as db, db:
        db.execute("PRAGMA user_version=99")
    sidecar = Path(str(review) + "-wal")
    sidecar.write_bytes(b"unexpected")
    report = recovery_rehearsal.rehearse(review, access, [key], [])
    assert report["databases"]["review"]["status"] == "snapshot_has_sidecar"
    assert report["databases"]["access"]["status"] == "unsupported_access_version"
    assert sidecar.read_bytes() == b"unexpected"


def test_missing_identity_constraint_and_foreign_key_break_receipt(copies):
    review, access, key = copies
    with closing(sqlite3.connect(review)) as db, db:
        db.execute("ALTER TABLE alert_rules RENAME TO previous_alert_rules")
        db.execute("CREATE TABLE alert_rules AS SELECT * FROM previous_alert_rules")
    with closing(sqlite3.connect(access)) as db, db:
        db.execute("UPDATE user_totp SET user_id='orphan'")
    report = recovery_rehearsal.rehearse(review, access, [key], ["RECOVERED_PREVIOUS"])
    assert report["databases"]["review"] == {"status": "schema_mismatch"}
    assert report["databases"]["access"] == {"status": "foreign_keys_failed"}


def test_snapshot_symlink_and_dangling_sidecar_are_rejected(copies, tmp_path):
    review, access, key = copies
    link = tmp_path / "linked"
    sidecar = Path(str(review) + "-shm")
    try:
        link.symlink_to(review)
        sidecar.symlink_to(tmp_path / "missing-target")
    except OSError:
        pytest.skip("Creating symlinks requires OS support.")
    assert recovery_rehearsal.rehearse(link, access, [key], [])["databases"]["review"]["status"] == "snapshot_not_regular"
    result = recovery_rehearsal.rehearse(review, access, [key], [])
    assert result["databases"]["review"]["status"] == "snapshot_has_sidecar"


def test_replacing_a_snapshot_during_check_invalidates_its_counts(copies, tmp_path, monkeypatch):
    review, access, key = copies
    original_identity = recovery_snapshot._identity
    calls = 0

    def replace_after_read(path):
        nonlocal calls
        if path == review:
            calls += 1
            if calls == 2:
                replacement = tmp_path / "replacement"
                replacement.write_bytes(review.read_bytes())
                replacement.replace(review)
        return original_identity(path)

    monkeypatch.setattr(recovery_snapshot, "_identity", replace_after_read)
    report = recovery_rehearsal.rehearse(review, access, [key], ["RECOVERED_PREVIOUS"])
    assert report["status"] == "failed" and report["databases"]["review"] == {"status": "snapshot_changed"}


@pytest.mark.parametrize("key_input", ["missing", "oversized", "invalid", "wide_permissions", "bad_variable"])
def test_invalid_key_sources_emit_fixed_errors_without_reading_databases(copies, tmp_path, key_input):
    review, access, key = copies
    names = []
    if key_input == "missing":
        key = tmp_path / "missing-key"
    elif key_input == "oversized":
        key.write_bytes(b"x" * 8192)
    elif key_input == "invalid":
        key.write_bytes(b"not a recovery key")
    elif key_input == "bad_variable":
        names = ["don't-print-this!"]
    else:
        if os.name == "nt":
            pytest.skip("POSIX permission bits")
        key.chmod(0o644)
    report = recovery_rehearsal.rehearse(review, access, [key], names)
    assert report["error"] == "key_source_unavailable"
    assert report["databases"]["review"]["status"] == "not_checked"


def test_cli_never_echoes_unknown_argument_values():
    typo = _run("--argument-that-contains-sensitive-material")
    assert typo.returncode == 2 and "sensitive-material" not in typo.stderr


def test_missing_ambient_key_is_never_created(copies, tmp_path, monkeypatch):
    for name in ("INTERVIEWCHECK_MODEL_SECRET_KEY", "INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS"):
        monkeypatch.delenv(name, raising=False)
    ambient = tmp_path / "ambient" / ".model_secret.key"
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_FILE", str(ambient))
    reply = _run(*_args(copies), "--key-env", "RECOVERED_PREVIOUS")
    assert reply.returncode == 0 and not ambient.parent.exists()


def test_paired_hashes_reject_unrelated_empty_access_store(copies, tmp_path, monkeypatch):
    review, access, key = copies
    pins = [hashlib.sha256(path.read_bytes()).hexdigest() for path in (review, access)]
    options = ["--review-sha256", pins[0], "--access-sha256", pins[1]]
    original = _run(*_args(copies), "--key-env", "RECOVERED_PREVIOUS", *options)
    assert original.returncode == 0 and json.loads(original.stdout)["pair_check"] == "matched"
    empty = tmp_path / "other-access.sqlite3"
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(empty))
    with account_db.connection():
        pass
    args = _args((review, empty, key)) + ["--key-env", "RECOVERED_PREVIOUS"]
    swapped = _run(*args, *options)
    assert swapped.returncode == 1
    report = json.loads(swapped.stdout)
    assert report["pair_check"] == "unverified" and report["databases"]["access"]["status"] == "snapshot_digest_mismatch"
    unpinned = _run(*args)
    assert unpinned.returncode == 0 and json.loads(unpinned.stdout)["pair_check"] == "not_requested"
    assert _run(*args, "--access-sha256", pins[1]).returncode == 2


def test_authenticated_invalid_totp_seed_fails_offline_check(copies):
    review, access, key = copies
    with closing(sqlite3.connect(access)) as db, db:
        db.execute("UPDATE user_totp SET secret_enc=?", (secret_box.encrypt_with_master(
            "invalid-seed!", FILE_MASTER, aad=USER_ID),))
    report = recovery_rehearsal.rehearse(review, access, [key], ["RECOVERED_PREVIOUS"])
    assert report["status"] == "failed" and report["databases"]["access"]["tables"]["user_totp"]["failed"] == 1


def test_access_requires_replay_state_column(copies):
    review, access, key = copies
    with closing(sqlite3.connect(access)) as db, db:
        db.execute("ALTER TABLE user_totp RENAME COLUMN last_used_step TO unrelated_counter")
    report = recovery_rehearsal.rehearse(review, access, [key], ["RECOVERED_PREVIOUS"])
    assert report["databases"]["access"] == {"status": "schema_mismatch"}

def test_missing_required_model_key_fails_even_when_another_store_verifies(copies):
    review, access, key = copies
    with closing(sqlite3.connect(review)) as db, db:
        db.execute("UPDATE connected_models SET encrypted_api_key=NULL WHERE provider='openai'")
    result = recovery_rehearsal.rehearse(review, access, [key], ["RECOVERED_PREVIOUS"])
    assert result["status"] == "failed" and result["databases"]["access"]["status"] == "checked"
    models = result["databases"]["review"]["tables"]["connected_models"]
    assert models["encrypted"] == 0 and models["missing_required"] == 1

def test_trusted_digests_and_key_verification_have_independent_results(copies, monkeypatch):
    review, access, _ = copies
    monkeypatch.setenv("WRONG_KEY", "a-different-recovery-passphrase")
    pins = {kind: hashlib.sha256(path.read_bytes()).hexdigest() for kind, path in (("review", review), ("access", access))}
    report = recovery_rehearsal.rehearse(review, access, [], ["WRONG_KEY"], pins)
    assert report["pair_check"] == "matched" and report["status"] == "failed"
    assert report["databases"]["access"]["tables"]["user_totp"]["failed"] == 1


def test_lost_webhook_secret_is_distinct_from_an_unsigned_alert(copies):
    review, access, key = copies
    with closing(sqlite3.connect(review)) as db, db:
        db.execute("UPDATE alert_rules SET secret_hint='stored', encrypted_signing_secret=NULL")
    report = recovery_rehearsal.rehearse(review, access, [key], ["RECOVERED_PREVIOUS"])
    assert report["status"] == "failed" and report["databases"]["review"]["tables"]["alert_rules"]["missing_required"] == 1
    with closing(sqlite3.connect(review)) as db, db:
        db.execute("UPDATE alert_rules SET secret_hint=NULL")
    assert recovery_rehearsal.rehearse(review, access, [key], ["RECOVERED_PREVIOUS"])["status"] == "verified"


def test_migration_preflight_rejects_empty_account_before_either_database_changes(copies, tmp_path):
    from api.recovery_snapshot import check_historical_pair, SnapshotError

    review, _, _ = copies
    empty = tmp_path / "empty.sqlite3"
    empty.touch()
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    original = (digest(review), digest(empty))
    with pytest.raises(SnapshotError):
        check_historical_pair(review, empty, *original)
    assert (digest(review), digest(empty)) == original


def test_rehearsal_requires_subscription_startup_field(copies):
    review, access, key = copies
    with closing(sqlite3.connect(access)) as db, db:
        db.execute("ALTER TABLE subscriptions DROP COLUMN stripe_customer_id")
    result = recovery_rehearsal.rehearse(review, access, [key], ["RECOVERED_PREVIOUS"])
    assert result["databases"]["access"]["status"] == "schema_mismatch"
