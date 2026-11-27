"""Verify the selected pending questions before disclosing a plain text handoff."""
from hashlib import sha256
import hmac
import json
from uuid import UUID

from fastapi import APIRouter, HTTPException
from pydantic import Field, TypeAdapter, ValidationError, field_validator

from . import answer_identity, deferred_items, review_worksheet, store
from .deferred_text import SelectedQuestion
from .models import DeferredQuestionGuard, Fingerprint, Input


router = APIRouter(prefix="/handoff")
_question = TypeAdapter(SelectedQuestion)


class Selection(Input):
    items: list[DeferredQuestionGuard] = Field(min_length=1, max_length=50)

    @field_validator("items")
    @classmethod
    def distinct(cls, items):
        if len({item.id for item in items}) != len(items):
            raise ValueError("Select each deferred question once.")
        return items


class Verification(Selection):
    preview_sha256: Fingerprint


def _unavailable():
    return deferred_items.conflict("Selected questions changed or are unavailable. Refresh the queue and preview again.")


def _parent_proof(db, sid, parent, context):
    try:
        answer = store.get_answer(db, sid, parent)
        return answer_identity.binding_key(db, parent), deferred_items.material(context, answer)
    except (HTTPException, ValueError, TypeError, KeyError) as exc:
        # Session eligibility was checked in this same read transaction. Never identify a failing selected parent.
        raise _unavailable() from exc


def handoff(db, sid, selected, expected_digest=None):
    session = deferred_items.access_session(db, sid)
    plan = db.execute("SELECT questions,permitted_sources FROM session_context WHERE session_id=?", (sid,)).fetchone()
    try:
        context = review_worksheet.material_context(session, plan)
    except (ValueError, TypeError, KeyError) as exc:
        raise _unavailable() from exc
    versions = {str(item.id): item.version for item in selected}
    rows = db.execute("""SELECT q.id,q.session_id,q.parent_answer_id,q.revision_id,q.status,q.needs_reconfirmation,
                                q.material_sha256,
                                CASE WHEN length(CAST(q.question AS BLOB)) <= 16000 THEN q.question END AS question
                         FROM json_each(?) selection CROSS JOIN deferred_questions q
                         WHERE q.id=selection.value AND q.session_id=?
                         ORDER BY q.created_at,q.id""", (json.dumps(list(versions)), sid))
    parents, lines = {}, []
    for row in rows:
        if row["status"] != "pending" or row["needs_reconfirmation"]:
            raise _unavailable()
        parent = row["parent_answer_id"]
        if parent not in parents:
            parents[parent] = _parent_proof(db, sid, parent, context)
        key, material = parents[parent]
        if (not hmac.compare_digest(deferred_items.version_with_key(row, key), versions[row["id"]])
                or material != row["material_sha256"]):
            raise _unavailable()
        try:
            question = _question.validate_python(row["question"])
        except ValidationError as exc:
            raise _unavailable() from exc
        lines.append(f"{len(lines) + 1}. {question}\n")
    if len(lines) != len(versions):
        raise _unavailable()
    text = "".join(lines)
    checksum = sha256(text.encode("utf-8")).hexdigest()
    if expected_digest is not None and not hmac.compare_digest(checksum, expected_digest):
        raise _unavailable()
    return {"text": text, "sha256": checksum}


@router.post("/preview")
def preview(sid: UUID, selection: Selection):
    with store.connection() as db:
        return handoff(db, str(sid), selection.items)


@router.post("/verify")
def verify(sid: UUID, selection: Verification):
    with store.connection() as db:
        return handoff(db, str(sid), selection.items, selection.preview_sha256)
