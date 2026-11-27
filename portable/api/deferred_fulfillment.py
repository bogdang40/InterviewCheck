"""Original publication facts for a selected follow up, independent of subsequent child edits."""
from hashlib import sha256
import json


SCHEMA = """
CREATE TABLE IF NOT EXISTS deferred_publications (
 answer_id TEXT PRIMARY KEY REFERENCES answers(id) ON DELETE CASCADE,
 session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
 question_id TEXT NOT NULL UNIQUE REFERENCES deferred_questions(id) ON DELETE CASCADE,
 parent_answer_id TEXT NOT NULL REFERENCES answers(id) ON DELETE CASCADE,
 question_sha256 TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_deferred_publications_session ON deferred_publications(session_id);
"""


def question_hash(question):
    return sha256(question.encode("utf-8")).hexdigest()


def submission_hash(aid, parent, slot, question, answer, refs):
    # Arrays of primitive values match UTF-8 JSON.stringify in the editor.
    values = [aid, parent, slot, question, answer, [[r["label"], r["text"], r["permitted"]] for r in refs]]
    return sha256(json.dumps(values, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()


def record(db, sid, aid, qid, parent, original_hash):
    db.execute("""INSERT INTO deferred_publications(answer_id,session_id,question_id,parent_answer_id,question_sha256)
                  VALUES(?,?,?,?,?)""", (aid, sid, qid, parent, original_hash))


def _old_matches(record, aid, parent, selected, original):
    if (record.get("parent_answer_id"), record.get("planned_slot"), record["question"]) != (parent, None, selected):
        return False
    fields = [aid, parent, None, record["question"], record["answer"], record["references"]]
    return sha256(json.dumps(fields, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode()).hexdigest() == original


def migrate_receipts(db):
    # The unpublished earlier schema kept a private digest of the *original* submission.
    # Recover only from that evidence, never by guessing from the child's current wording.
    has_history = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='answer_history'").fetchone()
    rows = db.execute("""SELECT q.session_id,q.id,q.parent_answer_id,q.child_answer_id,q.question,q.fulfillment_digest,
                                a.question,a.answer,a.refs,a.parent_answer_id,a.planned_slot
                         FROM deferred_questions q JOIN answers a ON a.id=q.child_answer_id AND a.session_id=q.session_id
                         WHERE q.status='fulfilled' AND q.fulfillment_digest IS NOT NULL""")
    for sid, qid, parent, aid, selected, original, question, answer, refs, actual_parent, slot in rows:
        candidate = {"question": question, "answer": answer, "references": json.loads(refs),
                     "parent_answer_id": actual_parent, "planned_slot": slot}
        if not _old_matches(candidate, aid, parent, selected, original):
            if not has_history:
                continue
            candidate = None
            snapshots = db.execute("SELECT snapshot FROM answer_history WHERE answer_id=? ORDER BY revision", (aid,))
            for (raw,) in snapshots:
                historical = json.loads(raw)
                if _old_matches(historical, aid, parent, selected, original):
                    candidate = historical
                    break
        if candidate:
            record(db, sid, aid, qid, parent, question_hash(selected))
            proof = submission_hash(aid, parent, None, selected, candidate["answer"], candidate["references"])
            db.execute("UPDATE deferred_questions SET fulfillment_digest=? WHERE id=?", (proof, qid))


def exported_origins(db, sid):
    return {aid: {"question_id": qid, "child_answer_id": aid, "parent_answer_id": parent, "question_sha256": fingerprint}
            for aid, qid, parent, fingerprint in db.execute(
                "SELECT answer_id,question_id,parent_answer_id,question_sha256 FROM deferred_publications WHERE session_id=?", (sid,)
            )}
