"""Permanently delete one interview and every row that belongs to it."""

import sqlite3

# Children first, so the delete also succeeds on a connection without foreign keys.
# Tables created lazily by optional features may be absent and are skipped.
SESSION_CHILD_TABLES = (
    "panel_decisions",
    "answer_review_events",
    "session_scorecards",
    "session_handoff_notes",
    "session_anonymizations",
    "legacy_privacy_holds",
    "retention_read_holds",
    "session_assignments",
    "session_tags",
    "session_drafts",
    "ats_access_versions",
    "note_exports",
    "transcript_imports",
)
SESSION_TAIL_TABLES = ("answers", "session_context", "session_trash")


def _has_table(db: sqlite3.Connection, name: str) -> bool:
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def purge_session(db: sqlite3.Connection, sid: str) -> None:
    """Delete the session inside the caller's write transaction."""
    for table in SESSION_CHILD_TABLES:
        if _has_table(db, table):
            db.execute(f"DELETE FROM {table} WHERE session_id=?", (sid,))
    if _has_table(db, "answer_history"):
        db.execute("DELETE FROM answer_history WHERE answer_id IN (SELECT id FROM answers WHERE session_id=?)", (sid,))
    for table in SESSION_TAIL_TABLES:
        db.execute(f"DELETE FROM {table} WHERE session_id=?", (sid,))
    db.execute("DELETE FROM sessions WHERE id=?", (sid,))
