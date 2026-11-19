"""Protected native-compatible administration for the Python membership service."""
from datetime import datetime
import json
from typing import Literal

from fastapi import APIRouter, Depends, Header, HTTPException, Query
from pydantic import BaseModel
from uuid import UUID

from . import account_auth, account_db as store, rate_limit

router = APIRouter(prefix="/admin")


def admin(authorization: str | None = Header(default=None)):
    user, _ = account_auth.authenticate(authorization)
    if user["role"] != "admin":
        raise HTTPException(403, "Admin access required.")
    return user


class Update(BaseModel):
    role: Literal["user", "admin"] | None = None
    disabled: bool | None = None
    complimentaryUntil: datetime | None = None


def view(db, user):
    data = store.snapshot(db, user)
    return {key: data[key] for key in ("user", "entitlement", "subscription")} | {"lastLoginAt": store.iso(user["last_login_at"])}


@router.get("/stats", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
def stats(_=Depends(admin)):
    with store.connection() as db:
        return {"totalUsers": db.execute("SELECT count(*) FROM users").fetchone()[0],
                "admins": db.execute("SELECT count(*) FROM users WHERE role='admin' AND disabled=0").fetchone()[0],
                "liveSubscriptions": db.execute("SELECT count(distinct user_id) FROM subscriptions WHERE status IN ('active','trialing','past_due')").fetchone()[0]}


@router.get("/users", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
def users(q: str = Query(default="", max_length=200), limit: int = Query(default=50, ge=1, le=100),
          cursor: str | None = Query(default=None, max_length=128), _=Depends(admin)):
    last, uid = 2**63 - 1, ""
    if cursor:
        try:
            stamp, raw = cursor.split("|")
            last, uid = int(stamp), str(UUID(raw))
            if not 0 <= last < 2**63:
                raise ValueError
        except ValueError as exc:
            raise HTTPException(422, "Invalid account list cursor.") from exc
    with store.connection() as db:
        records = db.execute("""SELECT * FROM users WHERE instr(lower(email),?)>0 AND
            (created_at<? OR (created_at=? AND id>?)) ORDER BY created_at DESC,id ASC LIMIT ?""",
                             (q.lower(), last, last, uid, limit + 1)).fetchall()
        next_cursor = f"{records[limit-1]['created_at']}|{records[limit-1]['id']}" if len(records) > limit else None
        return {"users": [view(db, row) for row in records[:limit]], "nextCursor": next_cursor}


def account(db, uid):
    row = db.execute("SELECT * FROM users WHERE id=?", (str(uid),)).fetchone()
    if not row:
        raise HTTPException(404, "Account not found.")
    return row


@router.get("/users/{uid}", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
def detail(uid: UUID, _=Depends(admin)):
    with store.connection() as db:
        return view(db, account(db, uid))


@router.patch("/users/{uid}", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
def update(uid: UUID, item: Update, actor=Depends(admin)):
    if not item.model_fields_set:
        raise HTTPException(422, "Specify an account change.")
    with store.connection(write=True) as db:
        # Check the actor again inside the transaction in case another admin changed their role.
        current = account(db, actor["id"])
        if current["disabled"] or current["role"] != "admin":
            raise HTTPException(403, "Admin access required.")
        old = account(db, uid)
        role = item.role or old["role"]
        disabled = old["disabled"] if item.disabled is None else item.disabled
        until = old["complimentary_until"]
        if "complimentaryUntil" in item.model_fields_set:
            if item.complimentaryUntil and item.complimentaryUntil.tzinfo is None:
                raise HTTPException(422, "Use a timestamp with a timezone.")
            until = int(item.complimentaryUntil.timestamp() * 1000) if item.complimentaryUntil else None
        if disabled and actor["id"] == str(uid):
            raise HTTPException(409, "Admins cannot disable their own account.")
        if old["role"] == "admin" and not old["disabled"] and (role != "admin" or disabled):
            count = db.execute("SELECT count(*) FROM users WHERE role='admin' AND disabled=0").fetchone()[0]
            if count <= 1:
                raise HTTPException(409, "Keep at least one active administrator.")
        ts = store.now()
        role_changed = role != old["role"]
        db.execute("UPDATE users SET role=?,disabled=?,complimentary_until=?,updated_at=? WHERE id=?",
                   (role, disabled, until, ts, str(uid)))
        if bool(disabled) or role_changed:
            db.execute("UPDATE sessions SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL", (ts, str(uid)))
        details = item.model_dump(mode="json", exclude_unset=True)
        store.audit(db, "admin.update_user", str(uid), actor["id"], details)
        return view(db, account(db, uid))


@router.get("/audit", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
def audit(limit: int = Query(default=100, ge=1, le=200), _=Depends(admin)):
    with store.connection() as db:
        rows = db.execute("SELECT * FROM audit_log ORDER BY id DESC LIMIT ?", (limit,))
        return {"entries": [{"id": r["id"], "at": store.iso(r["at"]), "actorUserId": r["actor_user_id"], "action": r["action"],
                             "targetUserId": r["target_user_id"], "details": json.loads(r["details"]) if r["details"] else None} for r in rows]}


@router.api_route("/{unknown:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"],
                  dependencies=[Depends(admin), Depends(rate_limit.limit(rate_limit.ADMIN_READ))], include_in_schema=False)
def missing_admin(unknown: str):
    raise HTTPException(404, "Unknown admin route.")
