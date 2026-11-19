"""Credential and session operations shared by the Python access API."""
import hmac
import os
import re
import sqlite3
from uuid import uuid4

from fastapi import HTTPException
from pydantic import BaseModel, Field, SecretStr, field_validator

from . import account_db as store


class Login(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    password: SecretStr = Field(min_length=10, max_length=200)
    deviceName: str = Field(default="", max_length=120)
    adminSecret: SecretStr | None = Field(default=None, max_length=200)
    inviteCode: SecretStr | None = Field(default=None, max_length=200)

    @field_validator("email")
    @classmethod
    def normalize_email(cls, value):
        value = value.strip().lower()
        if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", value):
            raise ValueError("Enter a valid email address.")
        return value


class PasswordChange(BaseModel):
    currentPassword: SecretStr = Field(min_length=10, max_length=200)
    newPassword: SecretStr = Field(min_length=10, max_length=200)


def limit(address):
    ts = store.now()
    # Persist the fixed window across workers and restarts. Ignore forwarded IPs.
    with store.connection(write=True) as db:
        db.execute("DELETE FROM login_windows WHERE start <= ?", (ts - 60_000,))
        db.execute("""INSERT INTO login_windows(address,start,hits) VALUES(?,?,1)
        ON CONFLICT(address) DO UPDATE SET hits=hits+1""", (address, ts))
        count = db.execute("SELECT hits FROM login_windows WHERE address=?", (address,)).fetchone()[0]
    if count > 10:
        raise HTTPException(429, "Too many sign in attempts. Try again in a minute.")


def check_secret(configured, presented):
    return bool(configured and presented and hmac.compare_digest(configured.encode(), presented.get_secret_value().encode()))


def sign_in(action, form, address, *, public_signup=False):
    limit(address)
    if action == "signup":
        secret = os.getenv("INTERVIEWCHECK_SIGNUP_SECRET", "")
        if (public_signup or secret) and not check_secret(secret, form.inviteCode):
            raise HTTPException(403, "An operator invitation is required to create an account.")
        allowed = {e.strip().lower() for e in os.getenv("ADMIN_EMAILS", "").split(",") if e.strip()}
        admin = form.email in allowed and check_secret(os.getenv("ADMIN_BOOTSTRAP_SECRET"), form.adminSecret)
        password_hash = store.hash_password(form.password.get_secret_value())
        ts = store.now()
        uid = str(uuid4())
        trial = store.days("TRIAL_DAYS", 0)
        with store.connection(write=True) as db:
            try:
                db.execute("""INSERT INTO users(id,email,password_hash,role,trial_ends_at,created_at,updated_at,last_login_at)
                VALUES(?,?,?,?,?,?,?,?)""", (uid, form.email, password_hash, "admin" if admin else "user",
                                              ts + trial * store.DAY if trial else None, ts, ts, ts))
            except sqlite3.IntegrityError as exc:
                raise HTTPException(409, "An account with that email already exists.") from exc
            store.audit(db, "auth.signup", uid, uid)
            return new_session(db, uid, form.deviceName)
    with store.connection() as db:
        row = db.execute("SELECT id,password_hash FROM users WHERE email=?", (form.email,)).fetchone()
    valid = store.matches(form.password.get_secret_value(), row["password_hash"] if row else store.DECOY)
    if not (row and valid):
        raise HTTPException(401, "Email or password is incorrect.")
    with store.connection(write=True) as db:
        ts = store.now()
        result = db.execute("UPDATE users SET last_login_at=?,updated_at=? WHERE id=? AND disabled=0",
                            (ts, ts, row["id"]))
        if not result.rowcount:
            raise HTTPException(403, "Account is disabled.")
        store.audit(db, "auth.login", row["id"], row["id"])
        return new_session(db, row["id"], form.deviceName)


def change_password(user_id, device_name, form: PasswordChange, address: str):
    limit(address)
    with store.connection() as db:
        row = db.execute("SELECT id,password_hash FROM users WHERE id=?", (user_id,)).fetchone()
    valid = store.matches(form.currentPassword.get_secret_value(), row["password_hash"] if row else store.DECOY)
    if not (row and valid):
        raise HTTPException(401, "Current password is incorrect.")
    new_hash = store.hash_password(form.newPassword.get_secret_value())
    ts = store.now()
    with store.connection(write=True) as db:
        result = db.execute("UPDATE users SET password_hash=?,updated_at=? WHERE id=? AND disabled=0",
                            (new_hash, ts, user_id))
        if not result.rowcount:
            raise HTTPException(403, "Account is disabled.")
        db.execute("UPDATE sessions SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL", (ts, user_id))
        store.audit(db, "auth.password_change", user_id, user_id)
        return new_session(db, user_id, device_name or "Portable workspace")


def new_session(db, uid, device):
    token = store.issue(db, uid, device or None)
    user = db.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()
    return {**store.snapshot(db, user), "token": token}


def authenticate(header):
    scheme, _, token = (header or "").partition(" ")
    if scheme.lower() != "bearer" or not re.fullmatch(r"mm_[A-Za-z0-9_-]{37,125}", token):
        raise HTTPException(401, "Sign in required.")
    hashed = store.digest(token)
    ts = store.now()
    with store.connection(write=True) as db:
        session = db.execute("""SELECT s.id,s.user_id,s.expires_at FROM sessions s JOIN users u ON u.id=s.user_id
        WHERE s.token_hash=? AND s.revoked_at IS NULL AND s.expires_at>? AND u.disabled=0""", (hashed, ts)).fetchone()
        if not session:
            raise HTTPException(401, "Session expired. Sign in again.")
        ttl = store.days("SESSION_TTL_DAYS", 30, 1, 365) * store.DAY
        if session["expires_at"] - ts < ttl / 2:
            db.execute("UPDATE sessions SET expires_at=?,last_seen_at=? WHERE id=?", (ts + ttl, ts, session["id"]))
        user = db.execute("SELECT * FROM users WHERE id=?", (session["user_id"],)).fetchone()
        return dict(user), session["id"]
