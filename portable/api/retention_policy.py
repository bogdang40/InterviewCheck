"""Configurable data retention policies, PII anonymization, and trash purge engine."""
from datetime import datetime, timedelta, timezone
import sqlite3
from typing import Any
from uuid import uuid4

from fastapi import APIRouter, Depends, Request
from pydantic import Field

from . import rate_limit, store
from .models import Input
from .retention_anonymizer import REDACTED_TEXT, SessionAnonymizer
from .session_purge import purge_session

MAX_RETENTION_DAYS = 3650

SCHEMA = """
CREATE TABLE IF NOT EXISTS retention_policies (
  id TEXT PRIMARY KEY CHECK(id = 'default'),
  anonymize_after_days INTEGER NOT NULL DEFAULT 90 CHECK(anonymize_after_days BETWEEN 0 AND 3650),
  purge_trashed_after_days INTEGER NOT NULL DEFAULT 30 CHECK(purge_trashed_after_days BETWEEN 0 AND 3650),
  preserve_scorecard_aggregates INTEGER NOT NULL DEFAULT 1 CHECK(preserve_scorecard_aggregates IN (0,1)),
  enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN (0,1)),
  updated_by TEXT NOT NULL DEFAULT 'system',
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS retention_runs (
  id TEXT PRIMARY KEY,
  dry_run INTEGER NOT NULL CHECK(dry_run IN (0,1)),
  actor_email TEXT NOT NULL,
  anonymized_sessions INTEGER NOT NULL DEFAULT 0,
  purged_sessions INTEGER NOT NULL DEFAULT 0,
  cutoff_anonymize_at TEXT,
  cutoff_purge_at TEXT,
  executed_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_retention_runs_at ON retention_runs(executed_at DESC);
CREATE TABLE IF NOT EXISTS session_anonymizations (
  session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
  anonymized_at TEXT NOT NULL,
  anonymized_by TEXT NOT NULL
);
"""

router = APIRouter(prefix="/api/admin/compliance", tags=["compliance-retention"])


class RetentionPolicyInput(Input):
    anonymize_after_days: int = Field(ge=0, le=MAX_RETENTION_DAYS)
    purge_trashed_after_days: int = Field(ge=0, le=MAX_RETENTION_DAYS)
    preserve_scorecard_aggregates: bool = True
    enabled: bool = False


class RetentionRunInput(Input):
    dry_run: bool = True


def _has_table(db: sqlite3.Connection, name: str) -> bool:
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def migrate(db: sqlite3.Connection) -> None:
    db.executescript(SCHEMA)
    db.execute(
        "INSERT OR IGNORE INTO retention_policies"
        "(id,anonymize_after_days,purge_trashed_after_days,preserve_scorecard_aggregates,enabled,updated_by,updated_at) "
        "VALUES ('default',90,30,1,0,'system',?)",
        (store.timestamp(),),
    )


def _parse_utc(raw: str | datetime | None) -> datetime | None:
    if raw is None:
        return None
    if isinstance(raw, datetime):
        dt = raw
    else:
        try:
            dt = datetime.fromisoformat(raw)
        except (TypeError, ValueError):
            return None
    return dt.replace(tzinfo=timezone.utc) if (dt.tzinfo is None or dt.utcoffset() is None) else dt.astimezone(timezone.utc)


def _default_policy() -> dict[str, Any]:
    return {
        "id": "default", "anonymize_after_days": 90, "purge_trashed_after_days": 30,
        "preserve_scorecard_aggregates": True, "enabled": False, "updated_by": "system", "updated_at": store.timestamp(),
    }


def _public_policy(row: sqlite3.Row | None) -> dict[str, Any]:
    if row is None:
        return _default_policy()
    return {
        "id": str(row["id"]),
        "anonymize_after_days": int(row["anonymize_after_days"]),
        "purge_trashed_after_days": int(row["purge_trashed_after_days"]),
        "preserve_scorecard_aggregates": bool(row["preserve_scorecard_aggregates"]),
        "enabled": bool(row["enabled"]),
        "updated_by": str(row["updated_by"]),
        "updated_at": str(row["updated_at"]),
    }


def _public_run(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": str(row["id"]), "dry_run": bool(row["dry_run"]), "actor_email": str(row["actor_email"]),
        "anonymized_sessions": int(row["anonymized_sessions"]), "purged_sessions": int(row["purged_sessions"]),
        "cutoff_anonymize_at": row["cutoff_anonymize_at"], "cutoff_purge_at": row["cutoff_purge_at"],
        "executed_at": str(row["executed_at"]),
    }


def _load_policy(db: sqlite3.Connection) -> dict[str, Any]:
    if not _has_table(db, "retention_policies"):
        return _default_policy()
    return _public_policy(db.execute("SELECT * FROM retention_policies WHERE id='default'").fetchone())


def execute_retention_job(
    db: sqlite3.Connection, *, dry_run: bool, actor_email: str, now: datetime | str | None = None,
) -> dict[str, Any]:
    if not _has_table(db, "retention_policies"):
        migrate(db)
    now_dt = datetime.now(timezone.utc) if now is None else _parse_utc(now)
    if now_dt is None:
        raise ValueError("Invalid reference timestamp for retention job.")
    now_iso = now_dt.isoformat()
    policy = _load_policy(db)
    anon_days, purge_days = int(policy["anonymize_after_days"]), int(policy["purge_trashed_after_days"])
    preserve_agg = bool(policy["preserve_scorecard_aggregates"])

    anon_ids: list[str] = []
    cutoff_anon_iso: str | None = None
    if anon_days > 0:
        cutoff_anon_dt = now_dt - timedelta(days=anon_days)
        cutoff_anon_iso = cutoff_anon_dt.isoformat()
        candidates = db.execute(
            """SELECT s.id, s.created_at, c.ended_at FROM active_sessions s
               LEFT JOIN session_context c ON c.session_id = s.id
               LEFT JOIN session_anonymizations sa ON sa.session_id = s.id
               WHERE sa.session_id IS NULL AND (c.ended_at IS NOT NULL OR s.consent = 0)
               ORDER BY s.created_at ASC, s.id ASC"""
        ).fetchall()
        for row in candidates:
            ref_dt = _parse_utc(row["ended_at"]) or _parse_utc(row["created_at"])
            if ref_dt is not None and ref_dt <= cutoff_anon_dt:
                anon_ids.append(str(row["id"]))
        if not dry_run:
            for sid in anon_ids:
                SessionAnonymizer(db, sid).run(
                    preserve_scorecard_aggregates=preserve_agg, actor_email=actor_email, now_iso=now_iso,
                )

    purge_ids: list[str] = []
    cutoff_purge_iso: str | None = None
    if purge_days > 0:
        cutoff_purge_dt = now_dt - timedelta(days=purge_days)
        cutoff_purge_iso = cutoff_purge_dt.isoformat()
        for row in db.execute("SELECT session_id, trashed_at FROM session_trash ORDER BY trashed_at ASC, session_id ASC"):
            trashed_dt = _parse_utc(row["trashed_at"])
            if trashed_dt is not None and trashed_dt <= cutoff_purge_dt:
                purge_ids.append(str(row["session_id"]))
        if not dry_run:
            for sid in purge_ids:
                purge_session(db, sid)

    run_id = str(uuid4())
    db.execute(
        "INSERT INTO retention_runs(id,dry_run,actor_email,anonymized_sessions,purged_sessions,"
        "cutoff_anonymize_at,cutoff_purge_at,executed_at) VALUES (?,?,?,?,?,?,?,?)",
        (run_id, 1 if dry_run else 0, actor_email, len(anon_ids), len(purge_ids), cutoff_anon_iso, cutoff_purge_iso, now_iso),
    )
    run_row = db.execute("SELECT * FROM retention_runs WHERE id=?", (run_id,)).fetchone()
    return {
        "dry_run": bool(dry_run), "anonymized_sessions": len(anon_ids), "purged_sessions": len(purge_ids),
        "anonymized_session_ids": anon_ids, "purged_session_ids": purge_ids,
        "cutoff_anonymize_at": cutoff_anon_iso, "cutoff_purge_at": cutoff_purge_iso,
        "executed_at": now_iso, "run": _public_run(run_row), "policy": policy,
    }


def _actor_email(actor: dict[str, Any]) -> str:
    return str(actor.get("email") or actor.get("id") or "admin")


async def _require_admin(request: Request) -> dict[str, Any]:
    from . import model_admin
    return await model_admin.require_admin(request)


@router.get("/retention", dependencies=[Depends(_require_admin), Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
def get_retention_policy():
    with store.connection() as db:
        policy = _load_policy(db)
        runs: list[dict[str, Any]] = []
        if _has_table(db, "retention_runs"):
            rows = db.execute("SELECT * FROM retention_runs ORDER BY executed_at DESC, rowid DESC LIMIT 20").fetchall()
            runs = [_public_run(row) for row in rows]
    return {"policy": policy, "runs": runs}


@router.put("/retention", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
def update_retention_policy(item: RetentionPolicyInput, actor: dict = Depends(_require_admin)):
    from . import model_admin
    email, now_iso, post_commit = _actor_email(actor), store.timestamp(), []
    with store.connection(write=True) as db:
        if not _has_table(db, "retention_policies"):
            migrate(db)
        db.execute(
            """INSERT INTO retention_policies(
                   id, anonymize_after_days, purge_trashed_after_days,
                   preserve_scorecard_aggregates, enabled, updated_by, updated_at
               ) VALUES ('default',?,?,?,?,?,?)
               ON CONFLICT(id) DO UPDATE SET
                   anonymize_after_days=excluded.anonymize_after_days,
                   purge_trashed_after_days=excluded.purge_trashed_after_days,
                   preserve_scorecard_aggregates=excluded.preserve_scorecard_aggregates,
                   enabled=excluded.enabled, updated_by=excluded.updated_by, updated_at=excluded.updated_at""",
            (item.anonymize_after_days, item.purge_trashed_after_days,
             1 if item.preserve_scorecard_aggregates else 0, 1 if item.enabled else 0, email, now_iso),
        )
        policy = _load_policy(db)
        model_admin._record_audit(
            db, actor=actor, action="admin.compliance.retention_policy", model_uuid="default",
            details={k: policy[k] for k in ("anonymize_after_days", "purge_trashed_after_days", "preserve_scorecard_aggregates", "enabled")},
            post_commit=post_commit,
        )
    model_admin._flush_account_audits(post_commit)
    return {"policy": policy}


@router.post("/retention/run", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
def run_retention_job(item: RetentionRunInput | None = None, actor: dict = Depends(_require_admin)):
    from . import model_admin
    dry_run = True if item is None else item.dry_run
    email, post_commit = _actor_email(actor), []
    with store.connection(write=True) as db:
        result = execute_retention_job(db, dry_run=dry_run, actor_email=email)
        if not dry_run:
            model_admin._record_audit(
                db, actor=actor, action="admin.compliance.retention_run", model_uuid=result["run"]["id"],
                details={k: result[k] for k in ("anonymized_sessions", "purged_sessions", "cutoff_anonymize_at", "cutoff_purge_at")} | {"run_id": result["run"]["id"]},
                post_commit=post_commit,
            )
    model_admin._flush_account_audits(post_commit)
    return result
