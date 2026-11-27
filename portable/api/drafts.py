"""Explicitly saved work in progress. Publishing is the only route that creates evidence."""

import hmac
import json
import secrets
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, HTTPException
from pydantic import Field

from . import deferred_items, session_privacy, lineage, store
from .models import CreateAnswerInput, DeferredQuestionGuard, Fingerprint, Input, OriginInput, RequestID

router = APIRouter()


class PartialSource(Input):
    label: Annotated[str, Field(max_length=180)] = ""
    text: Annotated[str, Field(max_length=24000)] = ""
    permitted: bool = False


class DraftInput(OriginInput):
    deferred_question: DeferredQuestionGuard | None = None
    deferred_draft_token: Fingerprint | None = None
    id: RequestID
    expected_revision: int = Field(ge=0)
    question: Annotated[str, Field(max_length=4000)] = ""
    answer: Annotated[str, Field(max_length=24000)] = ""
    references: list[PartialSource] = Field(default_factory=list, max_length=12)


class Publish(CreateAnswerInput):
    deferred_draft_token: Fingerprint | None = None
    id: RequestID
    expected_revision: int = Field(ge=1)


class Discard(Input):
    deferred_question: DeferredQuestionGuard | None = None
    deferred_draft_token: Fingerprint | None = None
    id: RequestID
    expected_revision: int = Field(ge=1)


def stale():
    return HTTPException(
        409,
        "The saved draft changed in another view. Review the saved version before replacing it.",
        headers={"X-InterviewCheck-Conflict": "draft-revision"},
    )


def get(db, sid, *, portable=False, include_deferred=True):
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
        **_draft_link(db, str(sid), row, portable, include_deferred),
    }


def _draft_link(db, sid, row, portable, include):
    if not include:
        return {}
    qid, revision = row["deferred_question_id"], row["deferred_revision_id"]
    if (qid is None) != (revision is None):
        raise deferred_items.UnreadableQuestion(409, "The saved question binding is incomplete. Inspect the SQLite backup.")
    if qid is None:
        return {}
    if portable:
        return {"deferred_question_id": qid, "deferred_revision_id": revision}
    return {"deferred_question": deferred_items.draft_guard(db, sid, qid, revision),
            "deferred_draft_token": row["deferred_draft_token"]}


def _check_lifetime(current, item):
    expected = current.get("deferred_draft_token") if current else None
    supplied = item.deferred_draft_token
    if expected is not None or supplied is not None or (current and current.get("deferred_question")):
        if not expected or not supplied or not hmac.compare_digest(expected, supplied):
            raise deferred_items.conflict("The saved draft was replaced. Read the current draft before continuing.")


def _binding(current, item, *, publish=False):
    _check_lifetime(current, item)
    prior = current.get("deferred_question") if current else None
    supplied = item.deferred_question
    if prior and supplied is None:
        raise deferred_items.conflict("This draft belongs to a deferred question. Reload its saved binding before continuing.")
    if current and supplied and (not prior or str(supplied.id) != prior["id"]):
        raise deferred_items.conflict("This saved draft belongs to a different capture. Keep it separate.")
    if publish and prior and supplied.model_dump(mode="json") != prior:
        raise deferred_items.conflict("Save the draft against the reconfirmed question before publishing it.")
    return supplied


@router.get("/sessions/{sid}/draft")
def read(sid: UUID):
    with store.connection() as db:
        deferred_items.access_session(db, str(sid))
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
        if current and current["id"] != aid:
            if item.deferred_question:
                raise deferred_items.conflict("A different draft is already saved. Publish or discard it first.")
            raise stale()
        binding = _binding(current, item)
        parent, slot = lineage.resolve(db, key, aid, item, current)
        linked = deferred_items.checked_binding(db, key, binding, item.question, parent, slot) if binding else None
        if current:
            if (
                current["question"],
                current["answer"],
                current["references"],
                current["parent_answer_id"],
                current["planned_slot"],
                current.get("deferred_question"),
            ) == (
                item.question,
                item.answer,
                refs,
                parent,
                slot,
                binding.model_dump(mode="json") if binding else None,
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
            """INSERT INTO session_drafts(session_id,id,question,answer,refs,updated_at,parent_answer_id,planned_slot,
                   deferred_question_id,deferred_revision_id,deferred_draft_token) VALUES(?,?,?,?,?,?,?,?,?,?,?)
                   ON CONFLICT(session_id) DO UPDATE SET question=excluded.question,answer=excluded.answer,
                   refs=excluded.refs,updated_at=excluded.updated_at,parent_answer_id=excluded.parent_answer_id,
                   planned_slot=excluded.planned_slot,deferred_question_id=excluded.deferred_question_id,
                   deferred_revision_id=excluded.deferred_revision_id,revision=session_drafts.revision+1""",
            (
                key,
                aid,
                item.question,
                item.answer,
                json.dumps(refs, ensure_ascii=False),
                store.timestamp(),
                parent,
                slot,
                linked["id"] if linked else None,
                linked["revision_id"] if linked else None,
                secrets.token_hex(32) if linked else None,
            ),
        )
        return get(db, sid)


@router.post("/sessions/{sid}/draft/discard")
def discard(sid: UUID, item: Discard):
    with store.connection(write=True) as db:
        deferred_items.access_session(db, str(sid))
        current = get(db, sid)
        _check_lifetime(current, item)
        if current is None and item.deferred_question:
            raise deferred_items.conflict("There is no current linked draft to discard.")
        if current:
            if current["id"] != str(item.id) or current["revision"] != item.expected_revision:
                raise stale()
            prior = current.get("deferred_question")
            supplied = item.deferred_question.model_dump(mode="json") if item.deferred_question else None
            if supplied != prior:
                raise deferred_items.conflict("The saved draft binding changed. Reload the draft before discarding it.")
            db.execute("DELETE FROM session_drafts WHERE session_id=?", (str(sid),))
    return {"discarded": True}


@router.post("/sessions/{sid}/draft/publish")
def publish(sid: UUID, item: Publish):
    key, aid = str(sid), str(item.id)
    with store.connection(write=True) as db:
        session = store.capture_context(db, key)
        if item.deferred_draft_token is not None and item.deferred_question is None:
            raise deferred_items.conflict("A linked draft token requires its deferred question binding.")
        current = get(db, sid)
        if current and current["id"] == aid:
            if current["revision"] != item.expected_revision:
                raise stale()
            binding = _binding(current, item, publish=True)
            if binding:
                item = item.model_copy(update={"deferred_question": binding})
            if lineage.FIELDS.isdisjoint(item.model_fields_set):
                item = item.model_copy(update={name: current[name] for name in lineage.FIELDS})
            db.execute("DELETE FROM session_drafts WHERE session_id=?", (key,))
        elif not db.execute("SELECT 1 FROM answers WHERE id=? AND session_id=?", (aid, key)).fetchone():
            raise stale()
        return store.write_answer(db, key, item, session=session)
