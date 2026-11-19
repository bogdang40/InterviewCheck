"""Tamper-evident SHA-256 hash chaining and verification for fallback model_audit."""
import hashlib
import hmac
import json
import sqlite3
from typing import Any

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse

from . import model_admin, rate_limit, store

router = APIRouter(prefix="/api/admin/audit", tags=["audit-integrity"])


def compute_entry_hash(
    *,
    prev_hash: str | None,
    at: str | int,
    actor_user_id: str | None,
    action: str,
    target_user_id: str | None,
    details: str | None,
) -> str:
    payload = f"{prev_hash or 'GENESIS'}|{at}|{actor_user_id or ''}|{action}|{target_user_id or ''}|{details or ''}"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def migrate(db: sqlite3.Connection) -> None:
    cols = {row[1] for row in db.execute("PRAGMA table_info(model_audit)")}
    if not cols:
        return
    if "prev_hash" not in cols:
        db.execute("ALTER TABLE model_audit ADD COLUMN prev_hash TEXT")
    if "entry_hash" not in cols:
        db.execute("ALTER TABLE model_audit ADD COLUMN entry_hash TEXT")


def append_model_audit(
    db: sqlite3.Connection,
    *,
    at: str,
    actor_user_id: str | None,
    action: str,
    model_uuid: str,
    details: dict[str, Any] | None = None,
) -> str:
    migrate(db)
    details_json = json.dumps(details) if details else None
    savepoint = "sp_model_audit_chain"
    db.execute(f"SAVEPOINT {savepoint}")
    try:
        prev = db.execute("SELECT entry_hash FROM model_audit ORDER BY id DESC LIMIT 1").fetchone()
        prev_hash = prev[0] if prev is not None else None
        entry_hash = compute_entry_hash(
            prev_hash=prev_hash,
            at=at,
            actor_user_id=actor_user_id,
            action=action,
            target_user_id=model_uuid,
            details=details_json,
        )
        db.execute(
            """INSERT INTO model_audit(at, actor_user_id, action, model_id, details, prev_hash, entry_hash)
               VALUES (?,?,?,?,?,?,?)""",
            (at, actor_user_id, action, model_uuid, details_json, prev_hash, entry_hash),
        )
        db.execute(f"RELEASE SAVEPOINT {savepoint}")
        return entry_hash
    except Exception:
        db.execute(f"ROLLBACK TO SAVEPOINT {savepoint}")
        db.execute(f"RELEASE SAVEPOINT {savepoint}")
        raise


def verify_model_audit_chain(db: sqlite3.Connection) -> dict[str, Any]:
    cols = {row[1] for row in db.execute("PRAGMA table_info(model_audit)")}
    if not cols:
        return {
            "ok": True,
            "verifiedCount": 0,
            "legacyUnchainedCount": 0,
            "firstBrokenId": None,
            "headHash": None,
        }
    if "prev_hash" not in cols or "entry_hash" not in cols:
        count = int(db.execute("SELECT count(*) FROM model_audit").fetchone()[0])
        return {
            "ok": True,
            "verifiedCount": 0,
            "legacyUnchainedCount": count,
            "firstBrokenId": None,
            "headHash": None,
        }
    rows = db.execute(
        "SELECT id, at, actor_user_id, action, model_id, details, prev_hash, entry_hash FROM model_audit ORDER BY id ASC"
    ).fetchall()
    verified_count = 0
    legacy_unchained_count = 0
    expected_prev_hash: str | None = None
    seen_chained = False

    for row in rows:
        row_id = int(row["id"])
        row_entry_hash = row["entry_hash"]
        row_prev_hash = row["prev_hash"]
        if row_entry_hash is None:
            if seen_chained or row_prev_hash is not None:
                return {
                    "ok": False,
                    "verifiedCount": verified_count,
                    "legacyUnchainedCount": legacy_unchained_count,
                    "firstBrokenId": row_id,
                    "headHash": expected_prev_hash,
                }
            legacy_unchained_count += 1
            continue

        seen_chained = True
        if row_prev_hash != expected_prev_hash:
            return {
                "ok": False,
                "verifiedCount": verified_count,
                "legacyUnchainedCount": legacy_unchained_count,
                "firstBrokenId": row_id,
                "headHash": expected_prev_hash,
            }

        expected_entry = compute_entry_hash(
            prev_hash=expected_prev_hash,
            at=row["at"],
            actor_user_id=row["actor_user_id"],
            action=row["action"],
            target_user_id=row["model_id"],
            details=row["details"],
        )
        if not hmac.compare_digest(expected_entry, str(row_entry_hash)):
            return {
                "ok": False,
                "verifiedCount": verified_count,
                "legacyUnchainedCount": legacy_unchained_count,
                "firstBrokenId": row_id,
                "headHash": expected_prev_hash,
            }

        expected_prev_hash = str(row_entry_hash)
        verified_count += 1

    return {
        "ok": True,
        "verifiedCount": verified_count,
        "legacyUnchainedCount": legacy_unchained_count,
        "firstBrokenId": None,
        "headHash": expected_prev_hash,
    }


@router.get("/verify", dependencies=[Depends(model_admin.require_admin), Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
def verify_fallback_audit() -> JSONResponse:
    with store.connection() as db:
        result = verify_model_audit_chain(db)
    return JSONResponse(result, headers={"Cache-Control": "no-store"})
