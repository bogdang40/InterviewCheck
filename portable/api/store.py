"""Local SQLite storage. A transaction owns each read or mutation."""
import json
import os
from contextlib import contextmanager, closing
from datetime import datetime, timezone
from pathlib import Path
import sqlite3
from uuid import uuid4

from fastapi import HTTPException

from .evidence import compare
from .models import AnswerInput, ReviewInput, RoleInput, SessionInput

DEFAULT_DB = Path(__file__).resolve().parents[1] / "data" / "review.sqlite3"
SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (
 id TEXT PRIMARY KEY, candidate TEXT NOT NULL, role TEXT NOT NULL, policy TEXT NOT NULL,
 consent INTEGER NOT NULL, created_at TEXT NOT NULL, legacy TEXT
);
CREATE TABLE IF NOT EXISTS answers (
 id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id), question TEXT NOT NULL,
 answer TEXT NOT NULL, refs TEXT NOT NULL, result TEXT NOT NULL, status TEXT NOT NULL,
 disposition TEXT NOT NULL DEFAULT 'pending', note TEXT NOT NULL DEFAULT '', legacy TEXT
);
CREATE INDEX IF NOT EXISTS answer_session ON answers(session_id);
CREATE TABLE IF NOT EXISTS note_exports (
 id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id), provider TEXT NOT NULL,
 remote_id TEXT NOT NULL, recipient TEXT NOT NULL, draft TEXT NOT NULL, state TEXT NOT NULL,
 created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS export_session ON note_exports(session_id);
CREATE TABLE IF NOT EXISTS roles (
 id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT NOT NULL, questions TEXT NOT NULL, legacy TEXT
);
"""
SUMMARY = """
SELECT s.id,s.candidate,s.role,s.policy,s.consent,s.created_at,COUNT(a.id) answer_count,
 COUNT(CASE WHEN a.status='match' AND a.disposition='pending' THEN 1 END) review_count
FROM sessions s LEFT JOIN answers a ON a.session_id=s.id
"""


def db_path():
    return Path(os.environ.get("INTERVIEWCHECK_DB", DEFAULT_DB))


def initialize(path):
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.exists():
        try:
            os.close(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
        except FileExistsError:
            pass  # Another local process initialized the same store.
    with closing(sqlite3.connect(path)) as db:
        db.execute("PRAGMA journal_mode=WAL")
        db.executescript(SCHEMA)


@contextmanager
def connection(path=None, *, write=False):
    with closing(sqlite3.connect(path or db_path(), timeout=10)) as db:
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        with db:
            db.execute("BEGIN IMMEDIATE" if write else "BEGIN")
            yield db


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def summary(row):
    return {**dict(row), "consent": bool(row["consent"])}


def get_summary(db, key):
    row = db.execute(SUMMARY + " WHERE s.id=? GROUP BY s.id", (key,)).fetchone()
    if row is None:
        raise HTTPException(404, "Session does not exist.")
    return summary(row)


def get_answer(db, key, aid):
    row = db.execute("SELECT * FROM answers WHERE session_id=? AND id=?", (key, aid)).fetchone()
    if row is None:
        raise HTTPException(404, "Answer does not exist in this session.")
    return answer_row(row)


def answer_row(row):
    record = {name: row[name] for name in ("id", "question", "answer", "disposition", "note")}
    record.update(references=json.loads(row["refs"]), result=json.loads(row["result"]))
    if row["legacy"]:
        record["legacy"] = json.loads(row["legacy"])
    return record


def get_session(db, key):
    item = get_summary(db, key)
    item["answers"] = [answer_row(row) for row in db.execute(
        "SELECT * FROM answers WHERE session_id=? ORDER BY rowid", (key,))]
    legacy = db.execute("SELECT legacy FROM sessions WHERE id=?", (key,)).fetchone()[0]
    if legacy:
        item["legacy"] = json.loads(legacy)
    return item


def create_session(db, item: SessionInput):
    key = str(item.id or uuid4())
    existing = db.execute("SELECT * FROM sessions WHERE id=?", (key,)).fetchone()
    if existing:
        if any(existing[field] != getattr(item, field) for field in ("candidate", "role", "policy", "consent")):
            raise HTTPException(409, "The session ID already belongs to different content.")
    else:
        db.execute("INSERT INTO sessions(id,candidate,role,policy,consent,created_at) VALUES (?,?,?,?,?,?)",
                   (key, item.candidate, item.role, item.policy, item.consent, timestamp()))
    return get_session(db, key)


def write_answer(db, key, item: AnswerInput, replace_id=None):
    if not get_summary(db, key)["consent"]:
        raise HTTPException(409, "This archived session has no recorded notice. Create a new session for capture.")
    aid = str(replace_id or item.id or uuid4())
    if replace_id and item.id and aid != str(item.id):
        raise HTTPException(409, "The body and route answer IDs differ.")
    current = db.execute("SELECT * FROM answers WHERE id=?", (aid,)).fetchone()
    refs = json.dumps([ref.model_dump() for ref in item.references], ensure_ascii=False)
    if current is not None and current["session_id"] == key:
        same_input = (current["question"], current["answer"], json.loads(current["refs"])) == (
            item.question, item.answer, json.loads(refs))
        fresh = not (current["legacy"] and json.loads(current["result"]).get("archived"))
        if same_input and fresh:
            return answer_row(current)
    if replace_id and (current is None or current["session_id"] != key):
        raise HTTPException(404, "Answer does not exist in this session.")
    if current and not replace_id:
        raise HTTPException(409, "The answer ID already belongs to different content.")
    result = compare(item.question, item.answer, item.references)
    fields = (item.question, item.answer, refs, json.dumps(result), result["status"])
    if replace_id:
        note = current["note"]
        if note and not note.startswith("Note from an earlier answer version:\n"):
            note = "Note from an earlier answer version:\n" + note
        db.execute("UPDATE answers SET question=?,answer=?,refs=?,result=?,status=?,disposition='pending',note=? WHERE id=?",
                   (*fields, note, aid))
    else:
        db.execute("INSERT INTO answers(question,answer,refs,result,status,id,session_id) VALUES (?,?,?,?,?,?,?)",
                   (*fields, aid, key))
    return get_answer(db, key, aid)


def update_review(db, key, aid, review: ReviewInput):
    db.execute("UPDATE answers SET disposition=?,note=? WHERE session_id=? AND id=?",
               (review.disposition, review.note, key, aid))
    return get_answer(db, key, aid)


def role_row(row):
    role = {**dict(row), "questions": json.loads(row["questions"])}
    if role["legacy"]:
        role["legacy"] = json.loads(role["legacy"])
    else:
        del role["legacy"]
    return role


def create_role(db, role: RoleInput):
    key = str(role.id or uuid4())
    fields = (role.name, role.description, json.dumps(role.questions, ensure_ascii=False))
    existing = db.execute("SELECT * FROM roles WHERE id=?", (key,)).fetchone()
    if existing:
        if tuple(existing[f] for f in ("name", "description", "questions")) != fields:
            raise HTTPException(409, "The role ID already belongs to different content.")
    else:
        db.execute("INSERT INTO roles(id,name,description,questions) VALUES (?,?,?,?)", (key, *fields))
    return role_row(db.execute("SELECT * FROM roles WHERE id=?", (key,)).fetchone())
