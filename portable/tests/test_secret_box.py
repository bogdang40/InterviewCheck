import base64
import os
import stat
import pytest

from api import secret_box


@pytest.fixture(autouse=True)
def isolated_store(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.delenv("INTERVIEWCHECK_MODEL_SECRET_KEY", raising=False)
    monkeypatch.delenv("INTERVIEWCHECK_MODEL_SECRET_FILE", raising=False)


def test_encrypt_decrypt_roundtrip_and_multiblock(monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "fixture-master-secret-key")
    aad = "11111111-2222-4333-8444-555555555555"
    secret = "sk-fixture-" + ("abc123_" * 20) + "π"
    token = secret_box.encrypt_secret(secret, aad=aad)
    assert token.startswith("v1:")
    assert secret not in token
    assert secret_box.decrypt_secret(token, aad=aad) == secret
    assert secret_box.encrypt_secret(secret, aad=aad) != token


def test_aad_mismatch_and_tampering_fail_cleanly(monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "fixture-master-secret-key")
    secret = "sk-super-secret-value-9999"
    token = secret_box.encrypt_secret(secret, aad="row-a")
    with pytest.raises(secret_box.SecretBoxError) as exc_info:
        secret_box.decrypt_secret(token, aad="row-b")
    assert secret not in str(exc_info.value)

    raw = bytearray(token[3:].encode("ascii"))
    raw[8] = ord("A") if raw[8] != ord("A") else ord("B")
    tampered = "v1:" + raw.decode("ascii")
    with pytest.raises(secret_box.SecretBoxError):
        secret_box.decrypt_secret(tampered, aad="row-a")

    with pytest.raises(secret_box.SecretBoxError):
        secret_box.decrypt_secret("v2:not-supported", aad="row-a")
    assert secret_box.decrypt_secret(None, aad="row-a") == ""
    assert secret_box.decrypt_secret("", aad="row-a") == ""


def test_non_canonical_base64_and_corrupt_key_file_fail(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "fixture-master-secret-key")
    secret = "sk-super-secret-value-9999"
    token = secret_box.encrypt_secret(secret, aad="row-a")
    b64 = token[3:]
    assert b64.endswith("=")

    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    flipped_char = alphabet[alphabet.index(b64[-2]) ^ 1]
    padded_tamper = "v1:" + b64[:-2] + flipped_char + "="
    assert base64.urlsafe_b64decode(padded_tamper[3:]) == base64.urlsafe_b64decode(b64)

    std_b64 = base64.b64encode(b"\xfb\xff" + base64.urlsafe_b64decode(b64)[2:]).decode("ascii")
    assert "+" in std_b64 and "/" in std_b64

    for bad_token in (
        padded_tamper,
        "v1:" + b64[:7] + "!!@@##" + b64[7:],
        token + " ",
        "v1:" + b64[:7] + " " + b64[7:],
        token[:-1],
        "v1:",
        "v1:π",
        "v1:" + std_b64,
    ):
        with pytest.raises(secret_box.SecretBoxError):
            secret_box.decrypt_secret(bad_token, aad="row-a")

    monkeypatch.delenv("INTERVIEWCHECK_MODEL_SECRET_KEY", raising=False)
    key_file = tmp_path / ".model_secret.key"
    valid_key_b64 = base64.urlsafe_b64encode(b"A" * 32)
    flipped_key_char = alphabet[alphabet.index(valid_key_b64.decode("ascii")[-2]) ^ 1].encode("ascii")
    non_canonical_key = valid_key_b64[:-2] + flipped_key_char + b"="
    std_key = base64.b64encode(b"\xfb\xff" + b"A" * 30)

    for bad_key in (b"!!@@##", std_key, non_canonical_key, valid_key_b64[:-1], b""):
        key_file.write_bytes(bad_key)
        key_file.chmod(0o600)
        with pytest.raises(secret_box.SecretBoxError):
            secret_box.encrypt_secret("sk-key-file-check", aad="m1")


def test_key_file_creation_permissions_and_env_switch(tmp_path, monkeypatch):
    token = secret_box.encrypt_secret("sk-file-key-test-1234", aad="m1")
    key_file = tmp_path / ".model_secret.key"
    assert key_file.is_file()
    if os.name != "nt":
        assert stat.S_IMODE(key_file.stat().st_mode) == 0o600
        key_file.chmod(0o644)
        with pytest.raises(secret_box.SecretBoxError, match="permissions"):
            secret_box.decrypt_secret(token, aad="m1")
        key_file.chmod(0o600)
    assert secret_box.decrypt_secret(token, aad="m1") == "sk-file-key-test-1234"

    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "env-key-one")
    env_token = secret_box.encrypt_secret("sk-env-secret-5678", aad="m2")
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "env-key-two")
    with pytest.raises(secret_box.SecretBoxError):
        secret_box.decrypt_secret(env_token, aad="m2")
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "env-key-one")
    assert secret_box.decrypt_secret(env_token, aad="m2") == "sk-env-secret-5678"


def test_mask_key_hint_boundaries():
    assert secret_box.mask_key_hint(None) is None
    assert secret_box.mask_key_hint("   ") is None
    assert secret_box.mask_key_hint("short") == "****"
    assert secret_box.mask_key_hint("12345678") == "****"
    assert secret_box.mask_key_hint("123456789") == "...6789"
    assert secret_box.mask_key_hint("  sk-proj-abcdef1234  ") == "...1234"
