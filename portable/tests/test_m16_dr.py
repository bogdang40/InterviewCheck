"""Tests for M16-W2 automated disaster recovery drill, WAL stress, and key rotation recovery."""
from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
from uuid import uuid4

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from api import account_db, backup, health_probes, key_rotation, model_registry, secret_box, store  # noqa: E402
from api.main import app  # noqa: E402
from api.models import AnswerInput, RoleInput, SessionInput  # noqa: E402
from scripts import dr_drill  # noqa: E402


def _seed_model(slug: str, secret: str, envelope: str) -> str:
    uid = str(uuid4())
    with store.connection(write=True) as db:
        model_registry.create_model(
            db,
            model_uuid=uid,
            slug=slug,
            display_name=f"DR {slug}",
            provider="openai",
            capability="reference",
            model_id="gpt-4o",
            endpoint=None,
            api_version=None,
            parameters={},
            encrypted_api_key=secret_box.encrypt_secret(secret, aad=uid, envelope=envelope),
            key_hint=secret_box.mask_key_hint(secret),
            enabled=True,
            is_default=False,
        )
    return uid


def test_dr_drill_cli_end_to_end_and_zero_secret_leakage(tmp_path):
    work_dir = tmp_path / "cli_drill"
    proc = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "dr_drill.py"), "--work-dir", str(work_dir), "--json"],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    payload = json.loads(proc.stdout)
    assert payload["ok"] is True
    assert payload["corruption_detected"] is True
    assert payload["wal_stress"]["operational_errors"] == 0
    assert payload["wal_stress"]["errors"] == []
    assert payload["wal_stress"]["writes_completed"] == 18
    assert payload["wal_stress"]["reads_completed"] == 18
    assert payload["sqlite_backup"]["review_integrity"] == "ok"
    assert payload["sqlite_backup"]["access_integrity"] == "ok"
    assert payload["sqlite_backup"]["access_user_version"] == 7
    assert payload["sqlite_restore"]["review_fk_errors"] == 0
    assert payload["sqlite_restore"]["access_fk_errors"] == 0
    assert payload["sqlite_restore"]["review_counts"]["drafts"] == 1
    assert payload["sqlite_restore"]["review_counts"]["trashed"] == 1
    assert payload["sqlite_restore"]["access_counts"]["api_tokens"] == 1
    assert payload["key_rotation"]["rotated_count"] == 2
    assert payload["key_rotation"]["needs_rotation_count_after"] == 0
    assert payload["key_rotation"]["decrypted_verified"] == 2
    assert payload["workspace_json_restore"]["integrity"] == "ok"
    assert payload["workspace_json_restore"]["fk_errors"] == 0
    assert payload["workspace_json_restore"]["drafts"] == 1
    assert payload["workspace_json_restore"]["trashed"] == 1
    assert payload["probes"]["healthz_status"] == 200
    assert payload["probes"]["readyz_status"] == 200
    assert payload["probes"]["readyz_ok"] is True

    for forbidden in (
        "sk-dr-model",
        "ic_tok_",
        "mm_",
        "dr-drill-initial-key-v1",
        "dr-drill-rotated-key-v2",
        "encrypted_api_key",
    ):
        assert forbidden not in proc.stdout


def test_concurrent_wal_stress_zero_operational_errors(tmp_path):
    report = dr_drill.run_drill(tmp_path / "wal_stress", writers=4, readers=4, ops_per_thread=10)
    assert report["ok"] is True
    assert report["wal_stress"]["writes_completed"] == 40
    assert report["wal_stress"]["reads_completed"] == 40
    assert report["wal_stress"]["operational_errors"] == 0
    assert report["wal_stress"]["errors"] == []
    assert report["sqlite_restore"]["review_counts"]["sessions"] >= 2
    assert report["workspace_json_restore"]["sessions"] >= 2


def test_key_rotation_recovery_after_restore_and_missing_key_rollback(tmp_path, monkeypatch):
    live_db = tmp_path / "live" / "review.sqlite3"
    backup_db = tmp_path / "bkp" / "review.sqlite3"
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(live_db))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "old-recovery-key")
    monkeypatch.delenv("INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS", raising=False)
    store.initialize(live_db)

    sec_1 = "sk-recover-v1-1111"
    sec_2 = "sk-recover-v2-2222"
    m1 = _seed_model("rec-v1", sec_1, "v1")
    m2 = _seed_model("rec-v2", sec_2, "v2")
    dr_drill._sqlite_backup(live_db, backup_db)

    live_db.write_bytes(b"destroyed")
    dr_drill._restore_sqlite(backup_db, live_db)

    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "new-recovery-key")
    with store.connection() as db:
        before = dict(db.execute("SELECT id, encrypted_api_key FROM connected_models").fetchall())
    with store.connection(write=True) as db:
        with pytest.raises(secret_box.SecretBoxError):
            key_rotation.rotate_database_secrets(db)
    with store.connection() as db:
        after_fail = dict(db.execute("SELECT id, encrypted_api_key FROM connected_models").fetchall())
    assert after_fail == before

    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS", "old-recovery-key")
    with store.connection(write=True) as db:
        report = key_rotation.rotate_database_secrets(db)
    assert report.rotated_count == 2
    monkeypatch.delenv("INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS", raising=False)

    active_kid = secret_box.active_key_id()
    with store.connection() as db:
        rotated = dict(db.execute("SELECT id, encrypted_api_key FROM connected_models").fetchall())
    assert secret_box.token_key_info(rotated[m1]) == ("v2", active_kid)
    assert secret_box.token_key_info(rotated[m2]) == ("v2", active_kid)
    assert secret_box.decrypt_secret(rotated[m1], aad=m1) == sec_1
    assert secret_box.decrypt_secret(rotated[m2], aad=m2) == sec_2


def test_corrupted_db_recovery_failure_and_tampered_json_backup_rejected(tmp_path, monkeypatch):
    live_rev = tmp_path / "live" / "review.sqlite3"
    live_acc = tmp_path / "live" / "access.sqlite3"
    bkp_rev = tmp_path / "bkp" / "review.sqlite3"
    bkp_acc = tmp_path / "bkp" / "access.sqlite3"
    dist_dir = tmp_path / "web_out"
    dist_dir.mkdir()
    (dist_dir / "index.html").write_text("<!doctype html><html></html>", encoding="utf-8")

    monkeypatch.setenv("INTERVIEWCHECK_DB", str(live_rev))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(live_acc))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "probe-recovery-key")
    monkeypatch.setattr(health_probes, "DIST", dist_dir)

    store.initialize(live_rev)
    with account_db.connection(write=True) as adb:
        assert adb.execute("PRAGMA user_version").fetchone()[0] == 7
    with store.connection(write=True) as db:
        role = store.create_role(db, RoleInput(name="Corrupt Test", questions=["Q1?"], policy="Verify evidence."))
        sess = store.create_session(db, SessionInput(candidate="C1", role=role["name"], role_id=role["id"], consent=True))
        store.write_answer(db, sess["id"], AnswerInput(question="Q1?", answer="A1"))

    dr_drill._sqlite_backup(live_rev, bkp_rev)
    dr_drill._sqlite_backup(live_acc, bkp_acc)
    dl = backup.download()
    raw_json = bytes(dl.body)
    sha = dl.headers["X-Backup-SHA256"]

    dr_drill._remove_db(live_rev)
    live_rev.write_bytes(b"NOT_A_VALID_SQLITE_FILE" * 32)
    with closing(sqlite3.connect(live_rev)) as bad_db:
        with pytest.raises(sqlite3.DatabaseError):
            bad_db.execute("PRAGMA integrity_check").fetchall()
    degraded = TestClient(app, base_url="http://127.0.0.1").get("/api/readyz")
    assert degraded.status_code == 503
    assert degraded.json()["ok"] is False
    assert degraded.json()["checks"]["review_db"] == "error"

    dr_drill._restore_sqlite(bkp_rev, live_rev)
    dr_drill._restore_sqlite(bkp_acc, live_acc)
    recovered = TestClient(app, base_url="http://127.0.0.1").get("/api/readyz")
    assert recovered.status_code == 200
    assert recovered.json()["ok"] is True

    clean_db = tmp_path / "clean" / "review.sqlite3"
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(clean_db))
    store.initialize(clean_db)
    with pytest.raises(HTTPException) as bad_sum:
        backup.process(raw_json, fingerprint=sha, expected_sha256="0" * 64)
    assert bad_sum.value.status_code == 409

    tampered_doc = json.loads(raw_json)
    tampered_doc["sessions"][0]["answers"][0]["result"]["status"] = "match"
    tampered_bytes = json.dumps(tampered_doc).encode("utf-8")
    tampered_sha = hashlib.sha256(tampered_bytes).hexdigest()
    with pytest.raises(HTTPException) as bad_evidence:
        backup.process(tampered_bytes, fingerprint=tampered_sha, expected_sha256=tampered_sha)
    assert bad_evidence.value.status_code == 422

    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM sessions").fetchone()[0] == 0

    ok_summary = backup.process(raw_json, fingerprint=sha, expected_sha256=sha)
    assert ok_summary["sessions"]["new"] == 1
    assert dr_drill._check_sqlite_health(clean_db) == ("ok", 0)
