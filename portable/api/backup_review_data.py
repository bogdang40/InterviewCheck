"""Read and restore the assignment, panel notes, and rubric scorecard belonging to an interview backup."""
import json

from fastapi import HTTPException
from pydantic import ValidationError

from . import backup_schema as schema


class UnrepresentableReviewData(HTTPException):
    """This local record cannot be exported or identified as an exact duplicate."""


def assignment_data(db, key):
    row = db.execute(
        """SELECT assignee_email,assigned_by,priority,due_at,updated_at
           FROM session_assignments WHERE session_id=?""", (key,),
    ).fetchone()
    if row is None:
        return None
    try:
        return schema.Assignment.model_validate(dict(row)).model_dump()
    except ValidationError as exc:
        raise UnrepresentableReviewData(409, f"Interview {key} contains an assignment that this file cannot preserve. "
                                        "Use a SQLite backup or reassign the interview before exporting it.") from exc


def handoff_data(db, key):
    rows = db.execute(
        """SELECT id,author_email,category,body,created_at FROM session_handoff_notes
           WHERE session_id=? ORDER BY created_at DESC,id DESC""", (key,),
    )
    notes = []
    size = 0
    for row in rows:
        try:
            note = schema.HandoffNote.model_validate(dict(row))
        except ValidationError as exc:
            raise UnrepresentableReviewData(409, f"Interview {key} contains a handoff note that this file cannot preserve. "
                                            "Use a SQLite backup to preserve the original record.") from exc
        size += len(note.model_dump_json().encode("utf-8")) + 1
        if size > schema.LIMIT:
            raise UnrepresentableReviewData(413, f"Interview {key} exceeds the JSON backup limit. Use a SQLite backup.")
        notes.append(note.model_dump())
    return notes


def scorecard_data(db, key):
    rows = db.execute(
        """SELECT criterion_id,criterion_label,weight,rating,rationale,updated_by,updated_at
           FROM session_scorecards WHERE session_id=? ORDER BY rowid""", (key,),
    )
    items = []
    seen = set()
    size = 0
    error = (
        f"Interview {key} contains a rubric scorecard entry that this file cannot preserve. "
        "Use a SQLite backup to preserve the original record."
    )
    for row in rows:
        if len(items) >= 25:
            raise UnrepresentableReviewData(409, error)
        try:
            item = schema.ScorecardItem.model_validate(dict(row))
        except ValidationError as exc:
            raise UnrepresentableReviewData(409, error) from exc
        if item.criterion_id in seen:
            raise UnrepresentableReviewData(409, error)
        seen.add(item.criterion_id)
        size += len(item.model_dump_json().encode("utf-8")) + 1
        if size > schema.LIMIT:
            raise UnrepresentableReviewData(413, f"Interview {key} exceeds the JSON backup limit. Use a SQLite backup.")
        items.append(item.model_dump())
    return items


def has_handoff_collision(db, notes):
    if not notes:
        return False
    # The ID index includes notes in Trash. json_each avoids a bound parameter per ID.
    ids = json.dumps([n.id for n in notes])
    return db.execute(
        "SELECT 1 FROM session_handoff_notes WHERE id IN (SELECT value FROM json_each(?)) LIMIT 1", (ids,),
    ).fetchone() is not None


def restore_review_data(db, session):
    a = session.assignment
    if a is not None:
        db.execute(
            """INSERT INTO session_assignments(session_id,assignee_email,assigned_by,priority,due_at,updated_at)
               VALUES(?,?,?,?,?,?)""",
            (session.id, a.assignee_email, a.assigned_by, a.priority, a.due_at, a.updated_at),
        )
    if session.handoff_notes:
        db.executemany(
            """INSERT INTO session_handoff_notes(id,session_id,author_email,category,body,created_at)
               VALUES(?,?,?,?,?,?)""",
            ((n.id, session.id, n.author_email, n.category, n.body, n.created_at) for n in session.handoff_notes),
        )
    if session.scorecard_items:
        db.executemany(
            """INSERT INTO session_scorecards(
                   session_id,criterion_id,criterion_label,weight,rating,rationale,updated_by,updated_at
               ) VALUES(?,?,?,?,?,?,?,?)""",
            (
                (session.id, i.criterion_id, i.criterion_label, i.weight, i.rating, i.rationale, i.updated_by, i.updated_at)
                for i in session.scorecard_items
            ),
        )
