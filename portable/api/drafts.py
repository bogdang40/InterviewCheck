"""Explicitly saved work in progress. Publishing is the only route that creates evidence."""

import json
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, HTTPException
from pydantic import Field

from . import session_privacy, lineage, store
from .models import AnswerInput, Input, OriginInput, RequestID

router = APIRouter()


class PartialSource(Input):
    label: Annotated[str, Field(max_length=180)] = ""
    text: Annotated[str, Field(max_length=24000)] = ""
    permitted: bool = False


class DraftInput(OriginInput):
    id: RequestID
    expected_revision: int = Field(ge=0)
    question: Annotated[str, Field(max_length=4000)] = ""
    answer: Annotated[str, Field(max_length=24000)] = ""
    references: list[PartialSource] = Field(default_factory=list, max_length=12)


class Publish(AnswerInput):
    id: RequestID
    expected_revision: int = Field(ge=1)


class Discard(Input):
    id: RequestID
    expected_revision: int = Field(ge=1)


def stale():
    return HTTPException(
        409,
        "The saved draft changed in another view. Review the saved version before replacing it.",
        headers={"X-InterviewCheck-Conflict": "draft-revision"},
    )


def get(db, sid):
    row = db.execute("SELECT * FROM session_drafts WHERE session_id=?", (str(sid),)).fetchone()
    if not row:
        return None
    return {
        **{
            k: row[k]
            for k in (
                "id",
                "revision",
                "updated_at",
                "question",
                "answer",
                "parent_answer_id",
                "planned_slot",
            )
        },
        "references": json.loads(row["refs"]),
    }


@router.get("/sessions/{sid}/draft")
def read(sid: UUID):
    with store.connection() as db:
        store.get_summary(db, str(sid))
        return get(db, sid)


@router.put("/sessions/{sid}/draft")
def save(sid: UUID, item: DraftInput):
    key, aid = str(sid), str(item.id)
    refs = [r.model_dump() for r in item.references]
    if not (item.answer or item.question or any(r["label"] or r["text"] for r in refs)):
        raise HTTPException(422, "Enter a question, an answer or a source before saving the draft.")
    with store.connection(write=True) as db:
        session = store.get_summary(db, key)
        session_privacy.require_content_writable(db, key)
        if session["ended_at"] or not session["consent"]:
            raise HTTPException(409, "Drafts require an open interview with recorded notice.")
        current = get(db, sid)
        parent, slot = lineage.resolve(db, key, aid, item, current)
        if current:
            if current["id"] != aid:
                raise stale()
            if (
                current["question"],
                current["answer"],
                current["references"],
                current["parent_answer_id"],
                current["planned_slot"],
            ) == (
                item.question,
                item.answer,
                refs,
                parent,
                slot,
            ):
                return current
            if current["revision"] != item.expected_revision:
                raise stale()
        elif (
            item.expected_revision
            or db.execute(
                "SELECT 1 FROM answers WHERE id=? UNION ALL SELECT 1 FROM session_drafts WHERE id=?",
                (aid, aid),
            ).fetchone()
        ):
            raise stale()
        db.execute(
            """INSERT INTO session_drafts(session_id,id,question,answer,refs,updated_at,parent_answer_id,planned_slot) VALUES(?,?,?,?,?,?,?,?)
                   ON CONFLICT(session_id) DO UPDATE SET question=excluded.question,answer=excluded.answer,
                   refs=excluded.refs,updated_at=excluded.updated_at,parent_answer_id=excluded.parent_answer_id,
                   planned_slot=excluded.planned_slot,revision=session_drafts.revision+1""",
            (
                key,
                aid,
                item.question,
                item.answer,
                json.dumps(refs, ensure_ascii=False),
                store.timestamp(),
                parent,
                slot,
            ),
        )
        return get(db, sid)


@router.post("/sessions/{sid}/draft/discard")
def discard(sid: UUID, item: Discard):
    with store.connection(write=True) as db:
        store.get_summary(db, str(sid))
        current = get(db, sid)
        if current:
            if current["id"] != str(item.id) or current["revision"] != item.expected_revision:
                raise stale()
            db.execute("DELETE FROM session_drafts WHERE session_id=?", (str(sid),))
    return {"discarded": True}


@router.post("/sessions/{sid}/draft/publish")
def publish(sid: UUID, item: Publish):
    key, aid = str(sid), str(item.id)
    with store.connection(write=True) as db:
        session = store.capture_context(db, key)
        current = get(db, sid)
        if current and current["id"] == aid:
            if current["revision"] != item.expected_revision:
                raise stale()
            if lineage.FIELDS.isdisjoint(item.model_fields_set):
                item = item.model_copy(update={name: current[name] for name in lineage.FIELDS})
            db.execute("DELETE FROM session_drafts WHERE session_id=?", (key,))
        elif not db.execute("SELECT 1 FROM answers WHERE id=? AND session_id=?", (aid, key)).fetchone():
            raise stale()
        return store.write_answer(db, key, item, session=session)
