"""Capture lifecycle and editable role templates."""
import json
from uuid import UUID

from fastapi import APIRouter, HTTPException

from . import store
from .models import RoleInput

router = APIRouter()


@router.post("/sessions/{sid}/finish")
def finish(sid: UUID):
    key = str(sid)
    with store.connection(write=True) as db:
        store.get_summary(db, key)
        db.execute("""INSERT INTO session_context(session_id,ended_at) VALUES (?,?)
            ON CONFLICT(session_id) DO UPDATE SET ended_at=COALESCE(ended_at,excluded.ended_at)""",
                   (key, store.timestamp()))
        return store.get_session(db, key)


@router.post("/sessions/{sid}/reopen")
def reopen(sid: UUID):
    key = str(sid)
    with store.connection(write=True) as db:
        if not store.get_summary(db, key)["consent"]:
            raise HTTPException(409, "This interview has no recorded notice for capture.")
        db.execute("UPDATE session_context SET ended_at=NULL WHERE session_id=?", (key,))
        return store.get_session(db, key)


@router.put("/roles/{rid}")
def edit_role(rid: UUID, item: RoleInput):
    if item.id is not None and item.id != rid:
        raise HTTPException(409, "The role ID differs from the requested role.")
    with store.connection(write=True) as db:
        cursor = db.execute("UPDATE roles SET name=?,description=?,questions=? WHERE id=?",
                            (item.name, item.description, json.dumps(item.questions, ensure_ascii=False), str(rid)))
        if not cursor.rowcount:
            raise HTTPException(404, "Role does not exist.")
        return store.role_row(db.execute("SELECT * FROM roles WHERE id=?", (str(rid),)).fetchone())
