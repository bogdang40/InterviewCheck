"""Capture lifecycle and editable role templates."""
from uuid import UUID

from fastapi import APIRouter, HTTPException, Request

from . import access, role_kits, store
from .models import AnswerInput, RoleInput

router = APIRouter()


@router.post("/sessions/{sid}/finish")
def finish(sid: UUID):
    key = str(sid)
    with store.connection(write=True) as db:
        store.get_summary(db, key)
        if db.execute("SELECT 1 FROM session_drafts WHERE session_id=?", (key,)).fetchone():
            raise HTTPException(409, "Publish or discard the saved exchange draft before finishing.")
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


@router.get("/roles/{rid}")
def get_role(rid: UUID):
    with store.connection() as db:
        row = db.execute("SELECT * FROM roles WHERE id=?", (str(rid),)).fetchone()
        if row is None:
            raise HTTPException(404, "Role does not exist.")
        return role_kits.role_row(row)


@router.put("/roles/{rid}")
async def edit_role(rid: UUID, item: RoleInput, request: Request):
    if item.id is not None and item.id != rid:
        raise HTTPException(409, "The role ID differs from the requested role.")
    _, actor_email = await access.optional_actor(request)
    with store.connection(write=True) as db:
        return role_kits.update_role(db, str(rid), item, created_by=actor_email)


@router.post("/sessions/{sid}/preview")
def session_preview(sid: UUID, item: AnswerInput):
    with store.connection() as db:
        context = store.capture_context(db, str(sid))
    return role_kits.compare_answer(item, context["permitted_sources"])
