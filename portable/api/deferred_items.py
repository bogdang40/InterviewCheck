"""Selected follow up questions, distinct from role plans and unpublished answer drafts."""
from hashlib import sha256
import hmac
import json
import secrets

from fastapi import HTTPException

from . import answer_identity, deferred_fulfillment, sql_script


SCHEMA = """
CREATE TABLE IF NOT EXISTS deferred_questions (
 id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
 parent_answer_id TEXT NOT NULL REFERENCES answers(id) ON DELETE CASCADE, question TEXT NOT NULL,
 status TEXT NOT NULL CHECK(status IN ('pending','dismissed','fulfilled')),
 needs_reconfirmation INTEGER NOT NULL CHECK(needs_reconfirmation IN (0,1)),
 material_sha256 TEXT NOT NULL, revision_id TEXT NOT NULL, created_at TEXT NOT NULL,
 child_answer_id TEXT UNIQUE REFERENCES answers(id), previous_revision_id TEXT, fulfillment_digest TEXT,
 CHECK ((status='fulfilled') = (child_answer_id IS NOT NULL)),
 CHECK (status<>'fulfilled' OR needs_reconfirmation=0)
);
CREATE INDEX IF NOT EXISTS idx_deferred_session ON deferred_questions(session_id,status,created_at,id);
CREATE INDEX IF NOT EXISTS idx_deferred_parent ON deferred_questions(parent_answer_id,status);
"""


def migrate(db):
    had_facts = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='deferred_publications'").fetchone()
    sql_script.execute(db, SCHEMA)
    sql_script.execute(db, deferred_fulfillment.SCHEMA)
    if "creation_receipt" not in {r[1] for r in db.execute("PRAGMA table_info(deferred_questions)")}:
        db.execute("ALTER TABLE deferred_questions ADD COLUMN creation_receipt TEXT")
    if "publication_draft_token" not in {r[1] for r in db.execute("PRAGMA table_info(deferred_questions)")}:
        db.execute("ALTER TABLE deferred_questions ADD COLUMN publication_draft_token TEXT")
    if not had_facts:
        deferred_fulfillment.migrate_receipts(db)
    columns = {r[1] for r in db.execute("PRAGMA table_info(session_drafts)")}
    if "deferred_question_id" not in columns:
        db.execute("ALTER TABLE session_drafts ADD COLUMN deferred_question_id TEXT REFERENCES deferred_questions(id)")
    if "deferred_revision_id" not in columns:
        db.execute("ALTER TABLE session_drafts ADD COLUMN deferred_revision_id TEXT")
    if "deferred_draft_token" not in columns:
        db.execute("ALTER TABLE session_drafts ADD COLUMN deferred_draft_token TEXT")
        db.execute("""UPDATE session_drafts SET deferred_draft_token=lower(hex(randomblob(32)))
                      WHERE deferred_question_id IS NOT NULL""")

    # Browser recovery identifies the parked draft lifetime without retaining a write token.
    if "recovery_fingerprint" not in columns:
        db.execute("ALTER TABLE session_drafts ADD COLUMN recovery_fingerprint TEXT")
        db.execute("UPDATE session_drafts SET recovery_fingerprint=lower(hex(randomblob(16)))")
    db.execute("""CREATE TRIGGER IF NOT EXISTS session_draft_recovery_insert AFTER INSERT ON session_drafts BEGIN
                  UPDATE session_drafts SET recovery_fingerprint=lower(hex(randomblob(16))) WHERE session_id=NEW.session_id;
                  END""")


def digest(fields):
    return sha256(json.dumps(fields, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def material(context, answer):
    return digest([context, [answer.get(k) for k in ("id", "question", "answer", "references", "result",
                                                      "parent_answer_id", "planned_slot", "import_origin", "legacy")]])


class UnreadableQuestion(HTTPException):
    pass


def conflict(detail):
    return HTTPException(409, detail, headers={"X-InterviewCheck-Conflict": "deferred-question"})


def access_session(db, sid, *, open_only=False):
    from . import session_privacy, store
    session = store.get_summary(db, sid)
    if not session["consent"] or session_privacy.read(db, sid).state != "unmarked":
        raise HTTPException(403, "This interview does not permit deferred questions.")
    if open_only and session["ended_at"]:
        raise conflict("Reopen the interview before changing a deferred question.")
    return session


def find(db, sid, qid):
    row = db.execute("SELECT * FROM deferred_questions WHERE session_id=? AND id=?", (sid, qid)).fetchone()
    if row is None:
        raise HTTPException(404, "Deferred question does not exist in this interview.")
    return row


def token(db, row, revision=None):
    key = answer_identity.binding_key(db, row["parent_answer_id"])
    payload = f"deferred-v1:{row['session_id']}:{row['id']}:{revision or row['revision_id']}".encode()
    return hmac.new(key, payload, sha256).hexdigest()


def public(db, row):
    item = {k: row[k] for k in ("id", "session_id", "parent_answer_id", "question", "status", "child_answer_id", "created_at")}
    return {**item, "needs_reconfirmation": bool(row["needs_reconfirmation"]), "version": token(db, row)}


def checked_material(db, sid, aid, expected):
    from . import review_worksheet
    live = review_worksheet.state(db, sid, aid)
    if not hmac.compare_digest(expected, live["material"]):
        raise conflict("The displayed parent exchange changed. Review the saved material again.")
    return material(live["session"], live["answer"])


def mark_changed(db, aid):
    # A real material revision invalidates even a draft whose original wording later returns.
    db.execute("""UPDATE deferred_questions SET needs_reconfirmation=1,revision_id=lower(hex(randomblob(16)))
                  WHERE parent_answer_id=? AND status IN ('pending','dismissed')""", (aid,))


def preserve_child_parent(db, sid, aid, parent, slot):
    row = db.execute("SELECT parent_answer_id FROM deferred_questions WHERE session_id=? AND child_answer_id=?", (sid, aid)).fetchone()
    if row and (parent != row[0] or slot is not None):
        raise conflict("This exchange answers a deferred question. Keep its recorded parent.")


def submission_digest(aid, item, parent, slot):
    return deferred_fulfillment.submission_hash(aid, parent, slot, item.question, item.answer, [r.model_dump() for r in item.references])


def checked_binding(db, sid, binding, question, parent, slot):
    row = find(db, sid, str(binding.id))
    if not hmac.compare_digest(binding.version, token(db, row)):
        raise conflict("The deferred question changed. Reload it before continuing.")
    if row["status"] != "pending" or row["needs_reconfirmation"]:
        raise conflict("Only a current pending question can be captured. Review its parent again.")
    if parent != row["parent_answer_id"] or slot is not None or question != row["question"]:
        raise conflict("Keep the selected question text and its parent when recording this follow up.")
    from . import review_worksheet
    live = review_worksheet.state(db, sid, parent)
    if material(live["session"], live["answer"]) != row["material_sha256"]:
        raise conflict("The parent material changed. Reconfirm the deferred question.")
    return row


def begin_publish(db, sid, aid, item, parent, slot):
    binding = getattr(item, "deferred_question", None)
    if binding is None:
        return None, False
    if item.id is None:
        raise conflict("A deferred response requires a stable exchange ID.")
    row = find(db, sid, str(binding.id))
    if row["status"] == "fulfilled":
        if (row["child_answer_id"] == aid and row["previous_revision_id"] and
                hmac.compare_digest(binding.version, token(db, row, row["previous_revision_id"])) and
                row["publication_draft_token"] == getattr(item, "deferred_draft_token", None) and
                row["fulfillment_digest"] == submission_digest(aid, item, parent, slot)):
            return row, True
        raise conflict("This question already has a recorded child exchange. Open its saved response.")
    row = checked_binding(db, sid, binding, item.question, parent, slot)
    if db.execute("SELECT 1 FROM session_drafts WHERE session_id=?", (sid,)).fetchone():
        raise conflict("Publish or discard the existing draft before recording a separate follow up.")
    if db.execute("SELECT 1 FROM answers WHERE id=?", (aid,)).fetchone():
        raise conflict("The response ID already belongs to an existing exchange.")
    return row, False


def finish_publish(db, row, aid, item, parent, slot):
    if row is not None:
        proof = submission_digest(aid, item, parent, slot)
        updated = db.execute("""UPDATE deferred_questions SET child_answer_id=?,status='fulfilled',
                                previous_revision_id=revision_id,revision_id=?,fulfillment_digest=?,publication_draft_token=?
                                WHERE id=? AND status='pending' AND revision_id=?""",
                             (aid, secrets.token_hex(16), proof, getattr(item, "deferred_draft_token", None), row["id"], row["revision_id"]))
        if updated.rowcount != 1:
            raise conflict("The deferred question changed before its response was saved.")
        deferred_fulfillment.record(db, row["session_id"], aid, row["id"], parent, deferred_fulfillment.question_hash(row["question"]))
        return receipt(row, aid, proof)


def receipt(row, aid, proof):
    return {"question_id": row["id"], "parent_answer_id": row["parent_answer_id"],
            "child_answer_id": aid, "submission_sha256": proof}


def draft_guard(db, sid, qid, revision):
    if qid is None:
        return None
    return {"id": qid, "version": token(db, find(db, sid, qid), revision)}
