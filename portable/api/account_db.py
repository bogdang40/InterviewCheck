"""Access database shared with the Node service."""
import base64
from contextlib import closing, contextmanager
from datetime import datetime, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import sqlite3
import time
from uuid import uuid4

from fastapi import HTTPException

DAY = 86_400_000
VERSION = 7
INDEXES = (
    "CREATE INDEX IF NOT EXISTS idx_users_created_id ON users(created_at DESC, id ASC)",
    "CREATE INDEX IF NOT EXISTS idx_audit_log_action_id ON audit_log(action, id DESC)",
    "CREATE INDEX IF NOT EXISTS idx_audit_log_actor_id ON audit_log(actor_user_id, id DESC)",
    "CREATE INDEX IF NOT EXISTS idx_audit_log_at_id ON audit_log(at DESC, id DESC)",
)
SCHEMA = [
    """CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'user', disabled INTEGER NOT NULL DEFAULT 0, trial_ends_at INTEGER,
    complimentary_until INTEGER, stripe_customer_id TEXT UNIQUE, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
    last_login_at INTEGER)""",
    """CREATE TABLE sessions (id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE, device_name TEXT, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL, revoked_at INTEGER)""",
    "CREATE INDEX idx_sessions_user ON sessions(user_id, expires_at)",
    """CREATE TABLE subscriptions (id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status TEXT NOT NULL,price_id TEXT,plan TEXT,current_period_end INTEGER,cancel_at_period_end INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL,status_changed_at INTEGER)""",
    "CREATE INDEX idx_subscriptions_user ON subscriptions(user_id,updated_at DESC)",
    """CREATE TABLE stripe_events (id TEXT PRIMARY KEY,type TEXT NOT NULL,received_at INTEGER NOT NULL,applied_at INTEGER)""",
    """CREATE TABLE audit_log (id INTEGER PRIMARY KEY AUTOINCREMENT,at INTEGER NOT NULL,actor_user_id TEXT,
    action TEXT NOT NULL,target_user_id TEXT,details TEXT)""",
    "CREATE INDEX idx_audit_log_at ON audit_log(at DESC)",
    *INDEXES,
]


def now():
    return time.time_ns() // 1_000_000


def days(key, default, low=0, high=3650):
    try:
        value = int(os.getenv(key, str(default)))
        if low <= value <= high:
            return value
    except ValueError:
        pass
    raise HTTPException(503, f"Configure {key} between {low} and {high}.")


def database():
    from .store import db_path
    path = Path(os.getenv("INTERVIEWCHECK_ACCESS_DB") or db_path().with_name("access.sqlite3"))
    if path.resolve() == db_path().resolve():
        raise HTTPException(503, "Use separate review and account database files.")
    return path


def prepare(db):
    version = db.execute("pragma user_version").fetchone()[0]
    if not 0 <= version <= VERSION:
        raise HTTPException(503, "This account database version is unsupported.")
    if version == VERSION:
        return
    if not version:
        if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").fetchone():
            raise HTTPException(503, "The selected file is not an account database.")
        for sql in SCHEMA:
            db.execute(sql)
    else:
        required = {"users", "sessions", "subscriptions", "stripe_events", "audit_log"}
        tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if not required.issubset(tables):
            raise HTTPException(503, "The selected file is not an account database.")
        if version == 1:
            db.execute("ALTER TABLE subscriptions ADD COLUMN status_changed_at INTEGER")
        if version < 3:
            db.execute("ALTER TABLE stripe_events ADD COLUMN applied_at INTEGER")
    if not db.execute("SELECT 1 FROM pragma_table_info('subscriptions') WHERE name=?", ("stripe_customer_id",)).fetchone():
        db.execute("ALTER TABLE subscriptions ADD COLUMN stripe_customer_id TEXT")
    db.execute("CREATE TABLE IF NOT EXISTS subscription_versions (id TEXT PRIMARY KEY,version INTEGER NOT NULL)")
    db.execute("""CREATE TABLE IF NOT EXISTS checkout_requests (
        user_id TEXT PRIMARY KEY REFERENCES users(id),plan TEXT NOT NULL,request_id TEXT NOT NULL,
        expires_at INTEGER NOT NULL,return_base TEXT NOT NULL,url TEXT)""")
    db.execute("CREATE TABLE IF NOT EXISTS login_windows (address TEXT PRIMARY KEY,start INTEGER NOT NULL,hits INTEGER NOT NULL)")
    db.execute("""CREATE TABLE IF NOT EXISTS api_tokens (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        token_prefix TEXT NOT NULL,
        token_hash TEXT NOT NULL UNIQUE,
        scopes_json TEXT NOT NULL DEFAULT '[]',
        created_at INTEGER NOT NULL,
        expires_at INTEGER,
        last_used_at INTEGER,
        revoked_at INTEGER)""")
    db.execute("CREATE INDEX IF NOT EXISTS idx_api_tokens_user ON api_tokens(user_id, created_at DESC)")
    db.execute("CREATE TABLE IF NOT EXISTS login_email_windows (email TEXT PRIMARY KEY,start INTEGER NOT NULL,hits INTEGER NOT NULL)")
    for sql in INDEXES:
        db.execute(sql)
    db.execute(f"PRAGMA user_version={VERSION}")


@contextmanager
def connection(*, write=False):
    path = database()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not path.exists():
        try:
            os.close(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
        except FileExistsError:
            pass
    with closing(sqlite3.connect(path, timeout=10)) as db:
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        db.execute("PRAGMA trusted_schema=OFF")
        db.execute("PRAGMA journal_mode=WAL")
        if db.execute("PRAGMA user_version").fetchone()[0] != VERSION:
            with db:
                db.execute("BEGIN IMMEDIATE")
                prepare(db)
        with db:
            db.execute("BEGIN IMMEDIATE" if write else "BEGIN")
            yield db


def audit(db, event, target, actor=None, details=None):
    db.execute("INSERT INTO audit_log(at,actor_user_id,action,target_user_id,details) VALUES(?,?,?,?,?)",
               (now(), actor, event, target, json.dumps(details) if details else None))


def check_database():
    with connection() as db:
        db.execute("SELECT 1 FROM users LIMIT 1").fetchone()
        db.execute("SELECT stripe_customer_id FROM subscriptions LIMIT 1").fetchone()


def derive(password, salt):
    return hashlib.scrypt(password.encode(), salt=salt, n=32768, r=8, p=1, dklen=64, maxmem=64 << 20)


def hash_password(password):
    salt = secrets.token_bytes(16)
    return "scrypt$32768$8$1$" + "$".join(base64.b64encode(x).decode() for x in (salt, derive(password, salt)))


DECOY = "scrypt$32768$8$1$" + base64.b64encode(secrets.token_bytes(16)).decode() + "$" + base64.b64encode(bytes(64)).decode()


def matches(password, encoded):
    try:
        algorithm, n, r, p, salt, expected = encoded.split("$")
        if (algorithm, n, r, p) != ("scrypt", "32768", "8", "1"):
            return False
        return hmac.compare_digest(derive(password, base64.b64decode(salt, validate=True)), base64.b64decode(expected, validate=True))
    except (TypeError, ValueError):
        return False


def digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


def issue(db, uid, device):
    token = "mm_" + secrets.token_urlsafe(32)
    ts = now()
    ttl = days("SESSION_TTL_DAYS", 30, 1, 365) * DAY
    db.execute("INSERT INTO sessions(id,user_id,token_hash,device_name,created_at,expires_at,last_seen_at) VALUES(?,?,?,?,?,?,?)",
               (str(uuid4()), uid, digest(token), device, ts, ts + ttl, ts))
    return token


def iso(ts):
    return datetime.fromtimestamp(ts / 1000, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z") if ts else None


def subscription_expiry(sub, offline):
    if not sub or sub["plan"] not in {"monthly", "annual"}:
        return 0
    if sub["status"] in {"active", "trialing"}:
        return sub["current_period_end"] or sub["updated_at"] + offline
    if sub["status"] == "past_due":
        return (sub["status_changed_at"] or sub["updated_at"]) + days("PAST_DUE_GRACE_DAYS", 3) * DAY
    return 0


def current_subscription(db, uid, ts, offline):
    rows = db.execute("""SELECT * FROM subscriptions WHERE user_id=?
        ORDER BY COALESCE(plan IN ('monthly','annual') AND status IN ('active','trialing','past_due'),0) DESC,
                 updated_at DESC,rowid ASC""", (uid,))
    current = rows.fetchone()
    if subscription_expiry(current, offline) <= ts:
        for sub in rows:
            expiry = subscription_expiry(sub, offline)
            if expiry > ts:
                return sub
            if not expiry:
                break  # The remaining rows cannot grant paid access.
    return current


def snapshot(db, user):
    ts = now()
    source, until = "none", None
    offline = days("OFFLINE_GRACE_DAYS", 7) * DAY
    sub = current_subscription(db, user["id"], ts, offline)
    if not user["disabled"]:
        if user["role"] == "admin":
            source = "admin"
        else:
            paid = subscription_expiry(sub, offline)
            for kind, end in (("subscription", paid), ("complimentary", user["complimentary_until"]), ("trial", user["trial_ends_at"])):
                if end and end > ts:
                    source, until = kind, end
                    break
    active = source != "none"
    grace = min(ts + offline, until) if active and until else (ts + offline if active else ts)
    return {"user": {"id": user["id"], "email": user["email"], "role": user["role"], "disabled": bool(user["disabled"]),
                     "createdAt": iso(user["created_at"]), "trialEndsAt": iso(user["trial_ends_at"]),
                     "complimentaryUntil": iso(user["complimentary_until"])},
            "entitlement": {"active": active, "source": source, "expiresAt": iso(until), "graceUntil": iso(grace),
                            "plan": sub["plan"] if sub else None, "subscriptionStatus": sub["status"] if sub else None},
            "subscription": {"id": sub["id"], "plan": sub["plan"], "status": sub["status"],
                             "currentPeriodEnd": iso(sub["current_period_end"]),
                             "cancelAtPeriodEnd": bool(sub["cancel_at_period_end"])} if sub else None, "serverTime": iso(ts)}
