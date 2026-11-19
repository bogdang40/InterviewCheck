from fastapi.testclient import TestClient
import pytest
from unittest.mock import AsyncMock

from api import access
from api.main import app
from api.origin import browser_origin, public_origin


def test_next_forwarding_requires_a_recognized_browser_authority(monkeypatch):
    monkeypatch.delenv("INTERVIEWCHECK_PUBLIC_ORIGIN", raising=False)
    monkeypatch.setenv("INTERVIEWCHECK_WEB_PORT", "3123")
    headers = {"host": "127.0.0.1:8000", "x-forwarded-host": "localhost:3123"}
    assert browser_origin(headers, "http") == "http://localhost:3123"
    assert browser_origin(headers, "ws") == "http://localhost:3123"
    assert browser_origin({**headers, "x-forwarded-host": "localhost:3124"}, "http") is None
    assert browser_origin({**headers, "x-forwarded-host": "attacker.invalid"}, "http") is None
    assert browser_origin({**headers, "host": "attacker.invalid"}, "http") is None
    assert browser_origin({"host": "[::1]:8765"}, "http") == "http://[::1]:8765"


@pytest.mark.parametrize("host", ["name@localhost:3000", "localhost:3000,domain", "localhost:bad", "localhost:3000/path"])
def test_invalid_forwarded_host(monkeypatch, host):
    monkeypatch.delenv("INTERVIEWCHECK_PUBLIC_ORIGIN", raising=False)
    assert browser_origin({"host": "127.0.0.1:8000", "x-forwarded-host": host}, "http") is None


def test_public_origin_forces_operator_auth_and_exact_https_origin(monkeypatch, tmp_path):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "workspace.db"))
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_MODE", raising=False)
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_URL", raising=False)
    monkeypatch.delenv("INTERVIEWCHECK_OPERATOR_EMAIL", raising=False)
    monkeypatch.setenv("INTERVIEWCHECK_PUBLIC_ORIGIN", "https://review.example.test")
    with pytest.raises(ValueError, match="operator"):
        public_origin()
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "http://127.0.0.1:8787")
    monkeypatch.setenv("INTERVIEWCHECK_OPERATOR_EMAIL", "test@example.test")
    monkeypatch.delenv("INTERVIEWCHECK_OPERATOR_ID", raising=False)
    with pytest.raises(ValueError, match="INTERVIEWCHECK_OPERATOR_ID"):
        public_origin()
    monkeypatch.setenv("INTERVIEWCHECK_OPERATOR_ID", "11111111-1111-4111-8111-111111111111")
    with TestClient(app, base_url="http://127.0.0.1:8000") as c:
        headers = {"x-forwarded-host": "review.example.test", "origin": "https://review.example.test"}
        assert c.get("/api/health", headers=headers).json() == {"ok": True}
        assert c.get("/api/sessions", headers=headers).status_code == 401
        assert c.get("/api/health", headers={**headers, "origin": "http://review.example.test"}).status_code == 403
        assert c.get("/api/health", headers={**headers, "x-forwarded-host": "other.example.test"}).status_code == 400


def test_public_remote_workspace_binds_login_and_session_to_provisioned_id(monkeypatch, tmp_path):
    uid = "11111111-1111-4111-8111-111111111111"
    email = "operator@example.test"
    public = "https://review.example.test"
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "workspace.db"))
    monkeypatch.setenv("INTERVIEWCHECK_PUBLIC_ORIGIN", public)
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://access.example.test")
    monkeypatch.setenv("INTERVIEWCHECK_OPERATOR_EMAIL", email)
    monkeypatch.setenv("INTERVIEWCHECK_OPERATOR_ID", uid)
    remote = AsyncMock(return_value={"user": {"id": "unassigned", "email": email},
                                    "entitlement": {"active": True}, "token": "fixture"})
    monkeypatch.setattr(access, "upstream", remote)
    headers = {"Origin": public, "X-Forwarded-Host": "review.example.test", "X-InterviewCheck": "1"}
    form = {"email": email, "password": "fixture-password"}
    with TestClient(app, base_url="https://127.0.0.1:8000", headers=headers) as c:
        assert c.post("/api/integrations/access/signup", json=form).status_code == 403
        remote.assert_not_called()
        denied = c.post("/api/integrations/access/login", json=form)
        assert denied.status_code == 403 and "set-cookie" not in denied.headers
        remote.return_value["user"]["id"] = uid
        c.post("/api/integrations/access/login", json=form).raise_for_status()
        assert c.get("/api/sessions").status_code == 200
        remote.return_value["user"]["id"] = "unassigned"
        assert c.get("/api/sessions").status_code == 403
