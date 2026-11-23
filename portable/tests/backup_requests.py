import pytest
from fastapi.testclient import TestClient

from api.main import app


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "source.sqlite"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "accounts.sqlite"))
    for name in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PRODUCTION",
                 "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_OPERATOR_ID", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(name, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        yield client


def create_session(client):
    response = client.post("/api/sessions", json={"candidate": "Sample", "role": "Engineer", "policy": "Manual", "consent": True})
    response.raise_for_status()
    return response.json()["id"]


def preview(client, raw):
    response = client.post("/api/backups/preview", content=raw)
    response.raise_for_status()
    return response.json()


def restore(client, raw, plan):
    return client.post("/api/backups/restore", content=raw, headers={"X-Backup-Preview": plan["fingerprint"]})
