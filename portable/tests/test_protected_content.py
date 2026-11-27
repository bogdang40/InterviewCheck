"""A retention receipt seals private interview content without inventing capture notice."""
from copy import deepcopy
import json
import sqlite3
from uuid import uuid4

import pytest

from api import migrate, store
from api.retention_anonymizer import REDACTED_TEXT, SessionAnonymizer
from backup_requests import client, preview, restore
from test_migrate import build_native

STAMP = "2026-05-20T12:00:00+00:00"
NEW_TEXT = "Synthetic private details entered after the interview was sealed"


def anonymize(sid):
    with store.connection(write=True) as db:
        SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=False, actor_email="operator@example.test", now_iso=STAMP)


def fresh_destination(path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(path))
    store.initialize(path)


def test_content_guard_precedes_answer_history_and_other_writes(client):
    sid = client.post("/api/sessions", json={"candidate": "Fixture", "role": "Engineer", "policy": "Manual",
                                            "consent": True}).raise_for_status().json()["id"]
    path = f"/api/sessions/{sid}"
    answer = client.post(path + "/answers", json={"question": "Explain the choice.", "answer": "A private explanation."})
    aid = answer.raise_for_status().json()["id"]
    other = client.post("/api/sessions", json={"candidate": "Other", "role": "Engineer", "policy": "Manual",
                                               "consent": True}).raise_for_status().json()["id"]
    anonymize(sid)
    before = client.get("/api/backups/workspace").raise_for_status().json()
    session = client.get(path).raise_for_status().json()
    assert session["privacy_state"] == "anonymized"
    revision = session["answers"][0]["revision"]
    body = {"question": "Private question?", "answer": NEW_TEXT}
    did = str(uuid4())
    batch = {"request_id": str(uuid4()), "transcript_sha256": "0" * 64, "candidate_speaker": "candidate",
             "interviewer_speakers": ["interviewer"], "exchanges": [{**body, "ordinal": 1, "start_ms": 0, "end_ms": 100}]}
    for method, route, payload in (
        ("PATCH", path + f"/answers/{aid}", {"disposition": "explained", "note": NEW_TEXT, "expected_revision": revision}),
        ("PUT", path + f"/answers/{aid}", {**body, "expected_revision": revision}),
        ("POST", path + "/answers", body),
        ("PUT", path + "/draft", {**body, "id": did, "expected_revision": 0}),
        ("POST", path + "/draft/publish", {**body, "id": did, "expected_revision": 1}),
        ("POST", path + "/imports/webvtt", batch),
        ("POST", path + "/reopen", {}),
        ("PUT", path + "/scorecard", {"items": [{"criterion_id": "x", "criterion_label": "Test", "rating": 2,
                                                 "weight": 1, "rationale": NEW_TEXT}]}),
        ("POST", path + "/handoff-notes", {"category": "observation", "body": NEW_TEXT}),
        ("PUT", path + "/assignment", {"assignee_email": "private@example.test"}),
        ("POST", "/api/interviews/assignments/bulk", {"action": "assign", "session_ids": [other, sid],
                                                       "assignee_email": "private@example.test"}),
        ("POST", "/api/interviews/bulk/tag", {"session_ids": [other, sid], "add": ["private"]}),
    ):
        response = client.request(method, route, json=payload)
        assert response.status_code == 409, (method, route, response.text)
        assert response.headers.get("X-InterviewCheck-Conflict") == "interview-privacy"
    with store.connection() as db:
        assert db.execute("SELECT COUNT(*) FROM answer_history WHERE answer_id=?", (aid,)).fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM answer_review_events WHERE session_id=?", (sid,)).fetchone()[0] == 0
    assert client.get("/api/backups/workspace").raise_for_status().json() == before
    # The unaffected interview remains writable.
    client.post(f"/api/sessions/{other}/answers", json=body).raise_for_status()


@pytest.mark.parametrize("trashed", [False, True], ids=["active", "trash"])
def test_native_false_notice_survives_anonymization_and_round_trip(client, tmp_path, monkeypatch, trashed):
    source = tmp_path / "native.sqlite"
    build_native(source)
    # Native capture could store a question longer than the current web form accepts.
    with sqlite3.connect(source) as db:
        db.execute("UPDATE interview_questions SET text=?", ("Native question " * 320,))
    assert migrate.migrate(source, store.db_path())["sessions"] == 1
    sid = migrate.portable_id("session", "i")
    original = client.get("/api/sessions/" + sid).raise_for_status().json()
    assert not original["consent"] and original["legacy"]
    anonymize(sid)
    if trashed:
        client.post(f"/api/sessions/{sid}/trash").raise_for_status()
    raw = client.get("/api/backups/workspace").raise_for_status().content
    extracted = json.loads(raw)["sessions"][0]
    assert extracted["consent"] is False and "legacy" not in extracted
    assert extracted["privacy"] == {"state": "anonymized", "anonymized_at": STAMP}
    assert bool(extracted.get("trashed_at")) == trashed
    assert extracted["answers"][0]["answer"] == REDACTED_TEXT
    fresh_destination(tmp_path / "recovered.sqlite", monkeypatch)
    restore(client, raw, preview(client, raw)).raise_for_status()
    assert client.get("/api/backups/workspace").raise_for_status().json()["sessions"][0] == extracted
    if trashed:
        with store.connection() as db:
            version = db.execute("SELECT operation_version FROM session_trash WHERE session_id=?", (sid,)).fetchone()[0]
        client.post(f"/api/trash/{sid}/restore", json={"operation_version": version}).raise_for_status()
    restored = client.get("/api/sessions/" + sid).raise_for_status().json()
    assert restored["privacy_state"] == "anonymized" and restored["consent"] is False
    assert client.post(f"/api/sessions/{sid}/reopen").status_code == 409
    assert client.post(f"/api/sessions/{sid}/answers", json={"question": "Later?", "answer": NEW_TEXT}).status_code == 409
    assert migrate.migrate(source, store.db_path())["sessions"] == 0
    assert NEW_TEXT not in client.get("/api/backups/workspace").text

    # A genuine missing notice still cannot create an ordinary current record.
    invalid = deepcopy(json.loads(raw))
    invalid["sessions"][0]["privacy"] = {"state": "unmarked", "anonymized_at": None}
    assert client.post("/api/backups/preview", json=invalid).status_code == 422
    assert client.post("/api/sessions", json={"candidate": "Fixture", "role": "Test", "policy": "Manual",
                                              "consent": False}).status_code == 422


def test_prior_native_erasure_restores_as_a_hold_without_a_receipt(client, tmp_path, monkeypatch):
    source = tmp_path / "native.sqlite"
    build_native(source)
    migrate.migrate(source, store.db_path())
    sid = migrate.portable_id("session", "i")
    anonymize(sid)
    legacy = client.get("/api/backups/workspace").raise_for_status().json()
    legacy["version"] = 5
    entry = legacy["sessions"][0]
    del entry["privacy"], entry["rubric_snapshot"], entry["deferred_questions"]
    raw = json.dumps(legacy).encode()
    fresh_destination(tmp_path / "legacy.sqlite", monkeypatch)
    restore(client, raw, preview(client, raw)).raise_for_status()
    doc = client.get("/api/backups/workspace").raise_for_status().json()["sessions"][0]
    assert doc["privacy"] == {"state": "legacy_unverified", "anonymized_at": None} and doc["consent"] is False
    path = f"/api/sessions/{sid}"
    aid = doc["answers"][0]["id"]
    rejects = client.patch(path + f"/answers/{aid}", json={"disposition": "pending", "note": NEW_TEXT})
    assert rejects.status_code == 409 and rejects.headers["X-InterviewCheck-Conflict"] == "interview-privacy"
    with store.connection() as db:
        assert not db.execute("SELECT 1 FROM session_anonymizations WHERE session_id=?", (sid,)).fetchone()
    assert client.get("/api/backups/workspace").raise_for_status().json()["sessions"][0] == doc
