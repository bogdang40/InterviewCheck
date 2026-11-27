from uuid import uuid4
from fastapi.testclient import TestClient
import pytest

from api import store
from api.main import app


@pytest.fixture
def web(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "draft.sqlite"))
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_MODE", raising=False)
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_URL", raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        session = client.post(
            "/api/sessions",
            json={"candidate": "Example", "role": "Engineer", "policy": "Manual permitted", "consent": True},
        ).json()
        yield client, "/api/sessions/" + session["id"]


def test_saved_draft_survives_restart_and_stays_out_of_reports(web):
    client, route = web
    d = {
        "id": str(uuid4()),
        "question": "How?",
        "answer": "unfinished private sentence",
        "expected_revision": 0,
    }
    saved = client.put(route + "/draft", json=d).json()
    assert saved["revision"] == 1 and client.put(route + "/draft", json=d).json() == saved
    store.initialize(store.db_path())
    assert client.get(route + "/draft").json() == saved
    assert client.get(route).json()["answer_count"] == 0
    assert "unfinished private sentence" not in client.get(route + "/report").text
    assert client.post(route + "/finish").status_code == 409
    assert (
        client.put(route + "/draft", json={**d, "answer": "Different", "expected_revision": 0}).status_code
        == 409
    )
    updated = client.put(
        route + "/draft", json={**d, "answer": "Ready to publish", "expected_revision": 1}
    ).json()
    assert updated["revision"] == 2
    assert (
        client.post(route + "/draft/discard", json={"id": d["id"], "expected_revision": 1}).status_code == 409
    )
    assert client.post(route + "/draft/publish", json={**d, "expected_revision": 1}).status_code == 409
    complete = {**d, "answer": "Ready to publish", "expected_revision": 2}
    result = client.post(route + "/draft/publish", json=complete)
    result.raise_for_status()
    assert result.json()["id"] == d["id"] and client.get(route + "/draft").json() is None
    assert client.post(route + "/draft/publish", json=complete).json()["id"] == d["id"]
    assert client.get(route).json()["answer_count"] == 1
    client.post(route + "/finish").raise_for_status()
    assert client.put(route + "/draft", json={**d, "id": str(uuid4())}).status_code == 409


def test_backup_preview_restores_only_explicit_saved_draft(web, tmp_path, monkeypatch):
    client, route = web
    d = {
        "id": str(uuid4()),
        "question": "Incomplete question",
        "expected_revision": 0,
        "references": [{"label": "Manual", "text": ""}],
    }
    saved = client.put(route + "/draft", json=d).json()
    raw = client.get("/api/backups/workspace").content
    assert saved["recovery_fingerprint"].encode() not in raw
    target = tmp_path / "restored.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
    plan = client.post("/api/backups/preview", content=raw).json()
    assert plan["drafts"] == 1 and plan["answers"] == 0
    client.post(
        "/api/backups/restore", content=raw, headers={"X-Backup-Preview": plan["fingerprint"]}
    ).raise_for_status()
    restored = client.get(route + "/draft").raise_for_status().json()
    assert restored.pop("recovery_fingerprint") != saved.pop("recovery_fingerprint")
    assert restored == saved
    client.post(
        route + "/draft/discard", json={"id": saved["id"], "expected_revision": saved["revision"]}
    ).raise_for_status()
    assert client.post(route + "/finish").status_code == 200
