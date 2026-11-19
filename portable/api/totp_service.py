"""Pure-stdlib RFC 6238 TOTP 2FA and single-use hashed backup code management."""
import base64
import hashlib
import hmac
import re
import secrets
import struct
from urllib.parse import quote
from uuid import uuid4

from pydantic import BaseModel, Field, SecretStr, field_validator

from . import account_db as store, secret_box

ISSUER = "InterviewCheck"
TOTP_PERIOD_S = 30
TOTP_DIGITS = 6
BACKUP_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
BACKUP_COUNT = 8


class TotpCodeInput(BaseModel):
    code: str = Field(min_length=6, max_length=32)

    @field_validator("code")
    @classmethod
    def validate_code(cls, value: str) -> str:
        cleaned = value.strip()
        if not re.fullmatch(r"\d{6}", cleaned):
            raise ValueError("Verification code must be 6 digits.")
        return cleaned


class TotpDisableInput(BaseModel):
    currentPassword: SecretStr = Field(min_length=10, max_length=200)
    code: str = Field(min_length=6, max_length=32)

    @field_validator("code")
    @classmethod
    def clean_code(cls, value: str) -> str:
        cleaned = value.strip()
        if len(cleaned) < 6:
            raise ValueError("Verification code is required.")
        return cleaned


def _decode_base32(secret_base32: str) -> bytes:
    cleaned = secret_base32.strip().rstrip("=").upper()
    if not cleaned or not re.fullmatch(r"[A-Z2-7]+", cleaned):
        raise ValueError("Invalid Base32 secret.")
    pad_len = (-len(cleaned)) % 8
    return base64.b32decode(cleaned + ("=" * pad_len), casefold=False)


def generate_totp_code(secret_base32: str, now_ms: int | None = None, step_offset: int = 0) -> str:
    key = _decode_base32(secret_base32)
    ts_ms = store.now() if now_ms is None else int(now_ms)
    counter = (ts_ms // 1000 // TOTP_PERIOD_S) + step_offset
    msg = struct.pack(">Q", counter)
    digest = hmac.new(key, msg, hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    binary = struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF
    return f"{binary % (10 ** TOTP_DIGITS):06d}"


def match_totp_step(secret_base32: str, raw_code: str, now_ms: int | None = None) -> int | None:
    candidate = (raw_code or "").strip()
    if not re.fullmatch(r"\d{6}", candidate):
        return None
    ts_ms = store.now() if now_ms is None else int(now_ms)
    base_step = ts_ms // 1000 // TOTP_PERIOD_S
    cand_bytes = candidate.encode("utf-8")
    matched_step: int | None = None
    for offset in (-1, 0, 1):
        step = base_step + offset
        if step < 0:
            continue
        expected = generate_totp_code(secret_base32, ts_ms, offset).encode("utf-8")
        if hmac.compare_digest(cand_bytes, expected):
            matched_step = step
    return matched_step


def verify_totp_code(secret_base32: str, raw_code: str, now_ms: int | None = None) -> bool:
    return match_totp_step(secret_base32, raw_code, now_ms) is not None


def _create_backup_batch() -> tuple[list[str], list[str]]:
    codes: list[str] = []
    seen: set[str] = set()
    while len(codes) < BACKUP_COUNT:
        left = "".join(secrets.choice(BACKUP_CHARS) for _ in range(4))
        right = "".join(secrets.choice(BACKUP_CHARS) for _ in range(4))
        code = f"{left}-{right}"
        if code not in seen:
            seen.add(code)
            codes.append(code)
    return codes, [hashlib.sha256(code.encode("utf-8")).hexdigest() for code in codes]


def _replace_backup_codes(db, user_id: str, code_hashes: list[str], ts: int) -> None:
    db.execute("DELETE FROM user_backup_codes WHERE user_id=?", (user_id,))
    db.executemany(
        "INSERT INTO user_backup_codes (id, user_id, code_hash, used_at, created_at) VALUES (?, ?, ?, NULL, ?)",
        [(str(uuid4()), user_id, code_hash, ts) for code_hash in code_hashes],
    )


def is_enabled(db, user_id: str) -> bool:
    row = db.execute("SELECT enabled FROM user_totp WHERE user_id=?", (user_id,)).fetchone()
    return bool(row and row["enabled"] == 1)


def verify_login_factor(db, user_id: str, raw_code: str, ts: int) -> str | None:
    row = db.execute("SELECT secret_enc, enabled, last_used_step FROM user_totp WHERE user_id=?", (user_id,)).fetchone()
    if not row or row["enabled"] != 1:
        return None
    secret = secret_box.decrypt_secret(row["secret_enc"], aad=user_id)
    step = match_totp_step(secret, raw_code, ts)
    if step is not None:
        if row["last_used_step"] is not None and step <= row["last_used_step"]:
            return None
        res = db.execute(
            "UPDATE user_totp SET last_used_step=? WHERE user_id=? AND enabled=1 AND (last_used_step IS NULL OR last_used_step < ?)",
            (step, user_id, step),
        )
        return "totp" if res.rowcount == 1 else None
    clean = re.sub(r"[^A-Z0-9]", "", (raw_code or "").strip().upper())
    if len(clean) != 8:
        return None
    cand_digest = hashlib.sha256(f"{clean[:4]}-{clean[4:]}".encode("utf-8")).digest()
    unused = db.execute("SELECT id, code_hash FROM user_backup_codes WHERE user_id=? AND used_at IS NULL", (user_id,)).fetchall()
    matched_id: str | None = None
    for entry in unused:
        row_digest = bytes.fromhex(entry["code_hash"])
        if len(row_digest) == len(cand_digest) and hmac.compare_digest(row_digest, cand_digest):
            matched_id = entry["id"]
    if not matched_id:
        return None
    res = db.execute("UPDATE user_backup_codes SET used_at=? WHERE id=? AND user_id=? AND used_at IS NULL", (ts, matched_id, user_id))
    return "backup_code" if res.rowcount == 1 else None


def status(user: dict) -> dict:
    with store.connection() as db:
        row = db.execute("SELECT enabled, verified_at FROM user_totp WHERE user_id=?", (user["id"],)).fetchone()
        if not row or row["enabled"] != 1:
            return {"enabled": False, "verifiedAt": None, "remainingBackupCodes": 0}
        remaining = db.execute("SELECT COUNT(*) FROM user_backup_codes WHERE user_id=? AND used_at IS NULL", (user["id"],)).fetchone()[0]
    return {"enabled": True, "verifiedAt": store.iso(row["verified_at"]), "remainingBackupCodes": int(remaining)}


def setup(user: dict) -> dict:
    ts = store.now()
    secret = base64.b32encode(secrets.token_bytes(20)).decode("ascii")
    secret_enc = secret_box.encrypt_secret(secret, aad=user["id"])
    with store.connection(write=True) as db:
        existing = db.execute("SELECT enabled FROM user_totp WHERE user_id=?", (user["id"],)).fetchone()
        if existing and existing["enabled"] == 1:
            raise store.AccountError(409, "totp_already_enabled", "Two-factor authentication is already enabled.")
        db.execute(
            """INSERT INTO user_totp (user_id, secret_enc, enabled, verified_at, created_at, last_used_step)
               VALUES (?, ?, 0, NULL, ?, NULL)
               ON CONFLICT(user_id) DO UPDATE SET secret_enc=excluded.secret_enc, enabled=0, verified_at=NULL, created_at=excluded.created_at, last_used_step=NULL""",
            (user["id"], secret_enc, ts),
        )
    label = f"{quote(ISSUER, safe='')}:{quote(user['email'], safe='')}"
    uri = f"otpauth://totp/{label}?secret={secret}&issuer={quote(ISSUER, safe='')}&algorithm=SHA1&digits=6&period=30"
    return {"secret": secret, "otpauthUri": uri, "issuer": ISSUER}


def verify(user: dict, code: str) -> dict:
    ts = store.now()
    codes, hashes = _create_backup_batch()
    with store.connection(write=True) as db:
        row = db.execute("SELECT secret_enc, enabled, last_used_step FROM user_totp WHERE user_id=?", (user["id"],)).fetchone()
        if not row:
            raise store.AccountError(400, "totp_not_setup", "Two-factor setup has not been started.")
        if row["enabled"] == 1:
            raise store.AccountError(409, "totp_already_enabled", "Two-factor authentication is already enabled.")
        step = match_totp_step(secret_box.decrypt_secret(row["secret_enc"], aad=user["id"]), code, ts)
        if step is None or (row["last_used_step"] is not None and step <= row["last_used_step"]):
            raise store.AccountError(400, "invalid_totp_code", "Verification code is invalid or expired.")
        res = db.execute(
            "UPDATE user_totp SET enabled=1, verified_at=?, last_used_step=? WHERE user_id=? AND enabled=0 AND (last_used_step IS NULL OR last_used_step < ?)",
            (ts, step, user["id"], step),
        )
        if res.rowcount != 1:
            raise store.AccountError(400, "invalid_totp_code", "Verification code is invalid or expired.")
        _replace_backup_codes(db, user["id"], hashes, ts)
        store.audit(db, "auth.totp_enabled", user["id"], user["id"])
    return {"enabled": True, "verifiedAt": store.iso(ts), "backupCodes": codes}


def disable(user: dict, current_password: str, code: str) -> dict:
    with store.connection() as db:
        u_row = db.execute("SELECT password_hash FROM users WHERE id=?", (user["id"],)).fetchone()
    if not store.matches(current_password, u_row["password_hash"] if u_row else store.DECOY):
        raise store.AccountError(401, "invalid_credentials", "Current password is incorrect.")
    ts = store.now()
    with store.connection(write=True) as db:
        if not is_enabled(db, user["id"]):
            raise store.AccountError(400, "totp_not_enabled", "Two-factor authentication is not enabled.")
        if not verify_login_factor(db, user["id"], code, ts):
            raise store.AccountError(401, "invalid_totp_code", "Invalid two-factor authentication code.")
        db.execute("DELETE FROM user_backup_codes WHERE user_id=?", (user["id"],))
        db.execute("DELETE FROM user_totp WHERE user_id=?", (user["id"],))
        store.audit(db, "auth.totp_disabled", user["id"], user["id"])
    return {"enabled": False}


def regenerate_backup_codes(user: dict, code: str) -> dict:
    ts = store.now()
    codes, hashes = _create_backup_batch()
    with store.connection(write=True) as db:
        row = db.execute("SELECT secret_enc, enabled, last_used_step FROM user_totp WHERE user_id=?", (user["id"],)).fetchone()
        if not row or row["enabled"] != 1:
            raise store.AccountError(400, "totp_not_enabled", "Two-factor authentication is not enabled.")
        step = match_totp_step(secret_box.decrypt_secret(row["secret_enc"], aad=user["id"]), code, ts)
        if step is None or (row["last_used_step"] is not None and step <= row["last_used_step"]):
            raise store.AccountError(401, "invalid_totp_code", "Invalid two-factor authentication code.")
        res = db.execute(
            "UPDATE user_totp SET last_used_step=? WHERE user_id=? AND enabled=1 AND (last_used_step IS NULL OR last_used_step < ?)",
            (step, user["id"], step),
        )
        if res.rowcount != 1:
            raise store.AccountError(401, "invalid_totp_code", "Invalid two-factor authentication code.")
        _replace_backup_codes(db, user["id"], hashes, ts)
        store.audit(db, "auth.totp_backup_regenerated", user["id"], user["id"])
    return {"backupCodes": codes}
