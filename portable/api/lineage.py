"""Explicit exchange origins within a single interview's frozen question plan."""

from fastapi import HTTPException

FIELDS = {"parent_answer_id", "planned_slot"}


def migrate(db):
    for table in ("answers", "session_drafts"):
        # Table and column names are fixed schema identifiers.
        names = {row[1] for row in db.execute(f"PRAGMA table_info({table})")}
        if "parent_answer_id" not in names:
            db.execute(
                f"ALTER TABLE {table} ADD COLUMN parent_answer_id TEXT REFERENCES answers(id) DEFERRABLE INITIALLY DEFERRED"
            )
        if "planned_slot" not in names:
            db.execute(f"ALTER TABLE {table} ADD COLUMN planned_slot INTEGER CHECK(planned_slot>0)")


def read(item, key):
    return item.get(key) if isinstance(item, dict) else getattr(item, key, None)


def validate_origin(parent, slot, aid, size, ids):
    if parent is not None and slot is not None:
        raise ValueError("Choose either a parent exchange or a planned question slot.")
    if slot is not None and (type(slot) is not int or not 1 <= slot <= size):
        raise ValueError("The planned question slot does not exist in this interview.")
    if parent is not None:
        if parent == aid:
            raise ValueError("An exchange cannot be its own parent.")
        if parent not in ids:
            raise ValueError("The parent exchange must belong to this interview.")


def validate_graph(planned_questions, answers, draft=None):
    """Validate a complete restored session without needing insertion order. Raises ValueError."""
    parents = {}
    for answer in answers:
        aid = str(read(answer, "id"))
        parent = read(answer, "parent_answer_id")
        parents[aid] = str(parent) if parent is not None else None
    for item in [*answers, *([draft] if draft is not None else [])]:
        parent = read(item, "parent_answer_id")
        validate_origin(
            str(parent) if parent is not None else None,
            read(item, "planned_slot"),
            str(read(item, "id")),
            len(planned_questions),
            parents,
        )
    valid = set()
    for aid in parents:
        path = set()
        while aid is not None and aid not in valid:
            if aid in path:
                raise ValueError("Follow up links form a cycle.")
            path.add(aid)
            aid = parents[aid]
        valid.update(path)


def resolve(db, sid, aid, payload, current):
    if FIELDS.isdisjoint(payload.model_fields_set):
        return (current["parent_answer_id"], current["planned_slot"]) if current else (None, None)
    parent = str(payload.parent_answer_id) if payload.parent_answer_id is not None else None
    slot = payload.planned_slot
    if not parent and slot is None:
        return None, None
    plan_size = 0
    valid_parents = ()
    if slot is not None:
        row = db.execute(
            "SELECT json_array_length(questions) FROM session_context WHERE session_id=?", (sid,)
        ).fetchone()
        plan_size = row[0] if row else 0
    if parent:
        row = db.execute("SELECT id FROM answers WHERE session_id=? AND id=?", (sid, parent)).fetchone()
        valid_parents = (row[0],) if row else ()
    try:
        validate_origin(parent, slot, aid, plan_size, valid_parents)
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    if parent and current and current["parent_answer_id"] != parent:
        cycle = db.execute(
            """WITH RECURSIVE chain(id) AS (
             SELECT ? UNION SELECT a.parent_answer_id FROM chain JOIN answers a ON a.id=chain.id
             WHERE a.session_id=? AND a.parent_answer_id IS NOT NULL)
             SELECT 1 FROM chain WHERE id=? LIMIT 1""",
            (parent, sid, aid),
        ).fetchone()
        if cycle:
            raise HTTPException(422, "This parent would form a follow up cycle.")
    return parent, slot


def description(record, planned, ordinals):
    parent = record.get("parent_answer_id")
    if parent:
        sequence = ordinals.get(parent)
        return f"Follow up to question {sequence} ({parent})" if sequence else f"Parent exchange {parent}"
    slot = record.get("planned_slot")
    if slot is not None:
        return (
            f"Planned question {slot}: {planned[slot - 1]}"
            if 1 <= slot <= len(planned)
            else f"Planned question {slot}"
        )
    return None
