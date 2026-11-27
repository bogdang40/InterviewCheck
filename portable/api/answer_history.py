"""Append saved answer revisions inside the caller's write transaction."""

import json

from fastapi import HTTPException

from . import retention_visibility

SCHEMA = """
CREATE TABLE IF NOT EXISTS answer_history (
    answer_id TEXT NOT NULL REFERENCES answers(id) ON DELETE CASCADE,
    revision INTEGER NOT NULL CHECK (revision >= 1),
    kind TEXT NOT NULL CHECK (kind IN ('baseline', 'answer_edit', 'review_update')),
    saved_at TEXT,
    actor TEXT,
    snapshot TEXT NOT NULL,
    PRIMARY KEY (answer_id, revision),
    CHECK ((kind = 'baseline' AND saved_at IS NULL AND actor IS NULL)
        OR (kind <> 'baseline' AND saved_at IS NOT NULL))
) WITHOUT ROWID
"""

SNAPSHOT_FIELDS = (
    "question", "answer", "references", "result", "disposition", "note", "parent_answer_id", "planned_slot",
)


def snapshot(answer):
    return {name: answer[name] for name in SNAPSHOT_FIELDS}


def record(db, answer, kind, *, saved_at=None, actor=None):
    db.execute(
        "INSERT INTO answer_history (answer_id, revision, kind, saved_at, actor, snapshot) VALUES (?, ?, ?, ?, ?, ?)",
        (answer["id"], answer["revision"], kind, saved_at,
         json.dumps(actor) if actor else None, json.dumps(snapshot(answer), ensure_ascii=False)),
    )


def baseline_revision(db, aid):
    row = db.execute("SELECT revision FROM answer_history WHERE answer_id=? ORDER BY revision LIMIT 1", (aid,)).fetchone()
    return row["revision"] if row else None


def has_revision(db, aid, revision):
    return db.execute("SELECT 1 FROM answer_history WHERE answer_id=? AND revision=?", (aid, revision)).fetchone() is not None


def current_revision(db, sid, aid):
    row = db.execute("""SELECT a.revision FROM answers a JOIN active_sessions s ON s.id=a.session_id
                        WHERE a.id=? AND a.session_id=?""", (aid, sid)).fetchone()
    if row is None:
        retention_visibility.require_available(db, sid)
        raise HTTPException(404, "Answer does not exist in this session.")
    return row["revision"]


def metadata(row):
    return {"revision": row["revision"], "kind": row["kind"], "saved_at": row["saved_at"],
            "actor": json.loads(row["actor"]) if row["actor"] else None}


def baseline(revision):
    return {"revision": revision, "kind": "baseline", "saved_at": None, "actor": None}


def page(db, sid, aid, before, limit):
    current = current_revision(db, sid, aid)
    first = baseline_revision(db, aid) or current
    ceiling = current if before is None else min(current, before - 1)
    rows = db.execute("""SELECT revision, kind, saved_at, actor FROM answer_history
                         WHERE answer_id=? AND revision<=? ORDER BY revision DESC LIMIT ?""",
                      (aid, ceiling, limit + 1)).fetchall()
    entries = [metadata(row) for row in rows]
    if ceiling == current and (not entries or entries[0]["revision"] != current):
        entries.insert(0, baseline(current))
    return {"current_revision": current, "baseline_revision": first,
            "entries": entries[:limit],
            "next_before_revision": entries[limit - 1]["revision"] if len(entries) > limit else None}


def saved_revision(db, aid, revision):
    row = db.execute("SELECT revision, kind, saved_at, actor, snapshot FROM answer_history WHERE answer_id=? AND revision=?",
                     (aid, revision)).fetchone()
    return {**metadata(row), "snapshot": json.loads(row["snapshot"])} if row else None
