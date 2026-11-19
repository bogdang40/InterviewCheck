"""Authenticated encryption at rest for model credentials using Python stdlib primitives."""
import base64
from functools import lru_cache
import hashlib
import hmac
import os
from pathlib import Path
import secrets
import stat

from . import store

PREFIX = "v1:"
NONCE_BYTES = 16
TAG_BYTES = 32
SCRYPT_SALT = b"interviewcheck-model-secret-box-v1"
MAC_DOMAIN = b"icbox:v1"
ENC_INFO = b"ic-secret-box-v1-enc"
MAC_INFO = b"ic-secret-box-v1-mac"


class SecretBoxError(Exception):
    """Raised when a model secret key or ciphertext cannot be loaded or authenticated."""


def mask_key_hint(secret: str | None) -> str | None:
    if secret is None:
        return None
    cleaned = secret.strip()
    if not cleaned:
        return None
    if len(cleaned) <= 8:
        return "****"
    return "..." + cleaned[-4:]


@lru_cache(maxsize=8)
def _derive_env_key(digest: bytes, raw_bytes: bytes) -> bytes:
    del digest
    return hashlib.scrypt(raw_bytes, salt=SCRYPT_SALT, n=16384, r=8, p=1, dklen=32)


def _key_file_path() -> Path:
    override = os.getenv("INTERVIEWCHECK_MODEL_SECRET_FILE", "").strip()
    if override:
        return Path(override)
    return store.db_path().with_name(".model_secret.key")


def _load_or_create_file_key(path: Path) -> bytes:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.exists():
        generated = base64.urlsafe_b64encode(secrets.token_bytes(32))
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            try:
                os.write(fd, generated)
            finally:
                os.close(fd)
        except FileExistsError:
            pass
    if os.name != "nt":
        try:
            mode = stat.S_IMODE(path.stat().st_mode)
        except OSError as exc:
            raise SecretBoxError("Model secret file could not be inspected.") from exc
        if (mode & 0o077) != 0:
            raise SecretBoxError("Model secret file permissions are too broad; restrict to 0600.")
    try:
        raw = path.read_bytes().strip()
        key = base64.urlsafe_b64decode(raw)
    except (OSError, ValueError) as exc:
        raise SecretBoxError("Model secret key file could not be read.") from exc
    if len(key) != 32:
        raise SecretBoxError("Model secret key file is invalid.")
    return key


def _master_key() -> bytes:
    env_key = os.getenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "").strip()
    if env_key:
        raw_bytes = env_key.encode("utf-8")
        return _derive_env_key(hashlib.sha256(raw_bytes).digest(), raw_bytes)
    return _load_or_create_file_key(_key_file_path())


def _hkdf_extract(salt: bytes, ikm: bytes) -> bytes:
    return hmac.new(salt, ikm, hashlib.sha256).digest()


def _hkdf_expand(prk: bytes, info: bytes, length: int = 32) -> bytes:
    out = bytearray()
    previous = b""
    counter = 1
    while len(out) < length:
        previous = hmac.new(prk, previous + info + bytes([counter]), hashlib.sha256).digest()
        out.extend(previous)
        counter += 1
    return bytes(out[:length])


def _xor_ctr(k_enc: bytes, nonce: bytes, data: bytes) -> bytes:
    out = bytearray(len(data))
    offset = 0
    counter = 0
    while offset < len(data):
        block = hmac.new(k_enc, nonce + counter.to_bytes(4, "big"), hashlib.sha256).digest()
        chunk = data[offset:offset + len(block)]
        for idx, byte in enumerate(chunk):
            out[offset + idx] = byte ^ block[idx]
        offset += len(chunk)
        counter += 1
    return bytes(out)


def _compute_tag(k_mac: bytes, nonce: bytes, aad: str, ciphertext: bytes) -> bytes:
    aad_bytes = aad.encode("utf-8")
    mac_input = MAC_DOMAIN + nonce + len(aad_bytes).to_bytes(4, "big") + aad_bytes + ciphertext
    return hmac.new(k_mac, mac_input, hashlib.sha256).digest()


def encrypt_secret(plaintext: str, *, aad: str = "") -> str:
    if not isinstance(plaintext, str) or plaintext == "":
        raise SecretBoxError("Cannot encrypt an empty secret.")
    master = _master_key()
    nonce = secrets.token_bytes(NONCE_BYTES)
    prk = _hkdf_extract(nonce, master)
    k_enc = _hkdf_expand(prk, ENC_INFO, 32)
    k_mac = _hkdf_expand(prk, MAC_INFO, 32)
    ciphertext = _xor_ctr(k_enc, nonce, plaintext.encode("utf-8"))
    tag = _compute_tag(k_mac, nonce, aad, ciphertext)
    token = base64.urlsafe_b64encode(nonce + tag + ciphertext).decode("ascii")
    return PREFIX + token


def decrypt_secret(ciphertext: str | None, *, aad: str = "") -> str:
    if not ciphertext:
        return ""
    if not isinstance(ciphertext, str) or not ciphertext.startswith(PREFIX):
        raise SecretBoxError("Stored model credential has an unsupported format.")
    try:
        raw = base64.urlsafe_b64decode(ciphertext[len(PREFIX):].encode("ascii"))
    except (ValueError, UnicodeError) as exc:
        raise SecretBoxError("Stored model credential could not be decoded.") from exc
    if len(raw) < NONCE_BYTES + TAG_BYTES + 1:
        raise SecretBoxError("Stored model credential is malformed.")
    nonce = raw[:NONCE_BYTES]
    tag = raw[NONCE_BYTES:NONCE_BYTES + TAG_BYTES]
    body = raw[NONCE_BYTES + TAG_BYTES:]
    master = _master_key()
    prk = _hkdf_extract(nonce, master)
    k_enc = _hkdf_expand(prk, ENC_INFO, 32)
    k_mac = _hkdf_expand(prk, MAC_INFO, 32)
    expected_tag = _compute_tag(k_mac, nonce, aad, body)
    if not hmac.compare_digest(tag, expected_tag):
        raise SecretBoxError("Stored model credential could not be decrypted.")
    try:
        return _xor_ctr(k_enc, nonce, body).decode("utf-8")
    except UnicodeDecodeError as exc:
        raise SecretBoxError("Stored model credential is not valid text.") from exc
