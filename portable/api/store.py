"""Local SQLite storage. A transaction owns each read or mutation."""
import json
import os
from contextlib import contextmanager, closing
from datetime import datetime, timezone
from pathlib import Path
import sqlite3
from uuid import uuid4

from fastapi import HTTPException

from . import lineage, role_kits
from .role_kits import role_row, create_role
from .models import EARLIER_ANSWER_NOTE, AnswerEdit, AnswerInput, ReviewInput, SessionInput

DEFAULT_DB = Path(__file__).resolve().parents[1] / "data" / "review.sqlite3"
SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (
 id TEXT PRIMARY KEY, candidate TEXT NOT NULL, role TEXT NOT NULL, policy TEXT NOT NULL,
 consent INTEGER NOT NULL, created_at TEXT NOT NULL, legacy TEXT
);
CREATE TABLE IF NOT EXISTS session_trash (
 session_id TEXT PRIMARY KEY REFERENCES sessions(id), trashed_at TEXT NOT NULL, operation_version TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS session_trash_order ON session_trash(trashed_at DESC,session_id);
CREATE VIEW IF NOT EXISTS active_sessions AS
 SELECT s.rowid AS rowid,s.* FROM sessions s
 WHERE NOT EXISTS (SELECT 1 FROM session_trash t WHERE t.session_id=s.id);
CREATE TABLE IF NOT EXISTS session_drafts (
 session_id TEXT PRIMARY KEY REFERENCES sessions(id), id TEXT NOT NULL UNIQUE,
 question TEXT NOT NULL, answer TEXT NOT NULL, refs TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1,
 updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS answers (
 id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id), question TEXT NOT NULL,
 answer TEXT NOT NULL, refs TEXT NOT NULL, result TEXT NOT NULL, status TEXT NOT NULL,
 disposition TEXT NOT NULL DEFAULT 'pending', note TEXT NOT NULL DEFAULT '', legacy TEXT,
 revision INTEGER NOT NULL DEFAULT 1, import_origin TEXT
);
CREATE INDEX IF NOT EXISTS answer_session ON answers(session_id);
CREATE INDEX IF NOT EXISTS pending_answer_session ON answers(session_id) WHERE status='match' AND disposition='pending';
CREATE TABLE IF NOT EXISTS transcript_imports (
 id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id),
 payload_sha256 TEXT NOT NULL, answer_ids TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS transcript_import_session ON transcript_imports(session_id);
CREATE TABLE IF NOT EXISTS ats_access_versions (
 session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE, version TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS note_exports (
 id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id), provider TEXT NOT NULL,
 remote_id TEXT NOT NULL, recipient TEXT NOT NULL, draft TEXT NOT NULL, state TEXT NOT NULL,
 created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS export_session ON note_exports(session_id);
CREATE TABLE IF NOT EXISTS roles (
 id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT NOT NULL, questions TEXT NOT NULL, legacy TEXT,
 policy TEXT NOT NULL DEFAULT '', permitted_sources TEXT NOT NULL DEFAULT '[]'
);
CREATE TABLE IF NOT EXISTS session_context (
 session_id TEXT PRIMARY KEY REFERENCES sessions(id), role_id TEXT REFERENCES roles(id),
 questions TEXT NOT NULL DEFAULT '[]', ended_at TEXT, permitted_sources TEXT NOT NULL DEFAULT '[]'
);
CREATE VIEW IF NOT EXISTS interview_catalog AS
 SELECT s.id,substr(s.candidate,1,180) candidate,substr(s.role,1,180) role,s.created_at,s.consent,c.ended_at,
 CASE WHEN c.ended_at IS NOT NULL THEN 'finished' WHEN s.consent THEN 'active' ELSE 'archived' END lifecycle,
 (SELECT count(*) FROM answers a WHERE a.session_id=s.id) answer_count,
 (SELECT count(*) FROM answers a WHERE a.session_id=s.id AND a.status='match' AND a.disposition='pending') review_count,
 (SELECT a.id FROM answers a WHERE a.session_id=s.id AND a.status='match' AND a.disposition='pending'
  ORDER BY a.rowid LIMIT 1) first_pending_answer_id
 FROM active_sessions s LEFT JOIN session_context c ON c.session_id=s.id;
"""
ALL_SUMMARY = """
SELECT s.id,s.candidate,s.role,s.policy,s.consent,s.created_at,c.role_id,c.ended_at,COUNT(a.id) answer_count,
 COUNT(CASE WHEN a.status='match' AND a.disposition='pending' THEN 1 END) review_count,
 (SELECT p.id FROM answers p
  WHERE p.session_id=s.id AND p.status='match' AND p.disposition='pending'
  ORDER BY p.rowid LIMIT 1) first_pending_answer_id
FROM sessions s LEFT JOIN session_context c ON c.session_id=s.id LEFT JOIN answers a ON a.session_id=s.id
"""
SUMMARY = ALL_SUMMARY.replace("FROM sessions s", "FROM active_sessions s")


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
        db.execute("BEGIN IMMEDIATE")
        columns = {row[1] for row in db.execute("PRAGMA table_info(answers)")}
        if "import_origin" not in columns:
            db.execute("ALTER TABLE answers ADD COLUMN import_origin TEXT")
        if "revision" not in columns:
            db.execute("ALTER TABLE answers ADD COLUMN revision INTEGER NOT NULL DEFAULT 1")
        lineage.migrate(db)
        role_kits.migrate_columns(db)
        # Freeze plans for workspaces created before role IDs were recorded. Only
        # an unambiguous title can recover the original plan from that edition.
        db.execute("""INSERT OR IGNORE INTO session_context(session_id,role_id,questions,ended_at)
            SELECT s.id,r.id,COALESCE(r.questions,'[]'),
                   strftime('%Y-%m-%dT%H:%M:%fZ',json_extract(s.legacy,'$.ended_at')/1000.0,'unixepoch')
            FROM sessions s LEFT JOIN
              (SELECT name,id,questions FROM roles GROUP BY name HAVING count(*)=1) r ON r.name=s.role
            WHERE NOT EXISTS (SELECT 1 FROM session_context c WHERE c.session_id=s.id)""")
        db.commit()


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


def get_summary(db, key, *, include_trashed=False):
    source = ALL_SUMMARY if include_trashed else SUMMARY
    row = db.execute(source + " WHERE s.id=? GROUP BY s.id", (key,)).fetchone()
    if row is None:
        raise HTTPException(404, "Session does not exist.")
    return summary(row)


def capture_context(db, key):
    summary = get_summary(db, key)
    summary["permitted_sources"] = role_kits.session_materials(db, key)
    return summary


def get_answer(db, key, aid):
    row = db.execute("""SELECT a.* FROM answers a JOIN active_sessions s ON s.id=a.session_id
                        WHERE a.session_id=? AND a.id=?""", (key, aid)).fetchone()
    if row is None:
        raise HTTPException(404, "Answer does not exist in this session.")
    return answer_row(row)


def answer_row(row):
    record = {name: row[name] for name in ("id", "question", "answer", "disposition", "note", "revision", "parent_answer_id", "planned_slot")}
    record.update(references=json.loads(row["refs"]), result=json.loads(row["result"]))
    if row["import_origin"]:
        record["import_origin"] = json.loads(row["import_origin"])
    if row["legacy"]:
        record["legacy"] = json.loads(row["legacy"])
    return record


def get_session(db, key, *, include_trashed=False):
    item = get_summary(db, key, include_trashed=include_trashed)
    draft = db.execute("SELECT id,revision,updated_at FROM session_drafts WHERE session_id=?", (key,)).fetchone()
    item["draft"] = dict(draft) if draft else None
    item["answers"] = [answer_row(row) for row in db.execute(
        "SELECT * FROM answers WHERE session_id=? ORDER BY rowid", (key,))]
    context = db.execute("SELECT questions,permitted_sources FROM session_context WHERE session_id=?", (key,)).fetchone()
    item["planned_questions"] = json.loads(context["questions"]) if context else []
    item["permitted_sources"] = json.loads(context["permitted_sources"]) if context else []
    legacy = db.execute("SELECT legacy FROM sessions WHERE id=?", (key,)).fetchone()[0]
    if legacy:
        item["legacy"] = json.loads(legacy)
    return item


def create_session(db, item: SessionInput):
    key = str(item.id or uuid4())
    existing = db.execute("SELECT * FROM sessions WHERE id=?", (key,)).fetchone()
    if existing:
        saved = capture_context(db, key)
        if "role_id" in item.model_fields_set and saved["role_id"] != (str(item.role_id) if item.role_id else None):
            raise HTTPException(409, "The session ID already belongs to a different role.")
        same_sources = (item.permitted_sources is None or
                        [material.model_dump() for material in item.permitted_sources] == saved["permitted_sources"])
        if (not same_sources or (item.policy is not None and item.policy != saved["policy"])
                or any(existing[f] != getattr(item, f) for f in ("candidate", "role", "consent"))):
            raise HTTPException(409, "The session ID already belongs to different content.")
    else:
        role_id, questions, policy, permitted = role_kits.session_defaults(db, item)
        db.execute("INSERT INTO sessions(id,candidate,role,policy,consent,created_at) VALUES (?,?,?,?,?,?)",
                   (key, item.candidate, item.role, policy, item.consent, timestamp()))
        db.execute("INSERT INTO session_context(session_id,role_id,questions,permitted_sources) VALUES (?,?,?,?)",
                   (key, role_id, questions, permitted))
    return get_session(db, key)


def check_revision(current, expected):
    if expected is not None and current["revision"] != expected:
        raise HTTPException(409, "This exchange changed after you opened it. Reload the saved version to compare your draft.",
                            headers={"X-InterviewCheck-Conflict": "answer-revision"})


def write_answer(db, key, item: AnswerInput, replace_id=None, *, session=None):
    session = session if session is not None else capture_context(db, key)
    if not session["consent"]:
        raise HTTPException(409, "This archived session has no recorded notice. Create a new session for capture.")
    aid = str(replace_id or item.id or uuid4())
    if replace_id and item.id and aid != str(item.id):
        raise HTTPException(409, "The body and route answer IDs differ.")
    current = db.execute("SELECT * FROM answers WHERE id=?", (aid,)).fetchone()
    if replace_id and (current is None or current["session_id"] != key):
        raise HTTPException(404, "Answer does not exist in this session.")
    if replace_id and isinstance(item, AnswerEdit):
        check_revision(current, item.expected_revision)
    own_record = current if current and current["session_id"] == key else None
    parent, slot = lineage.resolve(db, key, aid, item, own_record)
    refs = json.dumps([ref.model_dump() for ref in item.references], ensure_ascii=False)
    if current is not None and current["session_id"] == key:
        same_input = (current["question"], current["answer"], json.loads(current["refs"]), current["parent_answer_id"],
                      current["planned_slot"]) == (item.question, item.answer, json.loads(refs), parent, slot)
        fresh = not (current["legacy"] and json.loads(current["result"]).get("archived"))
        if same_input and fresh:
            return answer_row(current)
    if session["ended_at"]:
        raise HTTPException(409, "Reopen the interview before changing an exchange.")
    if not current and db.execute("SELECT 1 FROM session_drafts WHERE id=?", (aid,)).fetchone():
        raise HTTPException(409, "Publish the saved draft to add this exchange.")
    if current and not replace_id:
        raise HTTPException(409, "The answer ID already belongs to different content.")
    materials = session.get("permitted_sources")
    if materials is None:
        materials = role_kits.session_materials(db, key)
    result = role_kits.compare_answer(item, materials)
    fields = (item.question, item.answer, refs, json.dumps(result), result["status"], parent, slot)
    if replace_id:
        note = current["note"]
        if note and not note.startswith(EARLIER_ANSWER_NOTE):
            note = EARLIER_ANSWER_NOTE + note
        db.execute("UPDATE answers SET question=?,answer=?,refs=?,result=?,status=?,parent_answer_id=?,planned_slot=?,disposition='pending',note=?,revision=revision+1 WHERE id=?",
                   (*fields, note, aid))
    else:
        db.execute("INSERT INTO answers(question,answer,refs,result,status,parent_answer_id,planned_slot,id,session_id) VALUES (?,?,?,?,?,?,?,?,?)",
                   (*fields, aid, key))
    return get_answer(db, key, aid)


def update_review(db, key, aid, review: ReviewInput):
    current = get_answer(db, key, aid)
    check_revision(current, review.expected_revision)
    if (current["disposition"], current["note"]) == (review.disposition, review.note):
        return current
    db.execute("UPDATE answers SET disposition=?,note=?,revision=revision+1 WHERE session_id=? AND id=?",
               (review.disposition, review.note, key, aid))
    return get_answer(db, key, aid)
