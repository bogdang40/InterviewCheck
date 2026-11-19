"""Reversible interview removal and version-bound permanent deletion."""

from uuid import UUID, uuid4

from fastapi import APIRouter, HTTPException, Query

from . import bulk_operations, store
from .models import Input, RequestID

router = APIRouter()

BIN = """SELECT s.id,s.candidate,s.role,s.created_at,t.trashed_at,t.operation_version,
        (SELECT count(*) FROM answers a WHERE a.session_id=s.id) answer_count
        FROM session_trash t JOIN sessions s ON s.id=t.session_id"""


class Version(Input):
    operation_version: RequestID


class Purge(Version):
    confirm_session_id: RequestID


def active_marker(db, key, version):
    row = db.execute("SELECT operation_version FROM session_trash WHERE session_id=?", (key,)).fetchone()
    if row is None:
        raise HTTPException(404, "This interview is no longer in Trash.")
    if row["operation_version"] != str(version):
        raise HTTPException(409, "This interview was moved again. Refresh Trash before continuing.")


@router.get("/trash")
def list_trash(
    page: int = Query(ge=1, le=10_000_000, default=1), page_size: int = Query(ge=1, le=100, default=25)
):
    with store.connection() as db:
        total = db.execute("SELECT count(*) FROM session_trash").fetchone()[0]
        actual_page = min(page, max(1, (total + page_size - 1) // page_size))
        items = db.execute(
            BIN + " ORDER BY t.trashed_at DESC,t.session_id LIMIT ? OFFSET ?",
            (page_size, (actual_page - 1) * page_size),
        )
        return {
            "items": [dict(row) for row in items],
            "page": actual_page,
            "page_size": page_size,
            "total": total,
        }


@router.post("/sessions/{sid}/trash")
def move(sid: UUID):
    key = str(sid)
    with store.connection(write=True) as db:
        if not db.execute("SELECT 1 FROM sessions WHERE id=?", (key,)).fetchone():
            raise HTTPException(404, "Interview not found.")
        db.execute("DELETE FROM ats_access_versions WHERE session_id=?", (key,))
        # Retrying the same move before restore preserves the original confirmation version.
        db.execute(
            """INSERT INTO session_trash(session_id,trashed_at,operation_version) VALUES(?,?,?)
                      ON CONFLICT(session_id) DO NOTHING""",
            (key, store.timestamp(), str(uuid4())),
        )
        return dict(db.execute(BIN + " WHERE s.id=?", (key,)).fetchone())


@router.post("/trash/{sid}/restore")
def restore(sid: UUID, item: Version):
    key = str(sid)
    with store.connection(write=True) as db:
        active_marker(db, key, item.operation_version)
        db.execute("DELETE FROM session_trash WHERE session_id=?", (key,))
        return store.get_summary(db, key)


@router.post("/trash/{sid}/purge")
def purge(sid: UUID, item: Purge):
    key = str(sid)
    if item.confirm_session_id != sid:
        raise HTTPException(422, "The confirmation must identify the selected interview.")
    with store.connection(write=True) as db:
        active_marker(db, key, item.operation_version)
        bulk_operations.ensure_table(db)
        for table in ("answer_review_events", "session_scorecards", "session_handoff_notes"):
            if db.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)
            ).fetchone():
                db.execute(f"DELETE FROM {table} WHERE session_id=?", (key,))
        # All statements share the marker check and a single write transaction.
        # A future child table with a foreign key makes deletion fail atomically.
        for statement in (
            "DELETE FROM session_tags WHERE session_id=?",
            "DELETE FROM session_drafts WHERE session_id=?",
            "DELETE FROM note_exports WHERE session_id=?",
            "DELETE FROM transcript_imports WHERE session_id=?",
            "DELETE FROM answers WHERE session_id=?",
            "DELETE FROM session_context WHERE session_id=?",
            "DELETE FROM session_trash WHERE session_id=?",
            "DELETE FROM sessions WHERE id=?",
        ):
            db.execute(statement, (key,))
    return {"purged": True}
