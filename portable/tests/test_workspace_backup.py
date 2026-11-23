import json
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from api import store
from api.models import EARLIER_ANSWER_NOTE, REVIEW_NOTE_LIMIT
from api.main import app

PHRASE = "Separate the winding terminals before measuring the resistance between each pair."
HEADERS = {"X-InterviewCheck": "1", "Content-Type": "application/json"}


@pytest.fixture
def workspace(tmp_path, monkeypatch):
    src = tmp_path / "source.sqlite"
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(src))
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_MODE", raising=False)
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_URL", raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers=HEADERS) as client:
        role = client.post(
            "/api/roles",
            json={
                "name": "Engineer",
                "questions": ["How?", "Why?"],
                "permitted_sources": [{"label": "Manual", "text": "Safety notes are permitted."}],
            },
        ).json()
        sid = client.post(
            "/api/sessions",
            json={
                "candidate": "Fictional",
                "role": role["name"],
                "role_id": role["id"],
                "consent": True,
                "policy": "Manual permitted",
            },
        ).json()["id"]
        route = "/api/sessions/" + sid
        aid = client.post(
            route + "/answers",
            json={
                "question": "What checks?",
                "answer": "🙂 First, " + PHRASE,
                "references": [{"label": "Practice example", "text": PHRASE}],
            },
        ).json()["id"]
        client.patch(
            route + "/answers/" + aid,
            json={"disposition": "explained", "note": "Explained the isolation step."},
        ).raise_for_status()
        client.post(route + "/finish").raise_for_status()
        raw = client.get("/api/backups/workspace", params={"session_id": sid})
        raw.raise_for_status()
        target = tmp_path / "recovered.sqlite"
        store.initialize(target)
        monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
        yield client, raw.content, route


def submit(client, path, raw, token=None):
    headers = {"X-Backup-Preview": token} if token else {}
    return client.post("/api/backups/" + path, content=raw, headers=headers)


def test_restore_preserves_snapshot_revision_evidence_and_report(workspace):
    client, raw, route = workspace
    plan = submit(client, "preview", raw).json()
    assert plan["roles"]["new"] == plan["sessions"]["new"] == 1
    assert client.get("/api/sessions").json() == []
    submit(client, "restore", raw, plan["fingerprint"]).raise_for_status()
    record = client.get(route).json()
    assert record["ended_at"] and record["consent"]
    assert record["permitted_sources"][0]["label"] == "Manual"
    assert record["planned_questions"] == ["How?", "Why?"]
    (answer,) = record["answers"]
    assert answer["revision"] == 2 and answer["disposition"] == "explained"
    assert answer["result"]["passages"][0]["answer_span"][0] > 1
    assert "Explained the isolation step." in client.get(route + "/report").text
    assert json.loads(client.get("/api/backups/workspace").content) == json.loads(raw)
    assert submit(client, "restore", raw, plan["fingerprint"]).json()["sessions"]["identical"] == 1


def test_destination_changes_after_preview_do_not_partly_restore(workspace):
    client, raw, route = workspace
    plan = submit(client, "preview", raw).json()
    client.post(
        "/api/sessions",
        json={"id": route.split("/")[-1], "candidate": "Other", "role": "X", "consent": True, "policy": "X"},
    ).raise_for_status()
    assert submit(client, "restore", raw, plan["fingerprint"]).status_code == 409
    assert client.get("/api/roles").json() == []
    assert client.get(route).json()["candidate"] == "Other"
    assert submit(client, "preview", raw).json()["sessions"]["conflict"] == 1


def test_identity_and_evidence_are_verified(workspace):
    client, raw, _ = workspace
    doc = json.loads(raw)
    doc["sessions"][0]["answers"][0]["result"]["passages"][0]["source_excerpt"] = "Different words"
    assert submit(client, "preview", json.dumps(doc).encode()).status_code == 422
    duplicate_field = b'{"version":3,' + raw[1:]
    assert submit(client, "preview", duplicate_field).json()["detail"] == "Duplicate JSON field."
    assert submit(client, "restore", raw, "a" * 64).status_code == 409
    assert client.get("/api/sessions").json() == []


def test_restore_accepts_maximum_length_note_retained_on_answer_edit(workspace, tmp_path, monkeypatch):
    client, raw, route = workspace
    token = submit(client, "preview", raw).json()["fingerprint"]
    submit(client, "restore", raw, token).raise_for_status()
    client.post(route + "/reopen").raise_for_status()
    answer = client.get(route).json()["answers"][0]
    path = route + "/answers/" + answer["id"]
    note = "n" * REVIEW_NOTE_LIMIT
    amended = client.patch(path, json={"disposition": "explained", "note": note})
    amended.raise_for_status()
    client.put(path, json={"question": answer["question"], "answer": "A revised answer.",
                           "expected_revision": amended.json()["revision"]}).raise_for_status()
    backup = client.get("/api/backups/workspace")
    backup.raise_for_status()
    target = tmp_path / "recovered-note.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
    preview = submit(client, "preview", backup.content)
    preview.raise_for_status()
    submit(client, "restore", backup.content, preview.json()["fingerprint"]).raise_for_status()
    assert client.get(path).json()["note"] == EARLIER_ANSWER_NOTE + note


def test_collision_with_an_answer_in_another_session_blocks_entire_restore(workspace):
    client, raw, _ = workspace
    other = client.post(
        "/api/sessions", json={"candidate": "Other", "role": "X", "policy": "Y", "consent": True}
    ).json()
    aid = json.loads(raw)["sessions"][0]["answers"][0]["id"]
    client.post(
        f"/api/sessions/{other['id']}/answers", json={"id": aid, "question": "X?", "answer": "Other text"}
    ).raise_for_status()
    plan = submit(client, "preview", raw).json()
    assert plan["sessions"]["conflict"] == 1
    assert submit(client, "restore", raw, plan["fingerprint"]).status_code == 409
    assert client.get("/api/roles").json() == []


def test_trashed_lineage_restores_with_new_operation_version_and_saved_draft(
    workspace, tmp_path, monkeypatch
):
    client, raw, route = workspace
    token = submit(client, "preview", raw).json()["fingerprint"]
    submit(client, "restore", raw, token).raise_for_status()
    client.post(route + "/reopen").raise_for_status()
    parent = client.post(
        route + "/answers", json={"question": "Same question?", "answer": "First answer", "planned_slot": 2}
    ).json()
    child = client.post(
        route + "/answers",
        json={"question": "Why?", "answer": "Second answer", "parent_answer_id": parent["id"]},
    ).json()
    draft = {"id": str(uuid4()), "question": "Next?", "parent_answer_id": child["id"], "expected_revision": 0}
    client.put(route + "/draft", json=draft).raise_for_status()
    old_version = client.post(route + "/trash").json()["operation_version"]
    backup = client.get("/api/backups/workspace").json()
    (archived,) = backup["sessions"]
    assert archived["trashed_at"] and old_version not in json.dumps(backup)
    archived["answers"].reverse()  # Restore can encounter a child before its parent.
    raw = json.dumps(backup).encode()
    target = tmp_path / "trash_restore.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
    plan = submit(client, "preview", raw).json()
    assert plan["trashed"] == 1 and plan["drafts"] == 1
    submit(client, "restore", raw, plan["fingerprint"]).raise_for_status()
    assert client.get(route).status_code == 404
    (item,) = client.get("/api/trash").json()["items"]
    assert item["operation_version"] != old_version
    client.post(
        "/api/trash/" + item["id"] + "/restore", json={"operation_version": item["operation_version"]}
    ).raise_for_status()
    session = client.get(route).json()
    restored = {a["id"]: a for a in session["answers"]}
    assert restored[child["id"]]["parent_answer_id"] == parent["id"]
    assert restored[parent["id"]]["planned_slot"] == 2
    assert client.get(route + "/draft").json()["parent_answer_id"] == child["id"]


def test_invalid_parent_graph_and_invalid_role_rejected_before_restore(workspace):
    client, raw, _ = workspace
    doc = json.loads(raw)
    row = doc["sessions"][0]["answers"][0]
    row["parent_answer_id"] = row["id"]
    assert submit(client, "preview", json.dumps(doc).encode()).status_code == 422
    del row["parent_answer_id"]
    doc["roles"][0]["questions"] = [""] * 101
    assert submit(client, "preview", json.dumps(doc).encode()).status_code == 422
    assert client.get("/api/sessions").json() == []


def test_full_length_review_note_survives_answer_edit_and_recovery(workspace, tmp_path, monkeypatch):
    client, raw, route = workspace
    token = submit(client, "preview", raw).json()["fingerprint"]
    submit(client, "restore", raw, token).raise_for_status()
    client.post(route + "/reopen").raise_for_status()
    answer = client.get(route).json()["answers"][0]
    path = route + "/answers/" + answer["id"]
    note = "a" * 12000
    client.patch(path, json={"note": note, "disposition": "explained"}).raise_for_status()
    revised = client.put(path, json={"question": "What changed?", "answer": "The procedure changed."}).json()
    assert revised["note"].endswith(note) and len(revised["note"]) > 12000
    raw = client.get("/api/backups/workspace").content
    target = tmp_path / "restored-note.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
    preview = submit(client, "preview", raw)
    preview.raise_for_status()
    submit(client, "restore", raw, preview.json()["fingerprint"]).raise_for_status()
    assert client.get(path).json()["note"] == revised["note"]
    client.patch(path, json={"note": revised["note"], "disposition": "unresolved"}).raise_for_status()
    # A later review can retain the prefixed note under a different disposition.
    rereviewed = client.get("/api/backups/workspace").content
    assert submit(client, "preview", rereviewed).json()["sessions"]["identical"] == 1
    for invalid in (note + "x", revised["note"] + "x"):
        assert client.patch(path, json={"note": invalid, "disposition": "pending"}).status_code == 422
