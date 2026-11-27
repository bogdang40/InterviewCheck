"""Portable follow up content and graph validation. Private edit and replay tokens remain local."""
from typing import Annotated, Literal
import json

from fastapi import HTTPException
from pydantic import StringConstraints

from . import deferred_fulfillment, deferred_items
from .deferred_text import SelectedQuestion
from .backup_types import ID, Record, ReviewStamp

Revision = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{32}$")]
Digest = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
FIELDS = ("id", "parent_answer_id", "question", "status", "needs_reconfirmation", "material_sha256",
          "revision_id", "created_at", "child_answer_id")


class FulfillmentFact(Record):
    question_id: ID
    parent_answer_id: ID
    child_answer_id: ID
    question_sha256: Digest


class DeferredQuestion(Record):
    id: ID
    parent_answer_id: ID
    question: SelectedQuestion
    status: Literal["pending", "dismissed", "fulfilled"]
    needs_reconfirmation: bool
    material_sha256: Digest
    revision_id: Revision
    created_at: ReviewStamp
    child_answer_id: ID | None


def records(db, sid, byte_limit):
    if db.execute("""SELECT count(*) FROM sqlite_master WHERE type='table'
                     AND name IN ('deferred_questions','deferred_publications')""").fetchone()[0] != 2:
        raise deferred_items.UnreadableQuestion(409, "Restart InterviewCheck to initialize deferred question storage.")
    rows = db.execute(f"""SELECT {','.join(FIELDS)} FROM deferred_questions
                          WHERE session_id=? ORDER BY created_at,id""", (sid,))
    out, size = [], 0
    for row in rows:
        value = dict(row)
        value["needs_reconfirmation"] = bool(value["needs_reconfirmation"])
        size += len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()) + 1
        if size > byte_limit:
            raise HTTPException(413, "Deferred questions exceed the JSON backup limit. Use a consistent SQLite backup.")
        out.append(value)
    return out


def _parent_material(session, answer):
    context = {name: getattr(session, name) for name in ("candidate", "role", "role_id", "created_at", "policy", "consent", "planned_questions")}
    context["permitted_sources"] = [s.model_dump() for s in session.permitted_sources]
    return deferred_items.material(context, answer.model_dump(exclude_none=True))


def validate(session):
    queued = {q.id: q for q in session.deferred_questions}
    draft = session.draft
    linked = draft is not None and (draft.deferred_question_id is not None or draft.deferred_revision_id is not None)
    origins = {a.id: a.deferred_origin for a in session.answers if a.deferred_origin is not None}
    if not queued and not linked and not origins:
        return
    if not session.consent or session.privacy is None or session.privacy.state != "unmarked":
        raise ValueError("Protected or archive-only interviews cannot contain deferred questions.")
    by_id = {answer.id: answer for answer in session.answers}
    used_children, materials = set(), {}
    for q in queued.values():
        if q.parent_answer_id not in by_id or (q.status == "fulfilled") != (q.child_answer_id is not None):
            raise ValueError("A deferred question refers to a missing or inconsistent exchange.")
        if q.status == "fulfilled":
            child = by_id.get(q.child_answer_id)
            if (q.needs_reconfirmation or child is None or child.id in used_children or
                    child.parent_answer_id != q.parent_answer_id or child.planned_slot is not None or
                    (child.revision == 1 and child.question != q.question)):
                raise ValueError("A deferred response must be its own saved child of the selected parent.")
            fact = origins.get(child.id)
            if (fact is None or fact.question_id != q.id or fact.parent_answer_id != q.parent_answer_id or
                    fact.child_answer_id != child.id or fact.question_sha256 != deferred_fulfillment.question_hash(q.question)):
                raise ValueError("The deferred response disagrees with its recorded publication fact.")
            used_children.add(child.id)
        elif not q.needs_reconfirmation:
            if q.parent_answer_id not in materials:
                materials[q.parent_answer_id] = _parent_material(session, by_id[q.parent_answer_id])
            if materials[q.parent_answer_id] != q.material_sha256:
                raise ValueError("A deferred question marked current disagrees with its parent material.")
    if set(origins) != used_children:
        raise ValueError("A published exchange refers to an unfulfilled or missing deferred question.")
    if linked:
        item = queued.get(draft.deferred_question_id)
        if (not draft.deferred_revision_id or item is None or item.status != "pending" or
                draft.parent_answer_id != item.parent_answer_id or draft.planned_slot is not None or draft.question != item.question):
            raise ValueError("The deferred draft does not match its pending question and parent.")
    session.deferred_questions.sort(key=lambda item: (item.created_at, item.id))


def collides(db, rows):
    if not rows:
        return False
    ids = json.dumps([q.id for q in rows])
    return db.execute("""SELECT 1 FROM json_each(?) q WHERE EXISTS
                         (SELECT 1 FROM deferred_questions d WHERE d.id=q.value) LIMIT 1""", (ids,)).fetchone() is not None


def restore(db, session):
    for q in session.deferred_questions:
        db.execute(f"INSERT INTO deferred_questions(session_id,{','.join(FIELDS)}) VALUES(?,?,?,?,?,?,?,?,?,?)",
                   (session.id, *(getattr(q, key) for key in FIELDS)))
    for answer in session.answers:
        fact = answer.deferred_origin
        if fact is not None:
            deferred_fulfillment.record(db, session.id, answer.id, fact.question_id, fact.parent_answer_id, fact.question_sha256)
    if session.draft and session.draft.deferred_question_id:
        db.execute("UPDATE session_drafts SET deferred_question_id=?, deferred_revision_id=? WHERE session_id=?",
                   (session.draft.deferred_question_id, session.draft.deferred_revision_id, session.id))
