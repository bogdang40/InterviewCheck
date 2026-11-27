"""Bind an editor to the administrator, login session and lifetime of the displayed exchange."""
from dataclasses import dataclass, field
import hashlib
import hmac
import json

from fastapi import HTTPException

from . import access, account_db, answer_identity


@dataclass(frozen=True)
class Editor:
    user_id: str
    email: str
    session_token: str = field(repr=False)


def context(db, sid, aid, actor: Editor):
    key = answer_identity.binding_key(db, aid)
    data = json.dumps(["panel-editor-v1", sid, aid, actor.user_id, actor.email, actor.session_token],
                      ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return hmac.new(key, data, hashlib.sha256).hexdigest()


def verify(db, sid, aid, proof, actor: Editor):
    if not hmac.compare_digest(proof, context(db, sid, aid, actor)):
        raise HTTPException(409, "The panel editor no longer belongs to this account or exchange. Read it again.",
                            headers={"X-InterviewCheck-Conflict": "panel-authority"})
    # Remote authorization is performed by the request dependencies before taking
    # the review write lock. Embedded sessions can also be checked after that wait.
    if access.account_enabled() and not access.embedded_enabled():
        return
    if not account_db.database().is_file():
        raise HTTPException(401, "Sign in again before saving this panel decision.")
    with account_db.connection() as adb:
        row = adb.execute("""SELECT u.* FROM users u JOIN sessions s ON s.user_id=u.id
                             WHERE s.token_hash=? AND s.revoked_at IS NULL AND s.expires_at>?
                             AND u.disabled=0 AND u.id=?""", (account_db.digest(actor.session_token),
                                                               account_db.now(), actor.user_id)).fetchone()
        if row is None:
            raise HTTPException(401, "Sign in again before saving this panel decision.")
        if row["role"] != "admin" or row["email"] != actor.email:
            raise HTTPException(403, "The panel editor requires the same administrator account.")
        if access.account_enabled():
            access.verify_operator_email(row["email"])
            if account_db.snapshot(adb, dict(row))["entitlement"]["active"] is not True:
                raise HTTPException(402, "An active InterviewCheck plan is required.")
