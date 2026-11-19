#!/usr/bin/env python3
"""Automated end-to-end disaster recovery drill, WAL stress check, and probe verifier."""
from __future__ import annotations

import argparse, hashlib, json, os, secrets, shutil, sqlite3, sys, tempfile, threading, time
from contextlib import closing
from pathlib import Path
from typing import Any
from uuid import UUID, uuid4

ROOT = Path(__file__).resolve().parent.parent
PORTABLE = ROOT / "portable"
if str(PORTABLE) not in sys.path:
    sys.path.insert(0, str(PORTABLE))

from fastapi.testclient import TestClient  # noqa: E402
from api import account_db, backup, backup_schema, drafts, health_probes, key_rotation, model_registry, rate_limit, secret_box, store, trash  # noqa: E402
from api.main import app  # noqa: E402
from api.models import AnswerInput, PermittedMaterial, Reference, RoleInput, RubricCriterion, SessionInput  # noqa: E402

_ENV_KEYS = (
    "INTERVIEWCHECK_DB", "INTERVIEWCHECK_ACCESS_DB", "INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL",
    "INTERVIEWCHECK_MODEL_SECRET_KEY", "INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS", "INTERVIEWCHECK_MODEL_SECRET_FILE",
    "INTERVIEWCHECK_PUBLIC_ORIGIN", "INTERVIEWCHECK_PRODUCTION",
)
_INITIAL_KEY, _ROTATED_KEY = "dr-drill-initial-key-v1", "dr-drill-rotated-key-v2"


def _require(cond: bool, msg: str) -> None:
    if not cond:
        raise RuntimeError(msg)


def _sqlite_backup(src_path: Path, dst_path: Path) -> None:
    dst_path.parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(src_path, timeout=10)) as src, closing(sqlite3.connect(dst_path, timeout=10)) as dst:
        src.backup(dst)
    if os.name != "nt":
        os.chmod(dst_path, 0o600)


def _check_sqlite_health(path: Path) -> tuple[str, int]:
    with closing(sqlite3.connect(path, timeout=10)) as db:
        db.execute("PRAGMA foreign_keys=ON")
        return str(db.execute("PRAGMA integrity_check").fetchone()[0]), len(db.execute("PRAGMA foreign_key_check").fetchall())


def _db_counts(review_path: Path, access_path: Path) -> tuple[dict[str, int], dict[str, int]]:
    with closing(sqlite3.connect(review_path, timeout=10)) as rdb, closing(sqlite3.connect(access_path, timeout=10)) as adb:
        rc = {k: rdb.execute(f"SELECT count(*) FROM {t}").fetchone()[0] for k, t in (
            ("roles", "roles"), ("sessions", "sessions"), ("answers", "answers"),
            ("drafts", "session_drafts"), ("trashed", "session_trash"), ("models", "connected_models"))}
        ac = {t: adb.execute(f"SELECT count(*) FROM {t}").fetchone()[0] for t in ("users", "sessions", "api_tokens", "audit_log")}
        ac["user_version"] = adb.execute("PRAGMA user_version").fetchone()[0]
    return rc, ac


def _remove_db(path: Path) -> None:
    [Path(f"{path}{s}").unlink(missing_ok=True) for s in ("", "-wal", "-shm")]


def _restore_sqlite(backup_path: Path, live_path: Path) -> None:
    _remove_db(live_path)
    _sqlite_backup(backup_path, live_path)
    with closing(sqlite3.connect(live_path, timeout=10)) as db:
        _require(str(db.execute("PRAGMA journal_mode=WAL").fetchone()[0]).lower() == "wal", f"Expected WAL mode on {live_path.name}.")


def _seed_workspace(sensitive: list[str]) -> tuple[dict[str, Any], str, str, str, str, str]:
    guide = PermittedMaterial(label="SQLite Guide", text="SQLite WAL mode supports concurrent readers and online backup API.")
    with store.connection(write=True) as db:
        role = store.create_role(db, RoleInput(
            name="DR Reliability Engineer", description="Role with rubric for DR drill",
            questions=["Explain WAL mode.", "How do backups stay consistent?"], policy="Verify every answer against cited evidence.",
            permitted_sources=[guide], rubric=[RubricCriterion(id=str(uuid4()), criterion="SQLite Backup Safety", weight=5,
                                                               expected_signals=["online backup API", "WAL mode"], red_flags=["raw file copy"])]))
        active = store.create_session(db, SessionInput(candidate="Alice Recovery", role=role["name"], role_id=UUID(role["id"]), consent=True))
        store.write_answer(db, active["id"], AnswerInput(
            question="Explain WAL mode.", answer="SQLite WAL mode supports concurrent readers and online backup API.",
            references=[Reference(label=guide.label, text=guide.text, permitted=True)]))
        trashed = store.create_session(db, SessionInput(candidate="Bob Trashed", role=role["name"], role_id=UUID(role["id"]), consent=True))
        store.write_answer(db, trashed["id"], AnswerInput(question="How do backups stay consistent?", answer="Use sqlite3.Connection.backup()."))
    drafts.save(UUID(active["id"]), drafts.DraftInput(
        id=uuid4(), expected_revision=0, question="How do backups stay consistent?", answer="Draft answer pending review.", planned_slot=2))
    trash.move(UUID(trashed["id"]))

    sec_a, sec_b = "sk-dr-model-v1-" + secrets.token_hex(8), "sk-dr-model-v2-" + secrets.token_hex(8)
    m_a, m_b = str(uuid4()), str(uuid4())
    sensitive.extend([sec_a, sec_b])
    with store.connection(write=True) as db:
        for mid, slug, prov, cap, mod, sec, env_v, is_def in (
            (m_a, "dr-model-v1", "openai", "reference", "gpt-4o", sec_a, "v1", True),
            (m_b, "dr-model-v2", "anthropic", "judge", "claude-sonnet-4-6", sec_b, "v2", False),
        ):
            model_registry.create_model(db, model_uuid=mid, slug=slug, display_name=f"DR {slug}", provider=prov, capability=cap,
                                        model_id=mod, endpoint=None, api_version=None, parameters={}, key_hint=secret_box.mask_key_hint(sec),
                                        encrypted_api_key=secret_box.encrypt_secret(sec, aad=mid, envelope=env_v), enabled=True, is_default=is_def)
    admin_id, user_id, raw_tok = str(uuid4()), str(uuid4()), "ic_tok_" + secrets.token_urlsafe(32)
    sensitive.append(raw_tok)
    with account_db.connection(write=True) as adb:
        ts = account_db.now()
        for uid, email, rname in ((admin_id, "dr-admin@example.invalid", "admin"), (user_id, "dr-user@example.invalid", "user")):
            adb.execute("INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,0,?,?)", (uid, email, account_db.DECOY, rname, ts, ts))
        sensitive.extend([account_db.issue(adb, admin_id, "dr-admin-console"), account_db.issue(adb, user_id, "dr-user-browser")])
        adb.execute("INSERT INTO api_tokens(id,user_id,name,token_prefix,token_hash,scopes_json,created_at,expires_at) VALUES (?,?,?,?,?,?,?,?)",
                    (str(uuid4()), admin_id, "dr-automation", raw_tok[:14], account_db.digest(raw_tok), '["read:interviews","read:telemetry"]', ts, ts + 30 * account_db.DAY))
        account_db.audit(adb, "dr.seed.complete", admin_id, admin_id, {"models": 2})
    return role, admin_id, m_a, m_b, sec_a, sec_b


def _run_wal_stress(
    *, role_id: str, role_name: str, actor_id: str, writers: int, readers: int,
    ops_per_thread: int, review_db: Path, access_db: Path, backup_review: Path, backup_access: Path,
) -> tuple[dict[str, Any], bytes, str]:
    barrier, lock, errors, first_write = threading.Barrier(writers + readers + 1), threading.Lock(), [], threading.Event()
    stats = {"writes": 0, "reads": 0, "operational_errors": 0}

    def run_worker(kind: str, idx: int) -> None:
        try:
            barrier.wait(timeout=10)
            for step in range(ops_per_thread):
                if kind == "writer":
                    with store.connection(write=True) as db:
                        created = store.create_session(db, SessionInput(candidate=f"WAL Candidate {idx}-{step}", role=role_name, role_id=UUID(role_id), consent=True))
                        store.write_answer(db, created["id"], AnswerInput(
                            question="Explain WAL mode.", answer="SQLite WAL mode supports concurrent readers and online backup API.",
                            references=[Reference(label="SQLite Guide", text="SQLite WAL mode supports concurrent readers and online backup API.", permitted=True)]))
                    with account_db.connection(write=True) as adb:
                        account_db.audit(adb, "dr.wal.write", actor_id, actor_id, {"worker": idx, "step": step})
                    with lock:
                        stats["writes"] += 1
                    first_write.set()
                else:
                    with store.connection() as db:
                        db.execute("SELECT id, candidate FROM interview_catalog ORDER BY created_at DESC LIMIT 10").fetchall()
                    with account_db.connection() as adb:
                        adb.execute("SELECT id, action FROM audit_log ORDER BY id DESC LIMIT 10").fetchall()
                    with lock:
                        stats["reads"] += 1
        except sqlite3.OperationalError as exc:
            with lock:
                stats["operational_errors"] += 1
                errors.append(f"{kind}-{idx}: {exc}")
        except Exception as exc:
            with lock:
                errors.append(f"{kind}-{idx}: {exc.__class__.__name__}: {exc}")

    threads = [threading.Thread(target=run_worker, args=(k, i), daemon=True) for k, n in (("writer", writers), ("reader", readers)) for i in range(n)]
    for t in threads:
        t.start()
    barrier.wait(timeout=10)
    first_write.wait(timeout=5)
    _sqlite_backup(review_db, backup_review)
    _sqlite_backup(access_db, backup_access)
    resp = backup.download()
    for t in threads:
        t.join(timeout=30)
        if t.is_alive():
            errors.append(f"thread {t.name} timed out")
    return ({"writers": writers, "readers": readers, "ops_per_thread": ops_per_thread, "writes_completed": stats["writes"],
             "reads_completed": stats["reads"], "operational_errors": stats["operational_errors"], "errors": errors},
            bytes(resp.body), resp.headers["X-Backup-SHA256"])


def _verify_restore_and_rotation(
    review_db: Path, access_db: Path, backup_review: Path, backup_access: Path,
    snap_review: dict[str, int], snap_access: dict[str, int], m_a: str, m_b: str, sec_a: str, sec_b: str,
) -> tuple[tuple[str, int], tuple[str, int], key_rotation.RotationReport, dict[str, Any]]:
    _remove_db(review_db)
    review_db.write_bytes(b"CORRUPTED_SQLITE_HEADER\x00" * 128)
    _remove_db(access_db)
    degraded = TestClient(app, base_url="http://127.0.0.1").get("/api/readyz")
    _require(degraded.status_code == 503 and degraded.json().get("ok") is False, "Corrupted DB state did not fail /api/readyz.")
    _restore_sqlite(backup_review, review_db)
    _restore_sqlite(backup_access, access_db)
    rev_health, acc_health = _check_sqlite_health(review_db), _check_sqlite_health(access_db)
    _require(rev_health == ("ok", 0) and acc_health == ("ok", 0) and _db_counts(review_db, access_db) == (snap_review, snap_access),
             "Restored SQLite database failed integrity, foreign_key, or row count verification.")
    os.environ.update({"INTERVIEWCHECK_MODEL_SECRET_KEY": _ROTATED_KEY, "INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS": _INITIAL_KEY})
    with store.connection(write=True) as db:
        rot_report = key_rotation.rotate_database_secrets(db)
    os.environ.pop("INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS", None)
    with store.connection() as db:
        kstatus, rows = key_rotation.key_status(db), dict(db.execute("SELECT id, encrypted_api_key FROM connected_models").fetchall())
    _require(rot_report.rotated_count == 2 and kstatus["needs_rotation_count"] == 0, "Key rotation did not migrate all credentials.")
    _require(secret_box.decrypt_secret(rows[m_a], aad=m_a) == sec_a and secret_box.decrypt_secret(rows[m_b], aad=m_b) == sec_b,
             "Model decryption failed after key rotation.")
    return rev_health, acc_health, rot_report, kstatus


def run_drill(work_dir: Path, *, writers: int = 3, readers: int = 3, ops_per_thread: int = 6) -> dict[str, Any]:
    started, work_dir = time.monotonic(), Path(work_dir)
    live_dir, backup_dir, json_dir = work_dir / "live", work_dir / "backups", work_dir / "json_restore"
    for d in (live_dir, backup_dir, json_dir):
        d.mkdir(parents=True, exist_ok=True, mode=0o700)
    review_db, access_db = live_dir / "review.sqlite3", live_dir / "access.sqlite3"
    backup_review, backup_access = backup_dir / "review.sqlite3", backup_dir / "access.sqlite3"
    saved_env, saved_dist, sensitive = {k: os.environ.get(k) for k in _ENV_KEYS}, health_probes.DIST, [_INITIAL_KEY, _ROTATED_KEY]

    try:
        for k in _ENV_KEYS:
            os.environ.pop(k, None)
        os.environ.update({"INTERVIEWCHECK_DB": str(review_db), "INTERVIEWCHECK_ACCESS_DB": str(access_db),
                           "INTERVIEWCHECK_ACCESS_MODE": "embedded", "INTERVIEWCHECK_MODEL_SECRET_KEY": _INITIAL_KEY})
        rate_limit.reset_all()
        if not (health_probes.DIST / "index.html").is_file():
            staged = work_dir / "web_out"
            staged.mkdir(parents=True, exist_ok=True)
            (staged / "index.html").write_text("<!doctype html><html></html>", encoding="utf-8")
            health_probes.DIST = staged

        store.initialize(review_db)
        role, admin_id, m_a, m_b, sec_a, sec_b = _seed_workspace(sensitive)
        seed_review, seed_access = _db_counts(review_db, access_db)
        _require(seed_access["user_version"] == account_db.VERSION,
                 f"Expected access.sqlite3 v{account_db.VERSION}, got v{seed_access['user_version']}.")
        wal_stress, json_bytes, json_sha256 = _run_wal_stress(
            role_id=role["id"], role_name=role["name"], actor_id=admin_id, writers=writers, readers=readers,
            ops_per_thread=ops_per_thread, review_db=review_db, access_db=access_db, backup_review=backup_review, backup_access=backup_access)
        _require(not wal_stress["errors"] and wal_stress["operational_errors"] == 0, f"WAL stress errors: {wal_stress['errors']}")
        _require(hashlib.sha256(json_bytes).hexdigest() == json_sha256.lower(), "Workspace backup X-Backup-SHA256 mismatch.")
        rev_bkp, acc_bkp = _check_sqlite_health(backup_review), _check_sqlite_health(backup_access)
        _require(rev_bkp == ("ok", 0) and acc_bkp == ("ok", 0), "SQLite backup snapshot failed integrity or FK check.")
        snap_review, snap_access = _db_counts(backup_review, backup_access)
        rev_res, acc_res, rot_report, kstatus = _verify_restore_and_rotation(
            review_db, access_db, backup_review, backup_access, snap_review, snap_access, m_a, m_b, sec_a, sec_b)

        clean_db = json_dir / "review.sqlite3"
        os.environ["INTERVIEWCHECK_DB"] = str(clean_db)
        store.initialize(clean_db)
        backup_schema.parse(json_bytes)
        json_summary = backup.process(json_bytes, fingerprint=json_sha256, expected_sha256=json_sha256)
        json_int, json_fk = _check_sqlite_health(clean_db)
        _require(json_int == "ok" and json_fk == 0, "Workspace JSON restore DB failed integrity or FK check.")
        os.environ["INTERVIEWCHECK_DB"] = str(review_db)
        with TestClient(app, base_url="http://127.0.0.1") as client:
            hz, rz = client.get("/api/healthz"), client.get("/api/readyz")
        _require(hz.status_code == 200 and hz.json().get("ok") and rz.status_code == 200 and rz.json().get("ok"),
                 f"Post-restore probes failed: healthz={hz.status_code} readyz={rz.status_code}")

        result = {
            "ok": True, "work_dir": str(work_dir), "seed": {"review": seed_review, "access": seed_access},
            "wal_stress": wal_stress, "corruption_detected": True,
            "sqlite_backup": {"review_integrity": rev_bkp[0], "review_fk_errors": rev_bkp[1], "access_integrity": acc_bkp[0], "access_fk_errors": acc_bkp[1], "access_user_version": snap_access["user_version"]},
            "sqlite_restore": {"review_integrity": rev_res[0], "review_fk_errors": rev_res[1], "access_integrity": acc_res[0], "access_fk_errors": acc_res[1], "review_counts": snap_review, "access_counts": snap_access},
            "key_rotation": {"active_key_id": rot_report.active_key_id, "total_with_keys": rot_report.total_with_keys, "rotated_count": rot_report.rotated_count, "needs_rotation_count_after": kstatus["needs_rotation_count"], "decrypted_verified": 2},
            "workspace_json_restore": {"sha256": json_sha256, "roles": json_summary["roles"]["new"], "sessions": json_summary["sessions"]["new"], "answers": json_summary["answers"], "drafts": json_summary["drafts"], "trashed": json_summary["trashed"], "integrity": json_int, "fk_errors": json_fk},
            "probes": {"healthz_status": hz.status_code, "healthz_ok": hz.json()["ok"], "readyz_status": rz.status_code, "readyz_ok": rz.json()["ok"], "checks": rz.json()["checks"]},
            "duration_ms": int((time.monotonic() - started) * 1000),
        }
        _require(not any(s and s in json.dumps(result) for s in sensitive), "Secret leakage detected in DR drill output.")
        return result
    finally:
        health_probes.DIST = saved_dist
        for key, value in saved_env.items():
            os.environ.pop(key, None) if value is None else os.environ.__setitem__(key, value)
        rate_limit.reset_all()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run end-to-end InterviewCheck Disaster Recovery drill.")
    parser.add_argument("--work-dir", type=Path, default=None, help="Directory for drill databases and backups.")
    parser.add_argument("--json", action="store_true", dest="as_json", help="Emit structured JSON summary.")
    args = parser.parse_args(argv)
    tmp_dir = None if args.work_dir is not None else Path(tempfile.mkdtemp(prefix="ic-dr-drill-"))
    try:
        report = run_drill(args.work_dir or tmp_dir)
        print(json.dumps(report, indent=2) if args.as_json else f"DR drill OK in {report['duration_ms']}ms")
        return 0
    except Exception as exc:
        err = {"ok": False, "error": f"{exc.__class__.__name__}: {exc}"}
        print(json.dumps(err)) if args.as_json else print(f"DR drill FAILED: {err['error']}", file=sys.stderr)
        return 1
    finally:
        if tmp_dir is not None:
            shutil.rmtree(tmp_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
