"""Verify a closed, extracted database snapshot without opening a live workspace."""
from collections.abc import Sequence
from contextlib import closing
import hashlib
import os
from pathlib import Path
import sqlite3
import stat

from . import account_db, secret_box, totp_service
from .model_schemas import KEY_REQUIRED_PROVIDERS
from .encrypted_columns import ALERT_SIGNING_SECRETS, MODEL_API_KEYS, TOTP_SECRETS

# The review database has no numbered migration version. Identify the core
# records and every supported encrypted column. Never migrate a rehearsal input.
SCHEMA = {
    "review": {
        "sessions": {"id", "candidate", "role", "policy", "consent", "created_at"},
        "answers": {"id", "session_id", "question", "answer", "refs", "result", "revision"},
        "roles": {"id", "name", "questions"},
        "session_context": {"session_id", "role_id", "permitted_sources"},
        "connected_models": {"id", "provider", "capability", "model_id", "encrypted_api_key", "key_hint"},
        "alert_rules": {"id", "trigger_type", "webhook_url", "encrypted_signing_secret", "secret_hint"},
    },
    "access": {
        "users": {"id", "email", "role", "password_hash", "disabled", "created_at", "updated_at",
                  "trial_ends_at", "complimentary_until", "last_login_at", "stripe_customer_id"},
        "sessions": {"id", "user_id", "expires_at", "token_hash", "device_name", "created_at", "last_seen_at", "revoked_at"},
        "subscriptions": {"id", "user_id", "status", "plan", "current_period_end", "updated_at", "stripe_customer_id"},
        "audit_log": {"id", "at", "actor_user_id", "action", "target_user_id", "details", "prev_hash", "entry_hash"},
        "user_totp": {"user_id", "secret_enc", "enabled", "created_at", "verified_at", "last_used_step"},
        "user_backup_codes": {"id", "user_id", "code_hash", "created_at", "used_at"},
        "login_windows": {"address", "start", "hits"},
        "login_email_windows": {"email", "start", "hits"},
    },
}
RELATIONS = {
    "review": (("answers", "session_id", "sessions"), ("session_context", "session_id", "sessions")),
    "access": (("sessions", "user_id", "users"), ("user_totp", "user_id", "users")),
}
COLUMNS = {"review": (MODEL_API_KEYS, ALERT_SIGNING_SECRETS), "access": (TOTP_SECRETS,)}
MAX_ENVELOPE_BYTES = 16384
MAX_AAD_BYTES = 1024


class SnapshotError(Exception):
    """Only fixed public outcome codes are passed to this exception."""


def _identity(path: Path) -> tuple[int, int, int, int, int]:
    try:
        info = path.lstat()
    except FileNotFoundError as exc:
        raise SnapshotError("snapshot_missing") from exc
    if not stat.S_ISREG(info.st_mode):
        raise SnapshotError("snapshot_not_regular")
    for suffix in ("-wal", "-shm", "-journal"):
        try:
            Path(str(path) + suffix).lstat()
        except FileNotFoundError:
            continue
        raise SnapshotError("snapshot_has_sidecar")
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def _check_schema(db: sqlite3.Connection, kind: str) -> None:
    if kind == "access" and db.execute("PRAGMA user_version").fetchone()[0] != account_db.VERSION:
        raise SnapshotError("unsupported_access_version")
    _check_tables(db, SCHEMA[kind], RELATIONS[kind])


def _check_tables(db, tables, relations):
    for table, required in tables.items():
        entry = db.execute("SELECT type FROM pragma_table_list(?) WHERE schema='main' AND name=?",
                           (table, table)).fetchone()
        columns = dict(db.execute("SELECT name, pk FROM pragma_table_info(?)", (table,)))
        primary = {"session_context": "session_id", "user_totp": "user_id",
                   "login_windows": "address", "login_email_windows": "email"}.get(table, "id")
        if entry != ("table",) or not required.issubset(columns) or columns.get(primary) != 1:
            raise SnapshotError("schema_mismatch")
    for table, column, parent in relations:
        relation = db.execute('SELECT 1 FROM pragma_foreign_key_list(?) WHERE "from"=? AND "table"=? AND "to"=?',
                              (table, column, parent, "id")).fetchone()
        if relation is None:
            raise SnapshotError("schema_mismatch")


def _verify_rows(db, column, keys):
    # Only the three internal column descriptors supply SQL identifiers. Bound
    # what a damaged row can transfer from SQLite to the decryptor at one time.
    aad, token = column.aad_column, column.column
    where = "1" if column == TOTP_SECRETS else f"{token} IS NOT NULL"
    sql = f"""SELECT CASE WHEN typeof({aad})='text' AND length(CAST({aad} AS BLOB)) BETWEEN 1 AND ?
                          THEN {aad} END,
                     CASE WHEN typeof({token})='text' AND length(CAST({token} AS BLOB)) BETWEEN 1 AND ?
                          THEN {token} END
              FROM {column.table} WHERE {where}"""
    counts = {"encrypted": 0, "verified": 0, "failed": 0}
    for row_id, ciphertext in db.execute(sql, (MAX_AAD_BYTES, MAX_ENVELOPE_BYTES)):
        counts["encrypted"] += 1
        if row_id is None or ciphertext is None:
            counts["failed"] += 1
            continue
        try:
            plaintext = secret_box.decrypt_with_keyring(ciphertext, keys, aad=row_id)
            if not plaintext.strip():
                raise ValueError("Empty credential.")
            if column == TOTP_SECRETS:
                # Exercise the application's Base32 parser on the recovered seed.
                # Use a fixed counter and discard the resulting code.
                totp_service.generate_totp_code(plaintext, now_ms=30000)
        except (secret_box.SecretBoxError, ValueError):
            counts["failed"] += 1
        else:
            counts["verified"] += 1
    if column == MODEL_API_KEYS:
        # Optional local models can legitimately lack a key. Preserve that distinction
        # when another credential, such as a TOTP seed, authenticates successfully.
        providers = sorted(KEY_REQUIRED_PROVIDERS)
        placeholders = ", ".join("?" for _ in providers)
        counts["missing_required"] = db.execute(
            f"SELECT COUNT(*) FROM connected_models WHERE encrypted_api_key IS NULL "
            f"AND (provider IN ({placeholders}) OR COALESCE(key_hint, '') <> '')",
            providers,
        ).fetchone()[0]
    if column == ALERT_SIGNING_SECRETS:
        counts["missing_required"] = db.execute(
            "SELECT COUNT(*) FROM alert_rules WHERE encrypted_signing_secret IS NULL AND COALESCE(secret_hint, '') <> ''"
        ).fetchone()[0]
    return counts


def _check_digest(path, expected, initial):
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0)
    with os.fdopen(os.open(path, flags), "rb") as source:
        info = os.fstat(source.fileno())
        if (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns) != initial:
            raise SnapshotError("snapshot_changed")
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    if digest != expected:
        raise SnapshotError("snapshot_digest_mismatch")


def verify_snapshot(path: Path, kind: str, keys: Sequence[tuple[str, bytes]], expected_digest: str | None = None) -> dict:
    verified_identity = None
    try:
        initial = _identity(path)
        if expected_digest is not None:
            _check_digest(path, expected_digest, initial)
            verified_identity = initial
        uri = path.absolute().as_uri() + "?mode=ro&immutable=1"
        with closing(sqlite3.connect(uri, uri=True, timeout=0)) as db:
            db.execute("PRAGMA query_only=ON")
            db.execute("PRAGMA trusted_schema=OFF")
            _check_schema(db, kind)
            if db.execute("PRAGMA integrity_check(1)").fetchone() != ("ok",):
                raise SnapshotError("integrity_failed")
            if db.execute("PRAGMA foreign_key_check").fetchone() is not None:
                raise SnapshotError("foreign_keys_failed")
            tables = {column.table: _verify_rows(db, column, keys) for column in COLUMNS[kind]}
        if _identity(path) != initial:
            raise SnapshotError("snapshot_changed")
        failed = any(c["failed"] or c.get("missing_required", 0) for c in tables.values())
        result = {"status": "credential_check_failed" if failed else "checked", "tables": tables}
    except SnapshotError as exc:
        result = {"status": str(exc)}
    except (OSError, sqlite3.Error, UnicodeError, ValueError):
        result = {"status": "snapshot_unreadable"}
    if verified_identity is not None:
        try:
            if _identity(path) != verified_identity:
                raise SnapshotError("snapshot_changed")
        except (OSError, SnapshotError):
            return {"status": "snapshot_changed"}
        result["digest_matched"] = True
    return result



def check_historical_pair(review: Path, access: Path, review_sha256: str, access_sha256: str) -> None:
    """Validate closed copies from the supported version 7 writer before any migration."""
    if review.samefile(access):
        raise SnapshotError("same_snapshot")
    # Use the column contracts of the actual version 7 writer. Later releases
    # added TOTP enrollments, audit hash fields and encrypted alert secrets.
    tables = {
        "review": {name: SCHEMA["review"][name] for name in ("sessions", "answers", "roles", "session_context", "connected_models")},
        "access": {
            "users": {"id", "email", "role", "password_hash", "created_at", "updated_at"},
            "sessions": {"id", "token_hash", "user_id", "expires_at"},
            "subscriptions": {"id", "user_id", "status", "stripe_customer_id"},
            "stripe_events": {"id", "applied_at"},
            "audit_log": {"id", "at", "actor_user_id", "action"},
        },
    }
    pair = (("review", review, review_sha256), ("access", access, access_sha256))
    identities = {kind: _identity(path) for kind, path, _ in pair}
    for kind, path, expected in pair:
        _check_digest(path, expected.lower(), identities[kind])
        with closing(sqlite3.connect(path.absolute().as_uri() + "?mode=ro&immutable=1", uri=True)) as db:
            db.execute("PRAGMA query_only=ON")
            db.execute("PRAGMA trusted_schema=OFF")
            if kind == "access" and db.execute("PRAGMA user_version").fetchone() != (7,):
                raise SnapshotError("unsupported_historical_schema")
            _check_tables(db, tables[kind], RELATIONS["review"] if kind == "review" else RELATIONS["access"][:1])
            if db.execute("PRAGMA integrity_check(1)").fetchone() != ("ok",) or db.execute("PRAGMA foreign_key_check").fetchone():
                raise SnapshotError("integrity_failed")
    if any(_identity(path) != identities[kind] for kind, path, _ in pair):
        raise SnapshotError("snapshot_changed")
