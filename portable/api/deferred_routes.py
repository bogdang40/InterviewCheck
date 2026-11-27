"""Read and maintain selected questions without starting capture or replacing a saved draft."""
import hmac
import secrets
from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Query
from pydantic import model_validator

from . import deferred_items as items, store
from .models import Fingerprint, Input, Question, RequestID

router = APIRouter(prefix="/sessions/{sid}/deferred-questions", tags=["interview-follow-ups"])


class Add(Input):
    id: RequestID
    parent_answer_id: RequestID
    question: Question
    expected_material: Fingerprint


class Change(Input):
    action: Literal["dismiss", "reopen", "reconfirm"]
    expected_version: Fingerprint
    expected_material: Fingerprint | None = None

    @model_validator(mode="after")
    def confirm_parent(self):
        if self.action != "dismiss" and self.expected_material is None:
            raise ValueError("Review the current parent material first.")
        return self


@router.get("")
def listing(sid: UUID, status: Literal["all", "pending", "dismissed", "fulfilled"] = "all",
            page: int = Query(1, ge=1, le=2**31-1), page_size: int = Query(20, ge=1, le=100)):
    key = str(sid)
    with store.connection() as db:
        items.access_session(db, key)
        counts = dict(db.execute("SELECT status,count(*) FROM deferred_questions WHERE session_id=? GROUP BY status", (key,)))
        total = sum(counts.values()) if status == "all" else counts.get(status, 0)
        actual = min(page, max(1, (total + page_size - 1) // page_size))
        scope, params = ("session_id=?", (key,)) if status == "all" else ("session_id=? AND status=?", (key, status))
        rows = db.execute(f"""SELECT * FROM deferred_questions WHERE {scope}
                              ORDER BY created_at,id LIMIT ? OFFSET ?""", (*params, page_size, (actual-1)*page_size))
        return {"items": [items.public(db, r) for r in rows], "total": total, "pending_count": counts.get("pending", 0),
                "page": actual, "page_size": page_size}


@router.get("/{qid}")
def read(sid: UUID, qid: UUID):
    with store.connection() as db:
        items.access_session(db, str(sid))
        return items.public(db, items.find(db, str(sid), str(qid)))


@router.post("", status_code=201)
def add(sid: UUID, payload: Add):
    sid, qid, parent = str(sid), str(payload.id), str(payload.parent_answer_id)
    with store.connection(write=True) as db:
        session = items.access_session(db, sid)
        material = items.checked_material(db, sid, parent, payload.expected_material)
        existing = db.execute("SELECT * FROM deferred_questions WHERE id=?", (qid,)).fetchone()
        if existing:
            if (existing["session_id"], existing["parent_answer_id"], existing["question"]) == (sid, parent, payload.question):
                return items.public(db, existing)
            raise items.conflict("This deferred question ID is already in use.")
        if session["ended_at"]:
            raise items.conflict("Reopen the interview before keeping a new question.")
        db.execute("""INSERT INTO deferred_questions(id,session_id,parent_answer_id,question,status,needs_reconfirmation,
                      material_sha256,revision_id,created_at) VALUES(?,?,?,?,'pending',0,?,?,?)""",
                   (qid, sid, parent, payload.question, material, secrets.token_hex(16), store.timestamp()))
        return items.public(db, items.find(db, sid, qid))


@router.patch("/{qid}")
def change(sid: UUID, qid: UUID, payload: Change):
    sid, qid = str(sid), str(qid)
    with store.connection(write=True) as db:
        items.access_session(db, sid, open_only=True)
        row = items.find(db, sid, qid)
        if not hmac.compare_digest(payload.expected_version, items.token(db, row)):
            raise items.conflict("The deferred question changed. Reload it before continuing.")
        if row["status"] == "fulfilled":
            raise items.conflict("This question already has a recorded child exchange.")
        if payload.action == "dismiss":
            if db.execute("SELECT 1 FROM session_drafts WHERE deferred_question_id=?", (qid,)).fetchone():
                raise items.conflict("Discard or publish the linked draft before dismissing this question.")
            if row["status"] == "pending":
                db.execute("UPDATE deferred_questions SET status='dismissed',revision_id=? WHERE id=?", (secrets.token_hex(16), qid))
        else:
            if (payload.action == "reopen") != (row["status"] == "dismissed"):
                raise items.conflict("The selected action does not match the current question state.")
            material = items.checked_material(db, sid, row["parent_answer_id"], payload.expected_material)
            if row["status"] != "pending" or row["needs_reconfirmation"] or material != row["material_sha256"]:
                db.execute("""UPDATE deferred_questions SET status='pending',needs_reconfirmation=0,
                              material_sha256=?,revision_id=? WHERE id=?""", (material, secrets.token_hex(16), qid))
        return items.public(db, items.find(db, sid, qid))
