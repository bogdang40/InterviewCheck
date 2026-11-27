import json
from copy import deepcopy
from unittest.mock import AsyncMock
from uuid import uuid4

import pytest

from api import access, store
from backup_requests import client, create_session, preview, restore


def assign(client, sid):
    response = client.put(f"/api/sessions/{sid}/assignment", json={
        "assignee_email": "Reviewer@Example.test", "priority": "high", "due_at": "2025-02-01T09:15:00-05:00",
    })
    response.raise_for_status()
    return response.json()["assignment"]


def test_individual_and_workspace_assignment_recovery(client, tmp_path, monkeypatch):
    actor = "urn:partner:Partner Reviewer 07/" + "a" * 310
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://access.example.test")
    monkeypatch.setattr(access, "upstream", AsyncMock(return_value={"user": {"id": actor}, "entitlement": {"active": True}}))
    client.cookies.set(access.COOKIE, "synthetic-test-session")
    active, archived, unassigned = (create_session(client) for _ in range(3))
    expected = {sid: assign(client, sid) for sid in (active, archived)}
    client.post(f"/api/sessions/{archived}/trash").raise_for_status()
    single = client.get("/api/backups/workspace", params={"session_id": archived}).content
    raw = client.get("/api/backups/workspace").content
    document = json.loads(raw)
    assert document["version"] == json.loads(single)["version"] == 6
    archived_export, = json.loads(single)["sessions"]
    assert archived_export["id"] == archived and archived_export["trashed_at"]
    for record in document["sessions"]:
        sid = record["id"]
        if sid == unassigned:
            assert record["assignment"] is None
        else:
            assert record["assignment"] == {k: v for k, v in expected[sid].items() if k != "session_id"}
            assert record["assignment"]["assigned_by"] == actor
    target = tmp_path / "destination.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
    first = preview(client, single)
    assert first["assignments"] == first["trashed"] == 1
    restore(client, single, first).raise_for_status()
    plan = preview(client, raw)
    assert plan["assignments"] == plan["sessions"]["new"] == 2
    assert plan["sessions"]["identical"] == 1
    assert restore(client, raw, plan).json()["assignments"] == 2
    assert preview(client, raw)["sessions"] == {"new": 0, "identical": 3, "conflict": 0}
    queue = client.get("/api/interviews/assignments", params={"priority": "high", "due": "overdue"}).json()
    assert [item["session_id"] for item in queue["items"]] == [active]
    item, = client.get("/api/trash").json()["items"]
    client.post(f"/api/trash/{archived}/restore", json={"operation_version": item["operation_version"]}).raise_for_status()
    for sid in (active, archived):
        assert client.get(f"/api/sessions/{sid}/assignment").json()["assignment"] == expected[sid]


@pytest.mark.parametrize("version", [1, 2])
def test_legacy_unknown_assignment_preserves_existing_owner(client, version):
    sid = create_session(client)
    assignment = assign(client, sid)
    doc = client.get("/api/backups/workspace").json()
    doc["version"] = version
    del doc["sessions"][0]["privacy"]
    del doc["sessions"][0]["rubric_snapshot"]
    del doc["sessions"][0]["scorecard_items"]
    del doc["sessions"][0]["handoff_notes"]
    del doc["sessions"][0]["assignment"]
    new = {**doc["sessions"][0], "id": str(uuid4())}
    doc["sessions"].append(new)
    raw = json.dumps(doc).encode()
    plan = preview(client, raw)
    assert plan["assignments"] == 0
    assert plan["sessions"] == {"new": 1, "identical": 1, "conflict": 0}
    restore(client, raw, plan).raise_for_status()
    assert client.get(f"/api/sessions/{sid}/assignment").json()["assignment"] == assignment
    assert client.get(f"/api/sessions/{new['id']}/assignment").json()["assignment"] is None
    doc["sessions"][0]["candidate"] = "Conflicting candidate"
    assert preview(client, json.dumps(doc).encode())["sessions"]["conflict"] == 1
    for field in (None, {k: v for k, v in assignment.items() if k != "session_id"}):
        doc["sessions"][0]["assignment"] = field
        assert client.post("/api/backups/preview", json=doc).status_code == 422


@pytest.mark.parametrize("assigned_initially", [False, True])
def test_changed_assignment_after_preview_blocks_other_records(client, assigned_initially):
    sid = create_session(client)
    if assigned_initially:
        assign(client, sid)
    doc = client.get("/api/backups/workspace").json()
    other = {**doc["sessions"][0], "id": str(uuid4())}
    doc["sessions"].append(other)
    raw = json.dumps(doc).encode()
    plan = preview(client, raw)
    assert plan["sessions"] == {"new": 1, "identical": 1, "conflict": 0}
    if assigned_initially:
        client.delete(f"/api/sessions/{sid}/assignment").raise_for_status()
    else:
        assign(client, sid)
    assert restore(client, raw, plan).status_code == 409
    assert client.get(f"/api/sessions/{other['id']}").status_code == 404
    assert preview(client, raw)["sessions"]["conflict"] == 1


def test_assignment_metadata_must_match_and_be_well_formed(client):
    sid = create_session(client)
    assign(client, sid)
    doc = client.get("/api/backups/workspace").json()
    for field, value in (("assignee_email", "another@example.test"), ("assigned_by", "admin@example.test"),
                         ("priority", "low"), ("due_at", None), ("updated_at", "2025-03-04T05:06:07Z")):
        altered = deepcopy(doc)
        altered["sessions"][0]["assignment"][field] = value
        assert preview(client, json.dumps(altered).encode())["sessions"]["conflict"] == 1
    for field, value in (
        ("assignee_email", "invalid"), ("assigned_by", " "), ("assigned_by", "A\nB"), ("priority", "urgent"),
        ("due_at", "2025-01-01T00:00:00"), ("updated_at", "2025-01-01\n00:00:00Z"),
        ("updated_at", "2025-01-01T00:00:00." + "0" * 70 + "Z"), ("session_id", sid),
        ("due_at", "9999-12-31T23:59:59-01:00"),
    ):
        altered = deepcopy(doc)
        altered["sessions"][0]["assignment"][field] = value
        assert client.post("/api/backups/preview", json=altered).status_code == 422
    del doc["sessions"][0]["assignment"]
    assert client.post("/api/backups/preview", json=doc).status_code == 422


def test_missing_assignment_storage_fails_before_restore(client, tmp_path, monkeypatch):
    sid = create_session(client)
    assign(client, sid)
    raw = client.get("/api/backups/workspace").content
    target = tmp_path / "destination.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
    plan = preview(client, raw)
    with store.connection(write=True) as db:
        db.execute("DROP TABLE session_assignments")
    assert restore(client, raw, plan).status_code == 409
    assert client.get("/api/sessions").json() == []
    new_id = create_session(client)
    doc = client.get("/api/backups/workspace", params={"session_id": new_id}).json()
    assert doc["version"] == 6 and doc["sessions"][0]["assignment"] is None


def test_invalid_stored_actor_blocks_export_and_conflicts_with_assignment_aware_backup(client):
    sid = create_session(client)
    assign(client, sid)
    doc = client.get("/api/backups/workspace").json()
    second = {**doc["sessions"][0], "id": str(uuid4())}
    doc["sessions"].append(second)
    raw = json.dumps(doc).encode()
    plan = preview(client, raw)
    invalid_actor = "private upstream identity\x85suffix"
    with store.connection(write=True) as db:
        db.execute("UPDATE session_assignments SET assigned_by=? WHERE session_id=?", (invalid_actor, sid))
    for params in ({}, {"session_id": sid}):
        blocked = client.get("/api/backups/workspace", params=params)
        assert blocked.status_code == 409
        message = blocked.json()["detail"]
        assert sid in message and "SQLite" in message and "private upstream identity" not in message
    conflicted = preview(client, raw)
    assert conflicted["sessions"] == {"new": 1, "identical": 0, "conflict": 1}
    assert restore(client, raw, plan).status_code == 409
    assert client.get(f"/api/sessions/{second['id']}").status_code == 404
    doc["version"] = 2
    for record in doc["sessions"]:
        del record["privacy"]
        del record["rubric_snapshot"]
        del record["scorecard_items"]
        del record["handoff_notes"]
        del record["assignment"]
    legacy = json.dumps(doc).encode()
    plan = preview(client, legacy)
    assert plan["sessions"] == {"new": 1, "identical": 1, "conflict": 0}
    restore(client, legacy, plan).raise_for_status()
    assert client.get(f"/api/sessions/{sid}/assignment").json()["assignment"]["assigned_by"] == invalid_actor
