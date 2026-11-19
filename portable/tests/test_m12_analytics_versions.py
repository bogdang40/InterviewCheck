"""Tests for M12-W1: multi-reviewer calibration, role analytics, and rubric versioning."""
from contextlib import closing
import sqlite3
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import account_db, store
from api.main import app


CRIT_A = {
    "id": "crit-accuracy",
    "criterion": "Technical accuracy",
    "weight": 60,
    "expected_signals": ["Mentions lock ordering"],
    "red_flags": ["Ignores deadlock"],
}
CRIT_B = {
    "id": "crit-clarity",
    "criterion": "Clarity of reasoning",
    "weight": 40,
    "expected_signals": ["States tradeoffs"],
    "red_flags": [],
}
ROLE_PAYLOAD = {
    "name": "Staff Systems Engineer",
    "description": "Concurrency and storage design",
    "questions": ["How do you avoid deadlocks?", "Explain WAL durability."],
    "policy": "No external assistance.",
    "permitted_sources": [{"label": "Prompt brief", "text": "Allowed prompt sheet."}],
    "rubric": [CRIT_A],
    "change_note": "Initial rubric",
}


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "m12.sqlite"))
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN", "INTERVIEWCHECK_OPERATOR_EMAIL"):
        monkeypatch.delenv(key, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


@pytest.fixture
def embedded_clients(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "m12.sqlite"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("TRIAL_DAYS", "7")
    for key in ("INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_SIGNUP_SECRET"):
        monkeypatch.delenv(key, raising=False)
    headers = {"X-InterviewCheck": "1"}
    with TestClient(app, base_url="http://127.0.0.1", headers=headers) as alice, TestClient(
        app, base_url="http://127.0.0.1", headers=headers
    ) as bob:
        alice.post("/api/integrations/access/signup", json={"email": "alice@example.invalid", "password": "alice-password-123"}).raise_for_status()
        bob.post("/api/integrations/access/signup", json={"email": "bob@example.invalid", "password": "bob-password-123"}).raise_for_status()
        yield alice, bob


def _add_answer(client, sid: str, *, question: str, answer: str, slot: int | None = None, match: bool = False) -> dict:
    refs = [{"label": "Ref", "text": answer}] if match else []
    payload = {"question": question, "answer": answer, "references": refs}
    if slot is not None:
        payload["planned_slot"] = slot
    resp = client.post(f"/api/sessions/{sid}/answers", json=payload)
    resp.raise_for_status()
    return resp.json()


def test_local_review_event_logging_note_only_skip_and_trash_purge(client):
    role = client.post("/api/roles", json=ROLE_PAYLOAD).json()
    sid = client.post("/api/sessions", json={"candidate": "Ada", "role": role["name"], "role_id": role["id"], "consent": True}).json()["id"]
    ans = _add_answer(client, sid, question="How do you avoid deadlocks?", answer="Use consistent lock order across tables.", slot=1, match=True)

    # First disposition change logs local-operator event.
    r1 = client.patch(f"/api/sessions/{sid}/answers/{ans['id']}", json={"disposition": "explained", "note": "Clear"}).json()
    # Note-only edit must not record another disposition event.
    client.patch(f"/api/sessions/{sid}/answers/{ans['id']}", json={"disposition": "explained", "note": "Clear and verified", "expected_revision": r1["revision"]}).raise_for_status()
    with store.connection() as db:
        events = db.execute("SELECT * FROM answer_review_events WHERE answer_id=?", (ans["id"],)).fetchall()
    assert len(events) == 1
    assert (events[0]["reviewer_id"], events[0]["reviewer_email"]) == ("local-operator", "local-operator")
    assert (events[0]["previous_disposition"], events[0]["disposition"]) == ("pending", "explained")

    # Trashing hides session from analytics; restoring brings it back; purging cascades events cleanly.
    marker = client.post(f"/api/sessions/{sid}/trash").json()
    assert client.get("/api/roles/analytics").json()["roles"][0]["session_count"] == 0
    client.post(f"/api/trash/{sid}/restore", json={"operation_version": marker["operation_version"]}).raise_for_status()
    assert client.get("/api/roles/analytics").json()["roles"][0]["session_count"] == 1
    marker2 = client.post(f"/api/sessions/{sid}/trash").json()
    client.post(f"/api/trash/{sid}/purge", json={"operation_version": marker2["operation_version"], "confirm_session_id": sid}).raise_for_status()
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM answer_review_events").fetchone()[0] == 0


def test_multi_reviewer_calibration_analytics_and_disagreements(embedded_clients):
    alice, bob = embedded_clients
    # Unauthenticated request must fail closed under embedded auth.
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as anon:
        for path in ("/api/roles/analytics", f"/api/roles/{uuid4()}/calibration", f"/api/roles/{uuid4()}/versions"):
            assert anon.get(path).status_code == 401

    role = alice.post("/api/roles", json=ROLE_PAYLOAD).json()
    s1 = alice.post("/api/sessions", json={"candidate": "C1", "role": role["name"], "role_id": role["id"], "consent": True}).json()["id"]
    s2 = alice.post("/api/sessions", json={"candidate": "C2", "role": role["name"], "role_id": role["id"], "consent": True}).json()["id"]
    a1 = _add_answer(
        alice,
        s1,
        question="How do you avoid deadlocks?",
        answer="Always sort lock acquisition keys consistently across every worker thread before acquiring secondary latches.",
        slot=1,
        match=True,
    )
    a2 = _add_answer(alice, s1, question="Explain WAL durability.", answer="Flush journal frames before commit ack.", slot=2, match=False)
    a3 = _add_answer(alice, s2, question="How do you avoid deadlocks?", answer="Avoid nested locks when possible.", slot=1, match=False)
    alice.post(f"/api/sessions/{s1}/finish").raise_for_status()

    # Alice passes a1 and a2; Bob overrides a1 to unresolved (disagreement!) and discloses a3.
    alice.patch(f"/api/sessions/{s1}/answers/{a1['id']}", json={"disposition": "explained", "note": "Good"}).raise_for_status()
    alice.patch(f"/api/sessions/{s1}/answers/{a2['id']}", json={"disposition": "explained", "note": "Verified"}).raise_for_status()
    bob.patch(f"/api/sessions/{s1}/answers/{a1['id']}", json={"disposition": "unresolved", "note": "Missed edge case"}).raise_for_status()
    bob.patch(f"/api/sessions/{s2}/answers/{a3['id']}", json={"disposition": "disclosed", "note": "Used notes"}).raise_for_status()

    analytics = alice.get("/api/roles/analytics").json()
    assert len(analytics["roles"]) == 1
    item = analytics["roles"][0]
    assert item["role_id"] == role["id"]
    assert item["session_count"] == 2 and item["finished_count"] == 1
    assert item["answer_count"] == 3 and item["match_count"] == 1 and item["insufficient_count"] == 2
    assert item["match_rate_pct"] == 33.3
    # Final answer dispositions: a1=unresolved, a2=explained, a3=disclosed -> 1 pass, 2 concern -> 33.3% pass, 66.7% concern.
    assert item["explained_count"] == 1 and item["unresolved_count"] == 1 and item["disclosed_count"] == 1
    assert item["concern_count"] == 2 and item["pending_count"] == 0
    assert item["pass_rate_pct"] == 33.3 and item["concern_rate_pct"] == 66.7
    assert item["multi_reviewer_disagreements"] == 1

    reviewers = {r["reviewer_email"]: r for r in item["reviewer_summary"]}
    assert reviewers["alice@example.invalid"]["total_reviews"] == 2
    assert reviewers["alice@example.invalid"]["pass_rate_pct"] == 100.0
    assert reviewers["alice@example.invalid"]["delta_vs_baseline_pp"] == 66.7
    assert reviewers["bob@example.invalid"]["total_reviews"] == 2
    assert reviewers["bob@example.invalid"]["pass_rate_pct"] == 0.0
    assert reviewers["bob@example.invalid"]["concern_rate_pct"] == 100.0
    assert reviewers["bob@example.invalid"]["delta_vs_baseline_pp"] == -33.3

    cal = alice.get(f"/api/roles/{role['id']}/calibration").json()
    assert cal["summary"]["multi_reviewer_disagreements"] == 1
    assert len(cal["question_breakdown"]) == 2
    assert cal["question_breakdown"][0]["planned_slot"] == 1
    assert cal["question_breakdown"][0]["disagreement_count"] == 1
    assert cal["disagreements"][0]["answer_id"] == a1["id"]
    assert alice.get(f"/api/roles/{uuid4()}/calibration").status_code == 404


def test_rubric_versioning_diff_restore_and_conflict_guard(client):
    v1 = client.post("/api/roles", json=ROLE_PAYLOAD).json()
    rid = v1["id"]
    assert v1["version_number"] == 1 and v1["rubric"] == [CRIT_A]

    crit_a_v2 = {**CRIT_A, "weight": 75}
    v2 = client.put(
        f"/api/roles/{rid}",
        json={
            **ROLE_PAYLOAD,
            "version": v1["version"],
            "questions": ["How do you avoid deadlocks?", "Design a B-tree latch protocol."],
            "rubric": [crit_a_v2, CRIT_B],
            "change_note": "Added clarity criterion",
        },
    ).json()
    assert v2["version_number"] == 2 and v2["version"] != v1["version"]

    # Partial update without rubric preserves existing rubric and increments version_number.
    v3 = client.put(
        f"/api/roles/{rid}",
        json={
            "name": v2["name"],
            "description": "Updated desc",
            "questions": v2["questions"],
            "version": v2["version"],
            "change_note": "Desc tweak",
        },
    ).json()
    assert v3["version_number"] == 3 and v3["rubric"] == [crit_a_v2, CRIT_B]

    history = client.get(f"/api/roles/{rid}/versions").json()
    assert [entry["version_number"] for entry in history["versions"]] == [3, 2, 1]
    assert history["versions"][0]["change_note"] == "Desc tweak"

    detail = client.get(f"/api/roles/{rid}/versions/1").json()
    diff = detail["diff"]
    assert diff["has_changes"] is True
    assert set(diff["changed_fields"]) == {"description", "questions", "rubric"}
    assert diff["questions"]["added"] == ["Design a B-tree latch protocol."]
    assert diff["questions"]["removed"] == ["Explain WAL durability."]
    assert [c["id"] for c in diff["rubric"]["added"]] == ["crit-clarity"]
    assert diff["rubric"]["modified"][0]["id"] == "crit-accuracy"

    # Stale expected_version fails with 409 role-version and leaves v3 intact.
    conflict = client.post(
        f"/api/roles/{rid}/versions/1/restore",
        json={"expected_version": v1["version"], "change_note": "Should fail"},
    )
    assert conflict.status_code == 409
    assert conflict.headers["X-InterviewCheck-Conflict"] == "role-version"
    assert client.get(f"/api/roles/{rid}").json()["version_number"] == 3

    # Valid restore creates immutable v4 matching v1 content.
    restored = client.post(
        f"/api/roles/{rid}/versions/1/restore",
        json={"expected_version": v3["version"], "change_note": "Rollback to v1"},
    )
    restored.raise_for_status()
    body = restored.json()
    assert body["version_number"] == 4 and body["restored_from_version"] == 1
    assert body["version"] == v1["version"] and body["rubric"] == [CRIT_A]
    history_after = client.get(f"/api/roles/{rid}/versions").json()
    assert [entry["version_number"] for entry in history_after["versions"]] == [4, 3, 2, 1]
    assert history_after["versions"][0]["change_note"] == "Rollback to v1"


def test_rubric_validation_import_snapshot_and_legacy_upgrade(client, tmp_path):
    for bad in (
        {"rubric": [{**CRIT_A, "weight": 0}]},
        {"rubric": [{**CRIT_A, "weight": 101}]},
        {"rubric": [{**CRIT_A, "weight": True}]},
        {"rubric": [{**CRIT_A, "criterion": "   "}]},
        {"rubric": [{**CRIT_A, "id": f"c-{i}"} for i in range(26)]},
        {"change_note": "x" * 301},
    ):
        assert client.post("/api/roles", json={**ROLE_PAYLOAD, **bad}).status_code == 422

    # Import creates v1 snapshot immediately.
    doc = {"format": "interviewcheck.role", "version": 1, "role": {"workspaceID": "w-1", "name": "SRE", "plannedQuestions": [{"text": "Q1?"}]}}
    imported = client.post("/api/roles/import", json=doc).json()
    versions = client.get(f"/api/roles/{imported['id']}/versions").json()
    assert len(versions["versions"]) == 1 and versions["versions"][0]["change_note"] == "Imported role"

    # Legacy DB upgrade adds columns and backfills v1 snapshots.
    legacy_db = tmp_path / "legacy_upgrade.sqlite"
    rid = str(uuid4())
    with closing(sqlite3.connect(legacy_db)) as db, db:
        db.executescript("CREATE TABLE roles(id TEXT PRIMARY KEY, name TEXT, description TEXT, questions TEXT, legacy TEXT);")
        db.execute("INSERT INTO roles VALUES (?, 'Legacy Role', 'Old', '[\"Q?\"]', NULL)", (rid,))
    store.initialize(legacy_db)
    with store.connection(legacy_db) as db:
        snaps = db.execute("SELECT * FROM role_versions WHERE role_id=?", (rid,)).fetchall()
        assert len(snaps) == 1 and snaps[0]["version_number"] == 1
        assert db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='answer_review_events'").fetchone() is not None


def test_remote_optional_actor_and_version_boundary_errors(client, monkeypatch):
    role = client.post("/api/roles", json=ROLE_PAYLOAD).json()
    rid = role["id"]
    same_diff = client.get(f"/api/roles/{rid}/versions/1").json()["diff"]
    assert same_diff["has_changes"] is False and same_diff["changed_fields"] == []
    assert client.get(f"/api/roles/{rid}/versions/0").status_code == 422
    assert client.get(f"/api/roles/{rid}/versions/99").status_code == 404
    assert client.post(
        f"/api/roles/{rid}/versions/99/restore",
        json={"expected_version": role["version"], "change_note": "Missing"},
    ).status_code == 404

    # Remote access mode resolves (user["id"], user["email"]) via upstream /me.
    from unittest.mock import AsyncMock
    from api import access

    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://access.example.test")
    monkeypatch.setattr(
        access,
        "upstream",
        AsyncMock(
            return_value={
                "user": {"id": "usr-remote-1", "email": "remote@example.invalid"},
                "entitlement": {"active": True},
            }
        ),
    )
    client.cookies.set(access.COOKIE, "mm_remote_token_fixture")
    sid = client.post("/api/sessions", json={"candidate": "R", "role": role["name"], "role_id": rid, "consent": True}).json()["id"]
    ans = _add_answer(client, sid, question="Q?", answer="A", match=False)
    client.patch(f"/api/sessions/{sid}/answers/{ans['id']}", json={"disposition": "explained", "note": "Ok"}).raise_for_status()
    with store.connection() as db:
        ev = db.execute("SELECT reviewer_id, reviewer_email FROM answer_review_events WHERE answer_id=?", (ans["id"],)).fetchone()
    assert (ev["reviewer_id"], ev["reviewer_email"]) == ("usr-remote-1", "remote@example.invalid")


def test_version_bounds_duplicate_rubric_ids_and_stale_version_number(client):
    v1 = client.post("/api/roles", json=ROLE_PAYLOAD).json()
    rid = v1["id"]
    for bad_num in (2**63, 2**64):
        assert client.get(f"/api/roles/{rid}/versions/{bad_num}").status_code == 422
        assert client.post(
            f"/api/roles/{rid}/versions/{bad_num}/restore",
            json={"expected_version": v1["version"], "change_note": "Overflow"},
        ).status_code == 422
        assert client.put(f"/api/roles/{rid}", json={**ROLE_PAYLOAD, "version_number": bad_num}).status_code == 422

    assert client.post("/api/roles", json={**ROLE_PAYLOAD, "rubric": [CRIT_A, CRIT_A]}).status_code == 422
    assert client.put(f"/api/roles/{rid}", json={**ROLE_PAYLOAD, "rubric": [CRIT_A, CRIT_A]}).status_code == 422

    v2 = client.put(
        f"/api/roles/{rid}",
        json={**ROLE_PAYLOAD, "version": v1["version"], "description": "v2", "change_note": "v2"},
    ).json()
    stale = client.put(
        f"/api/roles/{rid}",
        json={**ROLE_PAYLOAD, "version_number": 1, "description": "stale"},
    )
    assert stale.status_code == 409
    assert stale.headers["X-InterviewCheck-Conflict"] == "role-version"
    v3 = client.put(
        f"/api/roles/{rid}",
        json={**ROLE_PAYLOAD, "version_number": v2["version_number"], "description": "v3", "change_note": "v3"},
    )
    assert v3.status_code == 200 and v3.json()["version_number"] == 3


def test_legacy_restored_role_edit_and_backup_tag_rubric_validation(client):
    import json

    legacy_rid = str(uuid4())
    sid = str(uuid4())
    doc = {
        "format": "interviewcheck.workspace",
        "version": 1,
        "roles": [{
            "id": legacy_rid,
            "name": "Legacy Restored Role",
            "description": "From v1 backup",
            "questions": ["Q1"],
            "policy": "Notes allowed.",
            "permitted_sources": [],
            "rubric": [CRIT_A],
            "version_number": 1,
            "versions": [],
        }],
        "sessions": [{
            "id": sid,
            "candidate": "Backup Candidate",
            "role": "Legacy Restored Role",
            "role_id": legacy_rid,
            "planned_questions": ["Q1"],
            "policy": "Notes allowed.",
            "permitted_sources": [],
            "consent": True,
            "created_at": "2026-01-01T00:00:00+00:00",
            "ended_at": None,
            "answers": [],
            "tags": [" padded "],
        }],
    }
    raw = json.dumps(doc).encode("utf-8")
    preview = client.post("/api/backups/preview", content=raw)
    preview.raise_for_status()
    fp = preview.json()["fingerprint"]
    client.post("/api/backups/restore", content=raw, headers={"X-Backup-Preview": fp}).raise_for_status()

    assert client.get("/api/interviews/feed?tag=padded").json()["filtered"] == 1
    edited = client.put(
        f"/api/roles/{legacy_rid}",
        json={**ROLE_PAYLOAD, "name": "Legacy Restored Role", "questions": ["Q1", "Q2"], "change_note": "Added Q2"},
    )
    edited.raise_for_status()
    assert edited.json()["version_number"] == 2
    history = client.get(f"/api/roles/{legacy_rid}/versions").json()["versions"]
    assert [(v["version_number"], v["change_note"]) for v in history] == [(2, "Added Q2"), (1, "Initial version")]

    bad_rubric = json.dumps({**doc, "roles": [{**doc["roles"][0], "rubric": [CRIT_A, CRIT_A]}]}).encode("utf-8")
    assert client.post("/api/backups/preview", content=bad_rubric).status_code == 422
    bad_tag = json.dumps({**doc, "sessions": [{**doc["sessions"][0], "tags": ["   "]}]}).encode("utf-8")
    assert client.post("/api/backups/preview", content=bad_tag).status_code == 422


def test_put_role_records_authenticated_actor(embedded_clients):
    alice, bob = embedded_clients
    v1 = alice.post("/api/roles", json=ROLE_PAYLOAD).json()
    rid = v1["id"]
    v2 = bob.put(
        f"/api/roles/{rid}",
        json={**ROLE_PAYLOAD, "version": v1["version"], "description": "Bob edit", "change_note": "Bob update"},
    )
    v2.raise_for_status()
    history = alice.get(f"/api/roles/{rid}/versions").json()["versions"]
    assert [(v["version_number"], v["created_by"]) for v in history] == [
        (2, "bob@example.invalid"),
        (1, "alice@example.invalid"),
    ]


