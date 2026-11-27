"""Deliver admin audit entries to the access database without ever losing one.

An admin change and its audit entry commit together in the review database. The
entry then moves to the hash chained access audit log. When the access database
is busy or unavailable the change still succeeds: the entry stays queued here
and the next admin change or the next startup delivers it.

Delivery holds the review write lock while it copies entries, so concurrent
flushes never copy the same entry twice. A crash between the access commit and
the review commit can repeat an entry once; it can never drop one.
"""
import json
import sqlite3
import sys
from typing import Any

from . import account_db, store
from .error_sanitizer import sanitize_error_text

SCHEMA = """CREATE TABLE IF NOT EXISTS admin_audit_outbox (
 id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, action TEXT NOT NULL, target TEXT NOT NULL,
 actor_user_id TEXT, details TEXT)"""


def migrate(db: sqlite3.Connection) -> None:
    db.execute(SCHEMA)


def stage(db: sqlite3.Connection, *, action: str, target: str | None, actor_user_id: str | None, details: dict[str, Any] | None) -> None:
    """Queue an entry inside the review transaction. An empty target represents no account."""
    db.execute(
        "INSERT INTO admin_audit_outbox(at,action,target,actor_user_id,details) VALUES (?,?,?,?,?)",
        (account_db.now(), action, target or "", actor_user_id, json.dumps(details) if details else None),
    )


def deliver_pending() -> int:
    """Copy queued entries into the access audit log. Failures are reported and retried later."""
    if not account_db.database().is_file():
        return 0
    pending: list[sqlite3.Row] = []
    try:
        with store.connection(write=True) as db:
            pending = db.execute("SELECT * FROM admin_audit_outbox ORDER BY id").fetchall()
            if not pending:
                return 0
            with account_db.connection(write=True) as adb:
                for entry in pending:
                    details = json.loads(entry["details"]) if entry["details"] else None
                    account_db.audit(adb, entry["action"], entry["target"] or None, entry["actor_user_id"], details, at=entry["at"])
            db.execute("DELETE FROM admin_audit_outbox WHERE id<=?", (pending[-1]["id"],))
    except Exception as error:  # A committed admin change must never become an error response.
        _report_failure(pending, error)
        return 0
    return len(pending)


def _report_failure(pending: list[sqlite3.Row], error: Exception) -> None:
    reason = sanitize_error_text(str(error), "Unknown error.")
    lines = [f"[audit] could not deliver {len(pending) or 'queued'} admin audit entries to the access database "
             f"({error.__class__.__name__}: {reason}); they remain queued in admin_audit_outbox and will be retried.\n"]
    for entry in pending:
        lines.append(f"[audit] queued id={entry['id']} at={entry['at']} action={entry['action']} target={entry['target']} "
                     f"actor={entry['actor_user_id']} details={entry['details']}\n")
    sys.stderr.write("".join(lines))
