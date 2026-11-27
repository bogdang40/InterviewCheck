import json
from copy import deepcopy
from uuid import uuid4

import pytest

from api import access, store
from backup_requests import client, create_session, preview, restore


def add_note(client, sid, category="follow_up", body="Ask about the tests."):
    response = client.post(f"/api/sessions/{sid}/handoff-notes", json={"category": category, "body": body})
    response.raise_for_status()
    return response.json()


def notes(client, sid):
    response = client.get(f"/api/sessions/{sid}/scorecard")
    response.raise_for_status()
    return response.json()["handoff_notes"]


def fresh_workspace(tmp_path, monkeypatch):
    target = tmp_path / "destination.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))


def test_handoff_roundtrip_with_trash_retention_and_stable_ids(client, tmp_path, monkeypatch):
    actor_id = "Partner Reviewer 07/" + "x" * 410

    async def actor(request):
        return (actor_id, actor_id)

    monkeypatch.setattr(access, "optional_actor", actor)
    monkeypatch.setattr(store, "timestamp", lambda: "2026-08-01T13:39:02.123456+00:00")
    active, archived, empty = (create_session(client) for _ in range(3))
    for category in ("observation", "follow_up", "decision", "concern"):
        add_note(client, active, category, f"Résumé\n\tReview {category}")
    redacted = add_note(client, archived)
    with store.connection(write=True) as db:
        # Preserve the row shape produced by the retention workflow.
        db.execute("UPDATE session_handoff_notes SET body='' WHERE id=?", (redacted["id"],))
    expected = {sid: notes(client, sid) for sid in (active, archived, empty)}
    client.post(f"/api/sessions/{archived}/trash").raise_for_status()
    single = client.get("/api/backups/workspace", params={"session_id": archived}).content
    doc = client.get("/api/backups/workspace").json()
    assert doc["version"] == json.loads(single)["version"] == 7
    for session in doc["sessions"]:
        sid = session["id"]
        assert session["handoff_notes"] == [{k: v for k, v in row.items() if k != "session_id"} for row in expected[sid]]
        assert "session_scorecards" not in session
    assert expected[active][0]["author_email"] == actor_id

    fresh_workspace(tmp_path, monkeypatch)
    restore(client, single, preview(client, single)).raise_for_status()
    for session in doc["sessions"]:
        session["handoff_notes"].reverse()  # File order cannot change note identity.
    raw = json.dumps(doc).encode()
    plan = preview(client, raw)
    assert plan["handoff_notes"] == 5 and plan["sessions"]["identical"] == 1
    assert "Résumé" not in str(plan)
    assert restore(client, raw, plan).json()["handoff_notes"] == 5
    assert preview(client, raw)["sessions"] == {"new": 0, "identical": 3, "conflict": 0}
    marker, = client.get("/api/trash").json()["items"]
    client.post(f"/api/trash/{archived}/restore", json={"operation_version": marker["operation_version"]}).raise_for_status()
    assert {sid: notes(client, sid) for sid in expected} == expected
    saved = expected[active][0]
    client.delete(f"/api/sessions/{active}/handoff-notes/{saved['id']}").raise_for_status()
    assert notes(client, active) == expected[active][1:]


@pytest.mark.parametrize("version", [1, 2, 3])
def test_legacy_backups_preserve_local_notes(client, version):
    sid = create_session(client)
    doc = client.get("/api/backups/workspace").json()
    doc["version"] = version
    del doc["sessions"][0]["deferred_questions"]
    del doc["sessions"][0]["privacy"]
    del doc["sessions"][0]["rubric_snapshot"]
    record = doc["sessions"][0]
    del record["scorecard_items"]
    if version < 3:
        del record["assignment"]
    assert client.post("/api/backups/preview", json=doc).status_code == 422
    del record["handoff_notes"]
    new_id = str(uuid4())
    doc["sessions"].append({**record, "id": new_id})
    new_note = add_note(client, sid)
    raw = json.dumps(doc).encode()
    plan = preview(client, raw)
    assert plan["handoff_notes"] == 0 and plan["sessions"] == {"new": 1, "identical": 1, "conflict": 0}
    restore(client, raw, plan).raise_for_status()
    assert notes(client, sid) == [new_note] and notes(client, new_id) == []
    client.put(f"/api/sessions/{sid}/assignment", json={"assignee_email": "reviewer@example.test"}).raise_for_status()
    assert preview(client, raw)["sessions"]["conflict"] == (1 if version == 3 else 0)


def test_handoff_collision_after_preview_blocks_entire_restore(client, tmp_path, monkeypatch):
    owner = create_session(client)
    add_note(client, owner)
    other = create_session(client)
    raw = client.get("/api/backups/workspace").content
    fresh_workspace(tmp_path, monkeypatch)
    plan = preview(client, raw)
    assert plan["sessions"]["new"] == 2
    moved = json.loads(raw)
    destination = next(s for s in moved["sessions"] if s["id"] == owner)
    destination["id"] = str(uuid4())
    moved["sessions"] = [destination]
    moved_raw = json.dumps(moved).encode()
    restore(client, moved_raw, preview(client, moved_raw)).raise_for_status()
    client.post(f"/api/sessions/{destination['id']}/trash").raise_for_status()
    assert preview(client, raw)["sessions"] == {"new": 1, "identical": 0, "conflict": 1}
    assert restore(client, raw, plan).status_code == 409
    for sid in (owner, other):
        assert client.get(f"/api/sessions/{sid}").status_code == 404


@pytest.mark.parametrize("starts_with_note", [False, True])
def test_updated_note_set_after_preview_blocks_unrelated_interview(client, starts_with_note):
    sid = create_session(client)
    saved = add_note(client, sid) if starts_with_note else None
    doc = client.get("/api/backups/workspace").json()
    other = {**doc["sessions"][0], "id": str(uuid4()), "handoff_notes": []}
    doc["sessions"].append(other)
    raw = json.dumps(doc).encode()
    plan = preview(client, raw)
    assert plan["sessions"] == {"new": 1, "identical": 1, "conflict": 0}
    if saved:
        client.delete(f"/api/sessions/{sid}/handoff-notes/{saved['id']}").raise_for_status()
    else:
        add_note(client, sid)
    assert restore(client, raw, plan).status_code == 409
    assert preview(client, raw)["sessions"]["conflict"] == 1
    assert client.get(f"/api/sessions/{other['id']}").status_code == 404


def test_note_fields_and_global_ids_validate_without_disclosing_text(client):
    sid = create_session(client)
    add_note(client, sid)
    doc = client.get("/api/backups/workspace").json()
    for field, value in (("category", "other"), ("author_email", "  "), ("id", "bad"), ("created_at", "2026-01-01"),
                         ("body", "private body\x07"), ("body", "z" * 2001), ("session_id", sid)):
        invalid = deepcopy(doc)
        invalid["sessions"][0]["handoff_notes"][0][field] = value
        reply = client.post("/api/backups/preview", json=invalid)
        assert reply.status_code == 422 and "private body" not in reply.text
    repeated = deepcopy(doc)
    repeated["sessions"][0]["handoff_notes"] *= 2
    assert client.post("/api/backups/preview", json=repeated).status_code == 422
    repeated = deepcopy(doc)
    repeated["sessions"].append({**doc["sessions"][0], "id": str(uuid4())})
    assert client.post("/api/backups/preview", json=repeated).status_code == 422
    del doc["sessions"][0]["handoff_notes"]
    assert client.post("/api/backups/preview", json=doc).status_code == 422


def test_v4_detects_content_changes_and_handles_invalid_stored_notes(client):
    sid = create_session(client)
    saved = add_note(client, sid)
    doc = client.get("/api/backups/workspace").json()
    raw = json.dumps(doc).encode()
    for field, value in (("body", "Different"), ("author_email", "other"), ("created_at", "2026-10-10T08:00:00Z"),
                         ("category", "decision"), ("id", str(uuid4()))):
        altered = deepcopy(doc)
        altered["sessions"][0]["handoff_notes"][0][field] = value
        assert preview(client, json.dumps(altered).encode())["sessions"]["conflict"] == 1
    plan = preview(client, raw)
    with store.connection(write=True) as db:
        db.execute("UPDATE session_handoff_notes SET author_email=? WHERE id=?", ("private\x85identifier", saved["id"]))
    response = client.get("/api/backups/workspace")
    assert response.status_code == 409
    assert sid in response.text and "private" not in response.text and saved["body"] not in response.text
    assert preview(client, raw)["sessions"]["conflict"] == 1
    assert restore(client, raw, plan).status_code == 409
    doc["version"] = 3
    del doc["sessions"][0]["deferred_questions"]
    del doc["sessions"][0]["privacy"]
    del doc["sessions"][0]["rubric_snapshot"]
    del doc["sessions"][0]["scorecard_items"]
    del doc["sessions"][0]["handoff_notes"]
    assert preview(client, json.dumps(doc).encode())["sessions"]["identical"] == 1


def test_absent_notes_table_does_not_silently_discard_notes(client, tmp_path, monkeypatch):
    sid = create_session(client)
    add_note(client, sid)
    raw = client.get("/api/backups/workspace").content
    fresh_workspace(tmp_path, monkeypatch)
    plan = preview(client, raw)
    with store.connection(write=True) as db:
        db.execute("DROP TABLE session_handoff_notes")
    assert restore(client, raw, plan).status_code == 409
    assert client.get("/api/sessions").json() == []
    new = create_session(client)
    doc = client.get("/api/backups/workspace", params={"session_id": new}).json()
    assert doc["sessions"][0]["handoff_notes"] == []


@pytest.mark.parametrize("protection", ["anonymized", "legacy_unverified"])
def test_delete_cannot_remove_retained_handoff_or_its_attribution(client, monkeypatch, protection):
    from api.retention_anonymizer import SessionAnonymizer

    author = "original-panelist@example.test"

    async def actor(request):
        return "fixture-panelist", author

    monkeypatch.setattr(access, "optional_actor", actor)
    sid = create_session(client)
    saved = add_note(client, sid, "decision", "Synthetic private rationale.")
    path = f"/api/sessions/{sid}/handoff-notes"
    with store.connection(write=True) as db:
        SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=False,
                                       actor_email="retention-fixture@example.test", now_iso=store.timestamp())
        if protection == "legacy_unverified":
            db.execute("DELETE FROM session_anonymizations WHERE session_id=?", (sid,))
            db.execute("INSERT INTO legacy_privacy_holds(session_id) VALUES(?)", (sid,))
    # A stale authorized tab knows the original note ID and can still attempt the request.
    refused = client.delete(path + "/" + saved["id"])
    assert refused.status_code == 409
    assert refused.headers["X-InterviewCheck-Conflict"] == "interview-privacy"
    retained = {**saved, "body": ""}
    assert client.get(path).raise_for_status().json()["items"] == [retained]
    assert notes(client, sid) == [retained]
    assert retained["author_email"] == author
