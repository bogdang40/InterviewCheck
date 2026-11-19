"""Account session, scoped API token, and rate-limit unlock endpoints."""
import json
import re
import secrets
import time
from typing import Literal
from uuid import UUID, uuid4

from fastapi import APIRouter, Body, Depends, Header, HTTPException, Query
from pydantic import BaseModel, Field, field_validator

from . import account_admin, account_auth, account_db as store, rate_limit

router = APIRouter()

API_TOKEN_SCOPES = ("read:interviews", "write:interviews", "export:reports", "read:telemetry", "admin:models")
ScopeName = Literal["read:interviews", "write:interviews", "export:reports", "read:telemetry", "admin:models"]
_VALID_LIMITERS = {"credential", "adminRead", "adminWrite", "adminProbe", "aiRequest", "integrationRemote", "billing", "totp"}


class ApiTokenCreate(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    scopes: list[ScopeName] = Field(min_length=1, max_length=len(API_TOKEN_SCOPES))
    ttlDays: int | None = Field(default=None, ge=1, le=365)

    @field_validator("name")
    @classmethod
    def clean_name(cls, value: str) -> str:
        cleaned = value.strip()
        if not cleaned:
            raise ValueError("Token name is required.")
        return cleaned

    @field_validator("scopes")
    @classmethod
    def dedupe_scopes(cls, values: list[ScopeName]) -> list[ScopeName]:
        return list(dict.fromkeys(values))


class RevokeSessionsInput(BaseModel):
    sessionId: UUID | None = None


class RateLimitUnlockInput(BaseModel):
    limiter: str | None = Field(default=None, max_length=40)
    keyHash: str | None = Field(default=None, max_length=64)
    key: str | None = Field(default=None, max_length=254)


def _auth(authorization: str | None = Header(default=None)):
    return account_auth.authenticate(authorization)


def _limiter_names() -> dict[int, str]:
    return {
        id(rate_limit.ADMIN_READ): "adminRead", id(rate_limit.ADMIN_WRITE): "adminWrite",
        id(rate_limit.ADMIN_PROBE): "adminProbe", id(rate_limit.AI_REQUEST): "aiRequest",
        id(rate_limit.INTEGRATION_REMOTE): "integrationRemote", id(rate_limit.BILLING_ACTION): "billing",
        id(rate_limit.TOTP_ACTION): "totp",
    }


def _mask_key(value: str) -> str:
    if "@" in value:
        idx = value.index("@")
        return ("***" if idx == 0 else value[0] + "***") + value[idx:]
    if value.endswith("/64"):
        return ":".join(value[:-3].split(":")[:2]) + ":*:*:*::/64"
    parts = value.split(".")
    return f"{parts[0]}.{parts[1]}.*.*" if len(parts) == 4 else ("***" if len(value) <= 2 else f"{value[:2]}***")


def _session_view(row) -> dict:
    return {"id": row["id"], "deviceName": row["device_name"], "createdAt": store.iso(row["created_at"]),
            "expiresAt": store.iso(row["expires_at"]), "lastSeenAt": store.iso(row["last_seen_at"])}


def _token_view(row) -> dict:
    try:
        scopes = [s for s in json.loads(row["scopes_json"]) if s in API_TOKEN_SCOPES]
    except ValueError:
        scopes = []
    return {"id": row["id"], "name": row["name"], "tokenPrefix": row["token_prefix"], "scopes": scopes,
            "createdAt": store.iso(row["created_at"]), "expiresAt": store.iso(row["expires_at"]), "lastUsedAt": store.iso(row["last_used_at"])}


@router.get("/auth/sessions")
def list_sessions(auth=Depends(_auth)):
    user, current_sid = auth
    with store.connection() as db:
        rows = db.execute(
            "SELECT id, device_name, created_at, expires_at, last_seen_at FROM sessions WHERE user_id=? AND revoked_at IS NULL AND expires_at>? ORDER BY last_seen_at DESC, created_at DESC",
            (user["id"], store.now()),
        ).fetchall()
    return {"sessions": [{**_session_view(r), "isCurrent": r["id"] == current_sid} for r in rows]}


@router.delete("/auth/sessions/{sid}")
def revoke_own_session(sid: UUID, auth=Depends(_auth)):
    user, current_sid = auth
    with store.connection(write=True) as db:
        if not db.execute("UPDATE sessions SET revoked_at=? WHERE id=? AND user_id=? AND revoked_at IS NULL", (store.now(), str(sid), user["id"])).rowcount:
            raise HTTPException(404, "Session not found.")
        store.audit(db, "auth.session_revoke", user["id"], user["id"], {"sessionId": str(sid), "isCurrent": str(sid) == current_sid})
    return {"revoked": True, "id": str(sid)}


@router.get("/auth/tokens")
def list_api_tokens(auth=Depends(_auth)):
    user, _ = auth
    with store.connection() as db:
        rows = db.execute("SELECT id, name, token_prefix, scopes_json, created_at, expires_at, last_used_at FROM api_tokens WHERE user_id=? AND revoked_at IS NULL ORDER BY created_at DESC", (user["id"],)).fetchall()
    return {"tokens": [_token_view(r) for r in rows]}


@router.post("/auth/tokens", status_code=201)
def create_api_token(item: ApiTokenCreate, auth=Depends(_auth)):
    user, _ = auth
    if "admin:models" in item.scopes and user.get("role") != "admin":
        raise HTTPException(403, "Admin role is required for the admin:models scope.")
    raw, tid, ts = "ic_tok_" + secrets.token_urlsafe(32), str(uuid4()), store.now()
    expires_at = ts + item.ttlDays * store.DAY if item.ttlDays is not None else None
    with store.connection(write=True) as db:
        current = db.execute("SELECT role, disabled FROM users WHERE id=?", (user["id"],)).fetchone()
        if not current or current["disabled"]:
            raise HTTPException(403, "This account has been disabled.")
        if "admin:models" in item.scopes and current["role"] != "admin":
            raise HTTPException(403, "Admin role is required for the admin:models scope.")
        db.execute("INSERT INTO api_tokens(id, user_id, name, token_prefix, token_hash, scopes_json, created_at, expires_at) VALUES(?,?,?,?,?,?,?,?)",
                   (tid, user["id"], item.name, raw[:14], store.digest(raw), json.dumps(item.scopes), ts, expires_at))
        row = db.execute("SELECT * FROM api_tokens WHERE id=?", (tid,)).fetchone()
        store.audit(db, "auth.token_create", user["id"], user["id"], {"tokenId": tid, "name": item.name, "scopes": item.scopes, "expiresAt": store.iso(expires_at)})
    return {"token": raw, "apiToken": _token_view(row)}


@router.delete("/auth/tokens/{tid}")
def revoke_api_token(tid: UUID, auth=Depends(_auth)):
    user, _ = auth
    with store.connection(write=True) as db:
        if not db.execute("UPDATE api_tokens SET revoked_at=? WHERE id=? AND user_id=? AND revoked_at IS NULL", (store.now(), str(tid), user["id"])).rowcount:
            raise HTTPException(404, "API token not found.")
        store.audit(db, "auth.token_revoke", user["id"], user["id"], {"tokenId": str(tid)})
    return {"revoked": True, "id": str(tid)}


@router.get("/admin/users/{uid}/sessions", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
def admin_list_user_sessions(uid: UUID, _=Depends(account_admin.admin)):
    with store.connection() as db:
        account_admin.account(db, uid)
        rows = db.execute("SELECT id, device_name, created_at, expires_at, last_seen_at FROM sessions WHERE user_id=? AND revoked_at IS NULL AND expires_at>? ORDER BY last_seen_at DESC, created_at DESC",
                          (str(uid), store.now())).fetchall()
    return {"userId": str(uid), "sessions": [_session_view(r) for r in rows]}


@router.post("/admin/users/{uid}/revoke-sessions", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
def admin_revoke_user_sessions(uid: UUID, item: RevokeSessionsInput | None = Body(default=None), actor=Depends(account_admin.admin)):
    ts = store.now()
    with store.connection(write=True) as db:
        current = account_admin.account(db, actor["id"])
        if current["disabled"] or current["role"] != "admin":
            raise HTTPException(403, "Admin access required.")
        account_admin.account(db, uid)
        sid = str(item.sessionId) if item and item.sessionId else None
        if sid is not None:
            if not db.execute("UPDATE sessions SET revoked_at=? WHERE id=? AND user_id=? AND revoked_at IS NULL", (ts, sid, str(uid))).rowcount:
                raise HTTPException(404, "Session not found.")
            revoked = 1
        else:
            revoked = db.execute("UPDATE sessions SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL", (ts, str(uid))).rowcount
        store.audit(db, "admin.revoke_sessions", str(uid), actor["id"], {"sessionId": sid, "revokedCount": revoked})
    return {"userId": str(uid), "revokedCount": revoked}


@router.get("/admin/rate-limits", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
def admin_list_rate_limits(_=Depends(account_admin.admin)):
    names, entries, mono_now, wall_now = _limiter_names(), [], time.monotonic(), store.now()
    for lim in rate_limit._LIMITERS:
        lname = names.get(id(lim), "limiter")
        with lim._lock:
            items = list(lim._buckets.items())
        for key, (count, start) in items:
            if (elapsed := mono_now - start) >= lim.window_seconds:
                continue
            reset_in = max(1, int(lim.window_seconds - elapsed + 0.999))
            entries.append({"source": "memory", "limiter": lname, "keyHash": store.digest(key), "maskedKey": _mask_key(key),
                            "count": count, "max": lim.max_requests, "remaining": max(0, lim.max_requests - count),
                            "resetAt": store.iso(wall_now + reset_in * 1000), "resetInSeconds": reset_in})
    with store.connection() as db:
        for table, col, win_ms in (("login_windows", "address", account_auth.IP_WINDOW_MS), ("login_email_windows", "email", account_auth.EMAIL_WINDOW_MS)):
            for row in db.execute(f"SELECT {col} AS k, start, hits FROM {table} WHERE start > ?", (wall_now - win_ms,)).fetchall():
                reset_at = row["start"] + win_ms
                entries.append({"source": table, "limiter": "credential", "keyHash": store.digest(row["k"]), "maskedKey": _mask_key(row["k"]),
                                "count": row["hits"], "max": account_auth.MAX_LOGIN_ATTEMPTS, "remaining": max(0, account_auth.MAX_LOGIN_ATTEMPTS - row["hits"]),
                                "resetAt": store.iso(reset_at), "resetInSeconds": max(1, (reset_at - wall_now + 999) // 1000)})
    return {"entries": entries, "total": len(entries)}


@router.delete("/admin/rate-limits", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
def admin_clear_rate_limits(
    limiter: str | None = Query(default=None, max_length=40), keyHash: str | None = Query(default=None, max_length=64),
    key: str | None = Query(default=None, max_length=254), body: RateLimitUnlockInput | None = Body(default=None),
    actor=Depends(account_admin.admin),
):
    target_lim = body.limiter if body and body.limiter is not None else limiter
    target_hash = body.keyHash if body and body.keyHash is not None else keyHash
    target_key = body.key if body and body.key is not None else key
    if target_lim is not None and target_lim not in _VALID_LIMITERS:
        raise HTTPException(422, "Unknown rate limiter.")
    if target_hash is not None:
        target_hash = target_hash.strip().lower()
        if not re.fullmatch(r"[a-f0-9]{64}", target_hash):
            raise HTTPException(422, "Invalid keyHash.")
    norm_addr = account_auth.normalize_address(target_key) if target_key is not None else None
    key_lower = target_key.strip().lower() if target_key is not None else None
    names, cleared = _limiter_names(), 0
    for lim in rate_limit._LIMITERS:
        if target_lim is not None and names.get(id(lim), "limiter") != target_lim:
            continue
        with lim._lock:
            if target_hash is None and target_key is None:
                cleared += len(lim._buckets)
                lim._buckets.clear()
            else:
                for v in [k for k in lim._buckets if (target_hash and store.digest(k) == target_hash) or (target_key is not None and k in {target_key, norm_addr})]:
                    del lim._buckets[v]
                    cleared += 1
    with store.connection(write=True) as db:
        current = account_admin.account(db, actor["id"])
        if current["disabled"] or current["role"] != "admin":
            raise HTTPException(403, "Admin access required.")
        if target_lim in (None, "credential"):
            for table, col in (("login_windows", "address"), ("login_email_windows", "email")):
                if target_hash is None and target_key is None:
                    cleared += db.execute(f"DELETE FROM {table}").rowcount
                else:
                    for row in db.execute(f"SELECT {col} AS k FROM {table}").fetchall():
                        rk = row["k"]
                        if (target_hash and store.digest(rk) == target_hash) or (target_key is not None and rk in {target_key, norm_addr, key_lower}):
                            cleared += db.execute(f"DELETE FROM {table} WHERE {col}=?", (rk,)).rowcount
        store.audit(db, "admin.rate_limit_unlock", None, actor["id"], {"limiter": target_lim or "all", "keyHash": target_hash, "cleared": cleared})
    return {"cleared": cleared}
