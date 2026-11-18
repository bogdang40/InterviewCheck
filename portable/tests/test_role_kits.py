from contextlib import closing
from uuid import uuid4
import csv
import io
import sqlite3

from fastapi.testclient import TestClient
import pytest

from api.main import app
from api import store

SOURCE = {
    "label": "Service manual",
    "text": "Discard the blue calibration disk when the paper seal separates from the housing.",
}
ALT = {
    "label": "Assembly checklist",
    "text": "Heat the copper collar until the thermal marker changes from red to black.",
}
ROLE = {
    "name": "Field engineer",
    "description": "Maintenance role",
    "questions": ["What went wrong?"],
    "policy": "Use the service manual.",
    "permitted_sources": [SOURCE],
}
ANSWER = {
    "question": "Explain the procedure.",
    "answer": SOURCE["text"],
    "references": [{"label": "Example", "text": SOURCE["text"]}],
}


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "kit.sqlite"))
    for name in ("INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(name, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def test_duplicate_role_names_snapshot_preview_capture_edit_and_reports(client):
    ids = []
    for policy, permitted in [(ROLE["policy"], [SOURCE]), ("Use the assembly checklist.", [ALT])]:
        result = client.post("/api/roles", json={**ROLE, "policy": policy, "permitted_sources": permitted})
        result.raise_for_status()
        ids.append(result.json()["id"])
    payload = {
        "id": str(uuid4()),
        "role_id": ids[0],
        "role": ROLE["name"],
        "candidate": "Fixture",
        "consent": True,
    }
    session = client.post("/api/sessions", json=payload).json()
    route = "/api/sessions/" + session["id"]
    assert session["policy"] == ROLE["policy"] and session["permitted_sources"] == [SOURCE]
    assert "permitted_sources" not in client.get("/api/sessions").json()[0]
    assert client.post("/api/preview", json=ANSWER).json()["status"] == "match"
    result = client.post(route + "/preview", json=ANSWER).json()
    assert result["status"] == "no_match"
    saved = client.post(route + "/answers", json=ANSWER).json()
    assert saved["result"] == result
    assert len(saved["references"]) == 1 and saved["references"][0]["label"] == "Example"

    edit = client.put(
        "/api/roles/" + ids[0], json={**ROLE, "permitted_sources": [], "policy": "Closed book."}
    )
    edit.raise_for_status()
    replay = client.post("/api/sessions", json=payload).json()
    assert replay["policy"] == ROLE["policy"] and replay["permitted_sources"] == [SOURCE]
    revised = client.put(
        route + "/answers/" + saved["id"],
        json={**ANSWER, "question": "What did you do?", "expected_revision": saved["revision"]},
    )
    assert revised.json()["result"]["status"] == "no_match"
    for endpoint in (route + "/report", route + "/print"):
        export = client.get(endpoint)
        assert SOURCE["label"] in export.text and SOURCE["text"] in export.text
    table = list(
        csv.DictReader(io.StringIO(client.get("/api/exports/interviews.csv").content.decode("utf-8-sig")))
    )
    assert SOURCE["label"] in table[0]["Permitted source snapshot"]

    updated = client.post("/api/sessions", json={**payload, "id": str(uuid4())}).json()
    assert updated["policy"] == "Closed book." and not updated["permitted_sources"]
    assert client.post("/api/sessions/" + updated["id"] + "/preview", json=ANSWER).json()["status"] == "match"
    alternate = client.post("/api/sessions", json={**payload, "role_id": ids[1], "id": str(uuid4())}).json()
    assert alternate["permitted_sources"] == [ALT]


def test_explicit_overrides_and_retries(client):
    role = client.post("/api/roles", json=ROLE).json()
    data = {
        "role": role["name"],
        "role_id": role["id"],
        "candidate": "Example",
        "consent": True,
        "id": str(uuid4()),
        "permitted_sources": [],
        "policy": "No references during this interview.",
    }
    created = client.post("/api/sessions", json=data)
    assert created.json()["permitted_sources"] == []
    assert created.json()["policy"] == data["policy"]
    assert client.post("/api/sessions", json={**data, "permitted_sources": [SOURCE]}).status_code == 409
    assert client.post("/api/sessions", json={**data, "role_id": None}).status_code == 409
    # A client that only knows role names/questions must keep newer policy fields.
    role = client.put(
        "/api/roles/" + role["id"], json={"name": role["name"], "description": "Current"}
    ).json()
    assert role["permitted_sources"] == [SOURCE] and role["policy"] == ROLE["policy"]
    manual = client.post("/api/sessions", json={**data, "id": str(uuid4()), "role_id": None, "policy": None})
    assert manual.status_code == 422


@pytest.mark.parametrize(
    "patch",
    [
        {"permitted_sources": [SOURCE] * 9},
        {"permitted_sources": [{"label": " ", "text": "Allowed"}]},
        {"permitted_sources": [{"label": "Huge", "text": "x" * 12001}]},
        {"policy": "x" * 4001},
    ],
)
def test_template_bounds(client, patch):
    assert client.post("/api/roles", json={**ROLE, **patch}).status_code == 422


def test_older_store_gets_empty_materials_without_reinterpreting_history(tmp_path):
    path = tmp_path / "old.db"
    with closing(sqlite3.connect(path)) as db, db:
        db.executescript("""
        CREATE TABLE roles(id TEXT PRIMARY KEY,name TEXT,description TEXT,questions TEXT,legacy TEXT);
        CREATE TABLE session_context(session_id TEXT PRIMARY KEY,role_id TEXT,questions TEXT,ended_at TEXT);
        INSERT INTO roles VALUES ('r','Field engineer','Old description','[]',NULL);
        INSERT INTO session_context VALUES ('s','r','[]',NULL);
        """)
    store.initialize(path)
    store.initialize(path)
    with store.connection(path) as db:
        role = store.role_row(db.execute("SELECT * FROM roles").fetchone())
        assert role["policy"] == "" and role["permitted_sources"] == []
        assert (
            db.execute("SELECT permitted_sources FROM session_context WHERE session_id='s'").fetchone()[0]
            == "[]"
        )


def test_imported_exchange_uses_session_materials_when_later_compared(client):
    rid = client.post("/api/roles", json=ROLE).json()["id"]
    sid = client.post(
        "/api/sessions", json={"candidate": "Import", "consent": True, "role": ROLE["name"], "role_id": rid}
    ).json()["id"]
    route = "/api/sessions/" + sid
    imported = client.post(
        route + "/imports/webvtt",
        json={
            "request_id": str(uuid4()),
            "transcript_sha256": "a" * 64,
            "candidate_speaker": "A",
            "interviewer_speakers": ["B"],
            "exchanges": [
                {
                    "ordinal": 1,
                    "start_ms": 1000,
                    "end_ms": 7000,
                    "question": ANSWER["question"],
                    "answer": ANSWER["answer"],
                }
            ],
        },
    )
    imported.raise_for_status()
    aid = imported.json()["answer_ids"][0]
    previous = client.get(route).json()["answers"][0]
    revised = client.put(
        route + "/answers/" + aid, json={**ANSWER, "expected_revision": previous["revision"]}
    )
    revised.raise_for_status()
    assert revised.json()["result"]["status"] == "no_match" and "import_origin" in revised.json()


def test_stale_role_edit_and_stale_setup_preserve_the_saved_plan(client):
    initial = client.post("/api/roles", json=ROLE).json()
    route = "/api/roles/" + initial["id"]
    setup = {
        "id": str(uuid4()), "candidate": "Fixture", "consent": True,
        "role": ROLE["name"], "role_id": initial["id"], "role_version": initial["version"],
        "policy": ROLE["policy"], "permitted_sources": [SOURCE],
    }
    original = client.post("/api/sessions", json=setup)
    original.raise_for_status()
    edited = {**ROLE, "questions": ["What changed?"], "policy": "Use the checklist.", "permitted_sources": [ALT]}
    # An edit from an older client must also invalidate current forms.
    latest = client.put(route, json=edited).json()
    assert latest["version"] != initial["version"]
    stale_edit = client.put(route, json={**initial, "description": "Other tab"})
    stale_setup = client.post("/api/sessions", json={**setup, "id": str(uuid4())})
    for response in (stale_edit, stale_setup):
        assert response.status_code == 409
        assert response.headers["X-InterviewCheck-Conflict"] == "role-version"
    assert client.get(route).json() == latest
    assert len(client.get("/api/sessions").json()) == 1
    assert client.post("/api/sessions", json=setup).json() == original.json()
    assert client.put(route, json={**latest, "description": "Reviewed"}).is_success
