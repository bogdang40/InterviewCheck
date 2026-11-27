"""Authenticated encryption at rest for model credentials using Python stdlib primitives."""
import base64
from collections.abc import Iterable
from functools import lru_cache
import hashlib
import hmac
import os
from pathlib import Path
import secrets
import stat
from typing import Literal

from . import store

PREFIX = "v1:"
V2_PREFIX = "v2:"
NONCE_BYTES = 16
TAG_BYTES = 32
SCRYPT_SALT = b"interviewcheck-model-secret-box-v1"
MAC_DOMAIN = b"icbox:v1"
MAC_DOMAIN_V2 = b"icbox:v2"
ENC_INFO = b"ic-secret-box-v1-enc"
MAC_INFO = b"ic-secret-box-v1-mac"
_HEX_CHARS = frozenset("0123456789abcdef")


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


def _derive_env_string(value: str) -> bytes:
    raw_bytes = value.encode("utf-8")
    return _derive_env_key(hashlib.sha256(raw_bytes).digest(), raw_bytes)


def _key_file_path() -> Path:
    override = os.getenv("INTERVIEWCHECK_MODEL_SECRET_FILE", "").strip()
    if override:
        return Path(override)
    return store.db_path().with_name(".model_secret.key")


def key_file_path() -> Path:
    return _key_file_path()


def _decode_urlsafe_b64(encoded: bytes) -> bytes:
    if not encoded or b"+" in encoded or b"/" in encoded:
        raise ValueError("Invalid URL-safe base64 encoding.")
    raw = base64.b64decode(encoded, altchars=b"-_", validate=True)
    if base64.urlsafe_b64encode(raw) != encoded:
        raise ValueError("Non-canonical URL-safe base64 encoding.")
    return raw


def load_key_file(path: Path) -> bytes:
    if os.name != "nt":
        try:
            mode = stat.S_IMODE(path.stat().st_mode)
        except OSError as exc:
            raise SecretBoxError("Model secret file could not be inspected.") from exc
        if (mode & 0o077) != 0:
            raise SecretBoxError("Model secret file permissions are too broad; restrict to 0600.")
    try:
        return parse_key_file(path.read_bytes())
    except OSError as exc:
        raise SecretBoxError("Model secret key file could not be read.") from exc


def parse_key_file(contents: bytes) -> bytes:
    try:
        key = _decode_urlsafe_b64(contents.strip())
    except ValueError as exc:
        raise SecretBoxError("Model secret key file could not be read.") from exc
    if len(key) != 32:
        raise SecretBoxError("Model secret key file is invalid.")
    return key


def _load_or_create_file_key(path: Path) -> bytes:
    try:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if not path.exists():
            generated = base64.urlsafe_b64encode(secrets.token_bytes(32))
            try:
                fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                try:
                    os.write(fd, generated)
                finally:
                    os.close(fd)
                if os.name != "nt":
                    os.chmod(path, 0o600)
            except FileExistsError:
                pass
    except OSError as exc:
        raise SecretBoxError("Model secret key file could not be initialized.") from exc
    return load_key_file(path)


def key_source() -> Literal["env", "file"]:
    return "env" if os.getenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "").strip() else "file"


def _master_key() -> bytes:
    env_key = os.getenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "").strip()
    if env_key:
        return _derive_env_string(env_key)
    return _load_or_create_file_key(_key_file_path())


def key_id_for(master_bytes: bytes) -> str:
    return hashlib.sha256(b"ic-kid:" + master_bytes).hexdigest()[:8]


def active_key_id() -> str:
    return key_id_for(_master_key())


def _parse_previous_env_entries() -> list[str]:
    raw = os.getenv("INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS", "")
    return list(dict.fromkeys(p.strip() for p in raw.split(",") if p.strip()))


def previous_key_count() -> int:
    return len(_parse_previous_env_entries())


def _coerce_previous_key(entry: str | bytes) -> bytes | None:
    if isinstance(entry, bytes):
        if len(entry) != 32:
            raise SecretBoxError("Invalid previous master key length.")
        return entry
    if isinstance(entry, str):
        cleaned = entry.strip()
        return _derive_env_string(cleaned) if cleaned else None
    raise SecretBoxError("Unsupported previous key type.")


def keyring(previous_keys: Iterable[str | bytes] = ()) -> list[tuple[str, bytes]]:
    return supplied_keyring((_master_key(), *previous_keys, *_parse_previous_env_entries()))


def supplied_keyring(keys: Iterable[str | bytes]) -> list[tuple[str, bytes]]:
    entries: list[tuple[str, bytes]] = []
    seen_masters: set[bytes] = set()
    for item in keys:
        master = _coerce_previous_key(item)
        if master is not None and master not in seen_masters:
            seen_masters.add(master)
            entries.append((key_id_for(master), master))
    return entries


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


def _compute_tag_v2(k_mac: bytes, nonce: bytes, kid: str, aad: str, ciphertext: bytes) -> bytes:
    kid_bytes, aad_bytes = kid.encode("ascii"), aad.encode("utf-8")
    mac_input = (
        MAC_DOMAIN_V2 + len(kid_bytes).to_bytes(2, "big") + kid_bytes
        + nonce + len(aad_bytes).to_bytes(4, "big") + aad_bytes + ciphertext
    )
    return hmac.new(k_mac, mac_input, hashlib.sha256).digest()


def _derive_keys(nonce: bytes, master: bytes) -> tuple[bytes, bytes]:
    prk = _hkdf_extract(nonce, master)
    return _hkdf_expand(prk, ENC_INFO, 32), _hkdf_expand(prk, MAC_INFO, 32)


def token_key_info(ciphertext: str | None) -> tuple[str, str | None]:
    if not isinstance(ciphertext, str) or not ciphertext:
        raise SecretBoxError("Stored model credential is empty or invalid.")
    if ciphertext.startswith(PREFIX):
        if len(ciphertext) <= len(PREFIX):
            raise SecretBoxError("Stored model credential is malformed.")
        return "v1", None
    if ciphertext.startswith(V2_PREFIX):
        rest = ciphertext[len(V2_PREFIX):]
        if ":" not in rest:
            raise SecretBoxError("Stored model credential is malformed.")
        kid, b64_part = rest.split(":", 1)
        if len(kid) != 8 or not all(ch in _HEX_CHARS for ch in kid) or not b64_part:
            raise SecretBoxError("Stored model credential is malformed.")
        return "v2", kid
    raise SecretBoxError("Stored model credential has an unsupported format.")


def encrypt_with_master(plaintext: str, master: bytes, *, aad: str = "", envelope: Literal["v1", "v2"] = "v1") -> str:
    if not isinstance(plaintext, str) or plaintext == "":
        raise SecretBoxError("Cannot encrypt an empty secret.")
    if not isinstance(master, bytes) or len(master) != 32:
        raise SecretBoxError("Invalid master key length.")
    if envelope not in ("v1", "v2"):
        raise SecretBoxError("Unsupported secret envelope version.")
    nonce = secrets.token_bytes(NONCE_BYTES)
    k_enc, k_mac = _derive_keys(nonce, master)
    ciphertext = _xor_ctr(k_enc, nonce, plaintext.encode("utf-8"))
    if envelope == "v1":
        tag = _compute_tag(k_mac, nonce, aad, ciphertext)
        return PREFIX + base64.urlsafe_b64encode(nonce + tag + ciphertext).decode("ascii")
    kid = key_id_for(master)
    tag = _compute_tag_v2(k_mac, nonce, kid, aad, ciphertext)
    return f"{V2_PREFIX}{kid}:{base64.urlsafe_b64encode(nonce + tag + ciphertext).decode('ascii')}"


def encrypt_secret(plaintext: str, *, aad: str = "", envelope: Literal["v1", "v2"] = "v1") -> str:
    return encrypt_with_master(plaintext, _master_key(), aad=aad, envelope=envelope)


def _decode_payload(b64_text: str) -> tuple[bytes, bytes, bytes]:
    try:
        raw = _decode_urlsafe_b64(b64_text.encode("ascii"))
    except (ValueError, UnicodeError) as exc:
        raise SecretBoxError("Stored model credential could not be decoded.") from exc
    if len(raw) < NONCE_BYTES + TAG_BYTES + 1:
        raise SecretBoxError("Stored model credential is malformed.")
    return raw[:NONCE_BYTES], raw[NONCE_BYTES:NONCE_BYTES + TAG_BYTES], raw[NONCE_BYTES + TAG_BYTES:]


def decrypt_secret(ciphertext: str | None, *, aad: str = "", previous_keys: Iterable[str | bytes] = ()) -> str:
    # Resolve the configured keys only after checking the envelope. A malformed
    # input, like an absent secret, must not create a workstation key file.
    def configured_keys():
        yield from keyring(previous_keys)
    return decrypt_with_keyring(ciphertext, configured_keys(), aad=aad)


def decrypt_with_keyring(ciphertext: str | None, keys: Iterable[tuple[str, bytes]], *, aad: str = "") -> str:
    if not ciphertext:
        return ""
    version, kid = token_key_info(ciphertext)
    if version == "v1":
        nonce, tag, body = _decode_payload(ciphertext[len(PREFIX):])
        candidates = [master for _, master in keys]
        compute = lambda k_mac: _compute_tag(k_mac, nonce, aad, body)
    else:
        assert kid is not None
        nonce, tag, body = _decode_payload(ciphertext[len(V2_PREFIX) + len(kid) + 1:])
        candidates = [master for k_id, master in keys if k_id == kid]
        compute = lambda k_mac: _compute_tag_v2(k_mac, nonce, kid, aad, body)

    for master in candidates:
        k_enc, k_mac = _derive_keys(nonce, master)
        if hmac.compare_digest(tag, compute(k_mac)):
            try:
                return _xor_ctr(k_enc, nonce, body).decode("utf-8")
            except UnicodeDecodeError as exc:
                raise SecretBoxError("Stored model credential is not valid text.") from exc
    raise SecretBoxError("Stored model credential could not be decrypted.")


def reencrypt_secret(ciphertext: str, *, aad: str = "", previous_keys: Iterable[str | bytes] = ()) -> str:
    if not ciphertext:
        raise SecretBoxError("Cannot re-encrypt an empty secret.")
    return encrypt_secret(decrypt_secret(ciphertext, aad=aad, previous_keys=previous_keys), aad=aad, envelope="v2")
