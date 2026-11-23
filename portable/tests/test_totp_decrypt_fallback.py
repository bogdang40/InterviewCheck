"""An undecryptable TOTP secret rejects authenticator codes normally and still accepts backup codes."""
import logging

from fastapi.testclient import TestClient
import pytest

from api import account_db, totp_service
from api.main import app

EMAIL, PASSWORD = "fallback@example.invalid", "StrongPass-1234"


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "totp-fallback-original-key")
    for key in ("INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_OPERATOR_ID",
                "INTERVIEWCHECK_PUBLIC_ORIGIN", "INTERVIEWCHECK_PRODUCTION", "INTERVIEWCHECK_SIGNUP_SECRET",
                "INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("TRIAL_DAYS", "7")
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        yield client


def _login(client, code):
    return client.post("/v1/auth/login", json={"email": EMAIL, "password": PASSWORD, "totpCode": code})


def test_lost_totp_key_falls_through_to_backup_codes(env, monkeypatch, caplog):
    token = env.post("/v1/auth/signup", json={"email": EMAIL, "password": PASSWORD, "deviceName": "PyTest"}).json()["token"]
    auth = {"Authorization": f"Bearer {token}"}
    fixed_ms = 1_760_000_010_000
    monkeypatch.setattr(account_db, "now", lambda: fixed_ms)
    setup = env.post("/v1/auth/totp/setup", json={}, headers=auth).json()
    code = totp_service.generate_totp_code(setup["secret"], fixed_ms)
    backup_codes = env.post("/v1/auth/totp/verify", json={"code": code}, headers=auth).json()["backupCodes"]

    # The master key changes without rotation, so the stored secret no longer decrypts.
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "totp-fallback-replacement-key")
    fixed_ms += 30_000
    with caplog.at_level(logging.ERROR, logger="api.totp_service"):
        rejected = _login(env, totp_service.generate_totp_code(setup["secret"], fixed_ms))
    assert rejected.status_code == 401
    assert rejected.json()["error"]["code"] == "invalid_totp_code"
    assert "could not be decrypted" in caplog.text
    assert setup["secret"] not in caplog.text and "totp-fallback" not in caplog.text

    accepted = _login(env, backup_codes[0])
    assert accepted.status_code == 200, accepted.text
    assert _login(env, backup_codes[0]).status_code == 401
