"""Preserve confirmed retention separately from protective holds on uncertain older files."""
from copy import deepcopy
import json
from unittest.mock import AsyncMock

from fastapi import HTTPException
import pytest

from api import ats_notes, model_execution, saved_judge, session_privacy, store
from api.retention_anonymizer import REDACTED_TEXT, SessionAnonymizer, anonymized_candidate_label
from backup_requests import client, preview, restore

STAMP = "2026-04-01T12:34:56+00:00"
ADMIN = "private-retention-actor@example.test"
SECRET = "Unique answer erased under retention"
RISK = "/api/calibration/disagreements"


def session(client):
    template = client.post("/api/roles", json={"name": "Test role", "policy": "Manual"}).raise_for_status().json()
    sid = client.post("/api/sessions", json={"candidate": "Synthetic candidate", "role": template["name"],
                                             "role_id": template["id"], "consent": True}).raise_for_status().json()["id"]
    aid = client.post(f"/api/sessions/{sid}/answers", json={"question": "Describe the checks.", "answer": SECRET}).raise_for_status().json()["id"]
    with store.connection(write=True) as db:
        for index, disposition in enumerate(("explained", "unresolved")):
            db.execute("""INSERT INTO answer_review_events(session_id,answer_id,role_id,reviewer_id,reviewer_email,
                                previous_disposition,disposition,created_at) VALUES(?,?,?,?,?,'pending',?,?)""",
                       (sid, aid, template["id"], f"r{index}", f"reviewer{index}@example.test", disposition, STAMP))
    return sid, aid, template["id"]


def apply_policy(sid):
    with store.connection(write=True) as db:
        SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=True, actor_email=ADMIN, now_iso=STAMP)


def switch_database(tmp_path, monkeypatch):
    path = tmp_path / "restored.sqlite"
    store.initialize(path)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(path))


def legacy(doc):
    doc = deepcopy(doc)
    doc["version"] = 5
    for record in doc["sessions"]:
        del record["privacy"]
        del record["rubric_snapshot"]
    return doc


def check_restricted(client, sid, aid, rid, state, monkeypatch):
    transfer = AsyncMock()
    review = AsyncMock()
    monkeypatch.setattr(ats_notes, "find_recipients", transfer)
    monkeypatch.setattr(model_execution, "execute_completion_chain", review)
    assert client.get(RISK).raise_for_status().json()["items"] == []
    assert client.get("/api/calibration/export?format=json").json()["reviewer_metrics"] == []
    assert client.get(f"/api/roles/{rid}/calibration").json()["disagreements"] == []
    assert client.get(f"/api/sessions/{sid}/ats").json() == {"history": [], "providers": [], "privacy": state}
    resp = client.post(f"/api/sessions/{sid}/ats/recipients", json={"provider": "ashby", "email": "test@example.test"})
    assert resp.status_code == 409
    transfer.assert_not_awaited()
    item = client.get(f"/api/sessions/{sid}/answers/{aid}").json()
    request = {"session_id": sid, "answer_id": aid, "expected_revision": item["revision"],
               "evidence_sha256": saved_judge.evidence_digest(item["question"], item["result"]["passages"])}
    assert client.post("/api/scoring/judge/saved", json=request).status_code == 409
    review.assert_not_awaited()


@pytest.mark.parametrize("trashed", [False, True])
def test_confirmed_restore_preserves_protection_without_retention_actor(client, tmp_path, monkeypatch, trashed):
    sid, aid, rid = session(client)
    assert client.get(RISK).json()["items"][0]["answer_id"] == aid
    apply_policy(sid)
    if trashed:
        client.post(f"/api/sessions/{sid}/trash").raise_for_status()
    archive = client.get("/api/backups/workspace", params={"session_id": sid}).raise_for_status()
    assert ADMIN not in archive.text and SECRET not in archive.text
    assert archive.json()["sessions"][0]["privacy"] == {"state": "anonymized", "anonymized_at": STAMP}
    assert archive.json() == client.get("/api/backups/workspace").json()
    switch_database(tmp_path, monkeypatch)
    restore(client, archive.content, preview(client, archive.content)).raise_for_status()
    assert preview(client, archive.content)["sessions"]["identical"] == 1
    with store.connection() as db:
        assert tuple(db.execute("SELECT anonymized_at,anonymized_by FROM session_anonymizations WHERE session_id=?", (sid,)).fetchone()) == (STAMP, "")
    if trashed:
        marker, = client.get("/api/trash").json()["items"]
        client.post(f"/api/trash/{sid}/restore", json={"operation_version": marker["operation_version"]}).raise_for_status()
    check_restricted(client, sid, aid, rid, "anonymized", monkeypatch)
    exported = client.get("/api/backups/workspace").json()["sessions"][0]
    assert exported["privacy"] == {"state": "anonymized", "anonymized_at": STAMP}
    assert exported["answers"][0]["answer"] == REDACTED_TEXT


def test_legacy_redaction_survives_reexport_without_claiming_a_confirmed_receipt(client, tmp_path, monkeypatch):
    sid, aid, rid = session(client)
    apply_policy(sid)
    doc = client.get("/api/backups/workspace").json()
    old = json.dumps(legacy(doc)).encode()
    assert preview(client, old)["sessions"]["identical"] == 1
    restore(client, old, preview(client, old)).raise_for_status()
    assert client.get("/api/backups/workspace").json()["sessions"][0]["privacy"]["state"] == "anonymized"
    switch_database(tmp_path, monkeypatch)
    restore(client, old, preview(client, old)).raise_for_status()
    check_restricted(client, sid, aid, rid, "legacy_unverified", monkeypatch)
    updated = client.get("/api/backups/workspace").raise_for_status()
    assert updated.json()["sessions"][0]["privacy"] == {"state": "legacy_unverified", "anonymized_at": None}
    assert preview(client, updated.content)["sessions"]["identical"] == 1
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM session_anonymizations").fetchone()[0] == 0


def test_protection_conflict_and_reintroduced_private_text_are_rejected(client):
    sid, _, _ = session(client)
    apply_policy(sid)
    doc = client.get("/api/backups/workspace").json()
    ordinary = deepcopy(doc)
    ordinary["sessions"][0]["privacy"] = {"state": "unmarked", "anonymized_at": None}
    raw = json.dumps(ordinary).encode()
    plan = preview(client, raw)
    assert plan["sessions"]["conflict"] == 1 and restore(client, raw, plan).status_code == 409
    assert client.get("/api/backups/workspace").json()["sessions"][0]["privacy"]["state"] == "anonymized"
    doc["sessions"][0]["answers"][0]["answer"] = SECRET
    invalid = client.post("/api/backups/preview", json=doc)
    assert invalid.status_code == 422 and SECRET not in invalid.text
    with store.connection(write=True) as db:
        db.execute("UPDATE answers SET answer=? WHERE session_id=?", (SECRET, sid))
    refused = client.get("/api/backups/workspace")
    assert refused.status_code == 409 and SECRET not in refused.text


def test_legacy_name_with_a_normal_answer_is_not_a_retention_receipt_or_a_hold(client, tmp_path, monkeypatch):
    sid, _, _ = session(client)
    doc = legacy(client.get("/api/backups/workspace").json())
    doc["sessions"][0]["candidate"] = anonymized_candidate_label(sid)
    switch_database(tmp_path, monkeypatch)
    raw = json.dumps(doc).encode()
    restore(client, raw, preview(client, raw)).raise_for_status()
    assert client.get(RISK).json()["summary"]["total_disagreed_answers"] == 1
    with store.connection() as db:
        assert session_privacy.read(db, sid).state == "unmarked"


def test_retention_interrupts_an_ats_operation_before_external_send(client, monkeypatch):
    sid, _, _ = session(client)
    async def redact_during_lookup(_query):
        apply_policy(sid)
        return [{"target_id": "unconfirmed-recipient", "candidate": "Private recipient"}]

    monkeypatch.setattr(ats_notes, "find_recipients", redact_during_lookup)
    version = ats_notes._open_operation(sid)
    response = client.post(f"/api/sessions/{sid}/ats/drafts", json={
        "provider": "ashby", "email": "test@example.test", "target_id": "unconfirmed-recipient",
    })
    assert response.status_code == 409 and "Private recipient" not in response.text
    with pytest.raises(HTTPException) as exc:
        ats_notes._confirm_operation(sid, version)
    assert exc.value.status_code == 409
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM note_exports WHERE session_id=?", (sid,)).fetchone()[0] == 0


def test_upgrade_protects_records_restored_before_receipts_were_portable(client):
    sid, _, _ = session(client)
    apply_policy(sid)
    old = store.db_path()
    with store.connection(write=True) as db:
        db.execute("DELETE FROM session_anonymizations WHERE session_id=?", (sid,))
        db.execute("DROP TABLE legacy_privacy_holds")
    store.initialize(old)
    store.initialize(old)
    with store.connection() as db:
        assert session_privacy.read(db, sid).state == "legacy_unverified"
        assert db.execute("SELECT count(*) FROM session_anonymizations").fetchone()[0] == 0
    assert client.get("/api/backups/workspace").json()["sessions"][0]["privacy"]["state"] == "legacy_unverified"
