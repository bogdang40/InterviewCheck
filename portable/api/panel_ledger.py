"""Panel process decisions for an exchange. Individual reviews and scorecards have separate writers."""
from collections import Counter
from hashlib import sha256
import json
import secrets

from fastapi import HTTPException

from . import sql_script


SCHEMA = """
CREATE TABLE IF NOT EXISTS panel_decisions (
 session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
 answer_id TEXT NOT NULL REFERENCES answers(id) ON DELETE CASCADE,
 sequence INTEGER NOT NULL CHECK(sequence>0),
 action TEXT NOT NULL CHECK(action IN ('discussion_complete','follow_up_required','reopened')),
 basis TEXT NOT NULL, write_token TEXT NOT NULL, rationale TEXT NOT NULL, actor_id TEXT NOT NULL, actor_email TEXT NOT NULL, created_at TEXT NOT NULL,
 PRIMARY KEY(answer_id,sequence)
);
CREATE INDEX IF NOT EXISTS idx_panel_decisions_session ON panel_decisions(session_id,answer_id,sequence);
"""
PUBLIC_FIELDS = "sequence,action,created_at"
PRIVATE_FIELDS = PUBLIC_FIELDS + ",rationale,actor_id,actor_email"
EVIDENCE = """a.id AS answer_id, a.session_id,a.panel_evidence_generation,a.revision,a.question,a.answer,a.refs,a.result,a.disposition,a.note,
              a.parent_answer_id,a.planned_slot,s.candidate,s.role,s.policy,s.consent,c.permitted_sources"""


def migrate(db):
    sql_script.execute(db, SCHEMA)
    if "panel_evidence_generation" not in {r[1] for r in db.execute("PRAGMA table_info(answers)")}:
        db.execute("ALTER TABLE answers ADD COLUMN panel_evidence_generation INTEGER NOT NULL DEFAULT 0")


def digest(values):
    return sha256(json.dumps(values, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()).hexdigest()


def material(row):
    refs = [[r["label"], r["text"], bool(r.get("permitted"))] for r in json.loads(row["refs"])]
    finding = json.loads(row["result"])
    passages = [[p["label"], p["answer_excerpt"], p["source_excerpt"], p["words"], p.get("source_index"),
                 p.get("answer_span"), p.get("source_span")] for p in finding["passages"]]
    return [row["answer_id"], row["question"], row["answer"], refs, finding["status"], finding["explanation"],
            finding["follow_up"], passages, row["parent_answer_id"], row["planned_slot"]]


def vote_basis(latest, counts):
    return [[uid, latest[uid]["reviewer_email"], latest[uid]["disposition"], latest[uid]["created_at"], counts[uid]]
            for uid in sorted(latest)]


def latest_votes(rows):
    latest, counts = {}, Counter()
    for row in rows:
        uid = row["reviewer_id"]
        latest[uid] = row
        counts[uid] += 1
    return vote_basis(latest, counts)


def decision_basis(row, evidence, votes):
    return digest([row["session_id"], row["panel_evidence_generation"], evidence, row["candidate"], row["role"], row["policy"], bool(row["consent"]),
                   json.loads(row["permitted_sources"] or "[]"), votes])


def status(basis, split, last):
    if last is None:
        return "open" if split else "none"
    if basis != last["basis"]:
        return "changed"
    return last["action"]


def _latest_decisions(db, answer_ids, *, with_evidence):
    ids = list(answer_ids)
    if not ids or db.execute("SELECT 1 FROM panel_decisions LIMIT 1").fetchone() is None:
        return
    columns = f"{EVIDENCE},p.basis,p.action,p.created_at" if with_evidence else "a.id AS answer_id,p.created_at"
    context = "LEFT JOIN session_context c ON c.session_id=s.id" if with_evidence else ""
    for start in range(0, len(ids), 300):
        yield from db.execute(f"""SELECT {columns}
                    FROM json_each(?) k JOIN answers a ON a.id=k.value
                    JOIN active_sessions s ON s.id=a.session_id {context}
                    JOIN panel_decisions p ON p.answer_id=a.id AND p.session_id=s.id
                    WHERE p.sequence=(SELECT MAX(d.sequence) FROM panel_decisions d WHERE d.answer_id=a.id)""",
                              (json.dumps(ids[start:start + 300]),))


def decision_times(db, answer_ids):
    """The all view includes a previously discussed case even when its evidence has changed."""
    return {r["answer_id"]: r["created_at"] for r in _latest_decisions(db, answer_ids, with_evidence=False)}


def queue_states(db, latest, counts, *, answer_ids=None):
    states = {}
    ids = latest if answer_ids is None else answer_ids
    for row in _latest_decisions(db, ids, with_evidence=True):
        aid = row["answer_id"]
        votes = vote_basis(latest[aid], counts[aid])
        split = len({v[2] for v in votes if v[2] != "pending"}) > 1
        basis = decision_basis(row, material(row), votes)
        states[aid] = (status(basis, split, row), row["created_at"])
    return states


def read_case(db, sid, aid):
    from . import session_privacy

    row = db.execute(f"""SELECT {EVIDENCE} FROM answers a JOIN active_sessions s ON s.id=a.session_id
                         LEFT JOIN session_context c ON c.session_id=s.id WHERE s.id=? AND a.id=?
                         {session_privacy.calibration_filter(db)}""", (sid, aid)).fetchone()
    if row is None:
        raise HTTPException(404, "Panel review is unavailable for this exchange.")
    reviews = db.execute("""SELECT reviewer_id,reviewer_email,disposition,created_at FROM answer_review_events
                            WHERE session_id=? AND answer_id=? ORDER BY id""", (sid, aid))
    votes = latest_votes(reviews)
    split = len({v[2] for v in votes if v[2] != "pending"}) > 1
    content = material(row)
    evidence = digest([content, row["revision"], row["disposition"], row["note"]])
    basis = decision_basis(row, content, votes)
    last = db.execute("""SELECT sequence,action,basis,write_token FROM panel_decisions WHERE session_id=? AND answer_id=?
                          ORDER BY sequence DESC LIMIT 1""", (sid, aid)).fetchone()
    revision = last["write_token"] if last else digest(["new-panel-discussion", sid, aid])
    return {"session_id": sid, "answer_id": aid, "status": status(basis, split, last), "split": split, "basis": basis, "version": revision,
            "evidence": evidence, "history_count": last["sequence"] if last else 0,
            "reviewers": [{"reviewer_email": email, "disposition": disposition, "created_at": at}
                          for _, email, disposition, at, _ in votes if disposition != "pending"]}


def history(db, sid, aid, *, before=None, private=False):
    columns = PRIVATE_FIELDS if private else PUBLIC_FIELDS
    predicate = "AND sequence<?" if before is not None else ""
    params = (sid, aid, before) if before is not None else (sid, aid)
    return [dict(r) for r in db.execute(f"""SELECT {columns} FROM panel_decisions WHERE session_id=? AND answer_id=?
                                            {predicate} ORDER BY sequence DESC LIMIT 10""", params)]


def transition(db, sid, aid, *, payload, actor, timestamp):
    case = read_case(db, sid, aid)
    if (payload.expected_basis != case["basis"] or payload.expected_version != case["version"] or
            payload.expected_evidence != case["evidence"]):
        raise HTTPException(409, "The saved exchange, reviewer opinions or panel decision changed. Read the latest record.",
                            headers={"X-InterviewCheck-Conflict": "panel-review"})
    current = case["status"]
    if current == "none":
        raise HTTPException(409, "Panel review requires a recorded reviewer disagreement.")
    if payload.action == current:
        raise HTTPException(409, "The discussion already has that state.")
    if current == "discussion_complete" and payload.action != "reopened":
        raise HTTPException(409, "Reopen the completed discussion before recording another decision.")
    if payload.action == "reopened" and current not in ("discussion_complete", "follow_up_required"):
        raise HTTPException(409, "This discussion is already open.")
    db.execute("""INSERT INTO panel_decisions(session_id,answer_id,sequence,action,basis,write_token,
                                             rationale,actor_id,actor_email,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)""",
               (sid, aid, case["history_count"] + 1, payload.action, case["basis"], secrets.token_hex(32),
                payload.rationale, actor[0], actor[1], timestamp))
    return read_case(db, sid, aid)
