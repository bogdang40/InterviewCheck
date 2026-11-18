from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from api import store
from api.main import app


SESSION = {"candidate": "Fixture", "role": "Engineer", "consent": True, "policy": "Reference manuals permitted."}


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "workspace.sqlite"))
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_URL", raising=False)
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_MODE", raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def test_session_keeps_its_role_plan_after_role_edits_and_retries(client):
    first = {"id": str(uuid4()), "name": "Engineer", "questions": ["Test A?"]}
    second = {**first, "id": str(uuid4()), "questions": ["Test B?"]}
    for role in (first, second):
        client.post("/api/roles", json=role).raise_for_status()
    payload = {**SESSION, "id": str(uuid4()), "role_id": second["id"]}
    assert client.post("/api/sessions", json=payload).json()["planned_questions"] == ["Test B?"]
    edited = {**second, "name": "Senior engineer", "questions": ["Test C?"]}
    client.put("/api/roles/" + second["id"], json=edited).raise_for_status()
    historical = client.post("/api/sessions", json=payload)
    historical.raise_for_status()
    assert historical.json()["role"] == "Engineer"
    assert historical.json()["planned_questions"] == ["Test B?"]
    assert client.post("/api/sessions", json={**payload, "role_id": first["id"]}).status_code == 409
    new = client.post("/api/sessions", json={**payload, "id": str(uuid4()), "role": "Senior engineer"})
    assert new.json()["planned_questions"] == ["Test C?"]


def test_finishing_freezes_capture_and_keeps_review_available(client):
    session = client.post("/api/sessions", json=SESSION).json()
    route = "/api/sessions/" + session["id"]
    exchange = {"id": str(uuid4()), "question": "How?", "answer": "I used the reference manual."}
    answers = route + "/answers"
    item = client.post(answers, json=exchange).json()
    end = client.post(route + "/finish").json()["ended_at"]
    assert end and client.post(route + "/finish").json()["ended_at"] == end
    assert client.post(answers, json=exchange).json()["id"] == item["id"]
    assert client.post(answers, json={**exchange, "id": str(uuid4())}).status_code == 409
    detail = answers + "/" + item["id"]
    assert client.put(detail, json={**exchange, "answer": "Edited."}).status_code == 409
    client.patch(detail, json={"note": "Explained source", "disposition": "explained"}).raise_for_status()
    assert end in client.get(route + "/report").text
    assert end in client.get(route + "/print").text
    assert client.post(route + "/reopen").json()["ended_at"] is None
    assert client.post(answers, json={**exchange, "id": str(uuid4())}).status_code == 201


def test_existing_workspace_upgrades_without_guessing_a_duplicate_role(client):
    client.post("/api/roles", json={"name": "Engineer", "questions": ["One?"]}).raise_for_status()
    client.post("/api/roles", json={"name": "Engineer", "questions": ["Two?"]}).raise_for_status()
    key = str(uuid4())
    with store.connection(write=True) as db:
        db.execute("INSERT INTO sessions VALUES (?,?,?,?,?,?,?)",
                   (key, "Example", "Engineer", "Manual allowed", 1, store.timestamp(), '{"ended_at":1609462800000}'))
    store.initialize(store.db_path())
    upgraded = client.get("/api/sessions/" + key).json()
    assert upgraded["planned_questions"] == [] and upgraded["role_id"] is None
    assert upgraded["ended_at"].startswith("2021-01-01")
    client.post("/api/sessions/" + key + "/reopen").raise_for_status()
    store.initialize(store.db_path())
    assert client.get("/api/sessions/" + key).json()["ended_at"] is None
