"""Read eligibility and compare a worksheet to the saved exchange in the caller's transaction."""
import hashlib
import hmac
import json

from fastapi import HTTPException

from . import answer_identity, session_privacy, store


def _fingerprint(key: bytes, tag: str, fields) -> str:
    payload = json.dumps([tag, fields], sort_keys=True, ensure_ascii=True, separators=(",", ":")).encode("ascii")
    return hmac.new(key, payload, hashlib.sha256).hexdigest()


def state(db, sid: str, aid: str, *, answer=None) -> dict:
    row = db.execute("""SELECT s.candidate,s.role,s.created_at,s.policy,s.consent,c.role_id,
                               c.questions,c.permitted_sources,
                               (SELECT count(*) FROM answers x WHERE x.session_id=s.id AND x.rowid<=a.rowid) AS ordinal
                        FROM active_sessions s JOIN answers a ON a.session_id=s.id
                        LEFT JOIN session_context c ON c.session_id=s.id
                        WHERE s.id=? AND a.id=?""", (sid, aid)).fetchone()
    if row is None:
        raise HTTPException(404, "This exchange is unavailable for worksheets.")
    if not row["consent"] or session_privacy.read(db, sid).state != "unmarked":
        raise HTTPException(403, "This interview does not permit worksheet use.",
                            headers={"X-InterviewCheck-Worksheet": "unavailable"})
    saved = answer if answer is not None else store.get_answer(db, sid, aid)
    context = {name: row[name] for name in ("candidate", "role", "created_at", "policy", "role_id")}
    context.update(consent=bool(row["consent"]), planned_questions=json.loads(row["questions"] or "[]"),
                   permitted_sources=json.loads(row["permitted_sources"] or "[]"))
    evidence = {k: v for k, v in saved.items() if k not in {"revision", "disposition", "note"}}
    key = answer_identity.binding_key(db, aid)
    material = _fingerprint(key, "material-v1", [sid, aid, row["ordinal"], context, evidence])
    review = _fingerprint(key, "review-v1", [material, saved["revision"], saved["disposition"], saved["note"]])
    return {"session_id": sid, "ordinal": row["ordinal"], "session": context, "answer": saved,
            "material": material, "review": review}


def check_save(db, sid: str, aid: str, current: dict, request) -> None:
    latest = state(db, sid, aid, answer=current)
    guard = request.worksheet_guard
    if (not hmac.compare_digest(guard.material, latest["material"])
            or not hmac.compare_digest(guard.review, latest["review"])
            or request.expected_revision != current["revision"] or request.disposition != current["disposition"]):
        raise HTTPException(409, "The worksheet or saved review changed. Preview the worksheet again before saving.",
                            headers={"X-InterviewCheck-Conflict": "worksheet"})
