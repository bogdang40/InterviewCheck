"""Exercise independent panel actions, visibility, retention, and both supported recovery paths."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing, contextmanager
import json
import sqlite3
from threading import Barrier

from fastapi.testclient import TestClient
import pytest

from api import access, rate_limit, store
from api.main import app
from api.retention_anonymizer import SessionAnonymizer

ADMIN = "chair@panel.test"
MEMBER = "member@panel.test"
NOTE = "Check the saved reasoning in a separate panel discussion."
QUEUE = "/api/calibration/disagreements"


@pytest.fixture
def workspace(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "workspace.sqlite"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "accounts.sqlite"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("ADMIN_EMAILS", ADMIN)
    monkeypatch.setenv("ADMIN_BOOTSTRAP_SECRET", "panel-test-bootstrap-123")
    monkeypatch.setenv("TRIAL_DAYS", "7")
    for name in ("INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_OPERATOR_ID", "INTERVIEWCHECK_ACCESS_URL",
                 "INTERVIEWCHECK_PUBLIC_ORIGIN", "INTERVIEWCHECK_SIGNUP_SECRET"):
        monkeypatch.delenv(name, raising=False)
    rate_limit.reset_all()
    options = {"base_url": "http://127.0.0.1", "headers": {"X-InterviewCheck": "1"}}
    with TestClient(app, **options) as chair, TestClient(app, **options) as member:
        for web, email, extra in ((chair, ADMIN, {"adminSecret": "panel-test-bootstrap-123"}), (member, MEMBER, {})):
            user = web.post("/api/integrations/access/signup", json={"email": email, "password": "panel-test-pass-123",
                                                                    **extra}).raise_for_status().json()
            assert user.get("admin", False) is (web is chair)
        sid = chair.post("/api/sessions", json={"candidate": "Synthetic panel candidate", "role": "Engineer",
                                                "policy": "Manual", "consent": True}).raise_for_status().json()["id"]
        aid = chair.post(f"/api/sessions/{sid}/answers", json={"question": "Explain the test.", "answer": "I wrote a test."}).raise_for_status().json()["id"]
        answer = f"/api/sessions/{sid}/answers/{aid}"
        for web, disposition in ((chair, "explained"), (member, "unresolved")):
            web.patch(answer, json={"disposition": disposition, "note": "Recorded opinion."}).raise_for_status()
        yield chair, member, sid, aid, answer, f"/api/calibration/sessions/{sid}/answers/{aid}/panel"


def command(case, action, note=NOTE):
    return {"expected_basis": case["basis"], "expected_version": case["version"], "expected_evidence": case["evidence"],
            "action": action, "rationale": note, "expected_editor": case.get("editor", "0" * 64)}


def status(web, route):
    return web.get(route).raise_for_status().json()


def decisions(web, view):
    return web.get(QUEUE, params={"panel_view": view}).raise_for_status().json()["items"]


def test_complete_is_independent_and_private_details_require_named_admin(workspace, monkeypatch):
    chair, member, sid, aid, answer, route = workspace
    initial = status(member, route)
    assert initial["status"] == "open" and initial["split"] and len(initial["reviewers"]) == 2
    before_answer = status(member, answer)
    before_card = status(member, f"/api/sessions/{sid}/scorecard")
    payload = command(initial, "discussion_complete")
    assert member.post(route, json=payload).status_code == 403 and member.get(route + "/private").status_code == 403
    assert member.get(route + "/edit").status_code == 403
    assert "editor" not in initial
    editor = status(chair, route + "/edit")
    assert chair.post(route, json=payload).status_code == 409
    payload = command(editor, "discussion_complete")
    result = chair.post(route, json=payload).raise_for_status().json()
    assert result["status"] == "discussion_complete" and result["split"] and result["history_count"] == 1
    event, = result["history"]
    assert event["actor_id"] and event["actor_email"] == ADMIN and event["rationale"] == NOTE
    assert status(chair, route + "/private")["history"] == [event]
    public = member.get(route)
    assert NOTE not in public.text and public.json()["history"] == [
        {"action": "discussion_complete", "sequence": 1, "created_at": event["created_at"]}]
    for fmt in ("json", "csv"):
        exported = chair.get("/api/calibration/export", params={"format": fmt}).raise_for_status()
        assert NOTE not in exported.text and "discussion_complete" not in exported.text and "actor_id" not in exported.text
    assert decisions(chair, "open") == [] and decisions(chair, "completed")[0]["answer_id"] == aid
    assert len(status(member, QUEUE)["items"]) == 1  # Historical calibration remains available.
    assert status(chair, answer) == before_answer and status(chair, f"/api/sessions/{sid}/scorecard") == before_card
    assert chair.post(route, json=payload).status_code == 409
    async def unidentified(_request):
        return {"role": "admin", "email": ADMIN}, "fixture"
    monkeypatch.setattr(access, "require_admin_session", unidentified)
    assert chair.post(route, json=command(result, "reopened")).status_code == 403


def test_material_edit_and_reverted_vote_reopen_discussion_but_note_edit_does_not(workspace):
    chair, member, _, _, answer, route = workspace
    first = chair.post(route, json=command(status(chair, route + "/edit"), "discussion_complete")).raise_for_status().json()
    member.patch(answer, json={"disposition": "unresolved", "note": "Clarified my earlier note."}).raise_for_status()
    after_note = status(chair, route + "/edit")
    assert after_note["status"] == "discussion_complete" and after_note["basis"] == first["basis"]
    assert after_note["evidence"] != first["evidence"]
    assert chair.post(route, json=command(first, "reopened")).status_code == 409
    body = {"question": "Explain the test.", "answer": "I wrote a different test.", "references": []}
    chair.put(answer, json=body).raise_for_status()
    chair.put(answer, json={**body, "answer": "I wrote a test."}).raise_for_status()
    after_material = status(chair, route + "/edit")
    assert after_material["status"] == "changed" and after_material["basis"] != first["basis"]
    assert decisions(chair, "open")[0]["panel_status"] == "changed"
    second = chair.post(route, json=command(after_material, "discussion_complete")).raise_for_status().json()
    member.patch(answer, json={"disposition": "explained", "note": "Converged briefly."}).raise_for_status()
    converged = status(chair, route + "/edit")
    assert not converged["split"] and converged["status"] == "changed"
    member.patch(answer, json={"disposition": "unresolved", "note": "Reviewed separately."}).raise_for_status()
    assert status(chair, route + "/edit")["basis"] != second["basis"]
    follow = chair.post(route, json=command(status(chair, route + "/edit"), "follow_up_required")).raise_for_status().json()
    assert decisions(chair, "open")[0]["panel_status"] == "follow_up_required"
    reopened = chair.post(route, json=command(follow, "reopened")).raise_for_status().json()
    assert reopened["history"][0]["action"] == "reopened" and reopened["history_count"] == 4


def test_concurrent_writes_have_one_winner(workspace):
    chair, _, _, _, _, route = workspace
    payload = command(status(chair, route + "/edit"), "discussion_complete")
    barrier = Barrier(2)
    def decide():
        barrier.wait()
        return chair.post(route, json=payload).status_code
    with ThreadPoolExecutor(2) as pool:
        assert sorted(f.result() for f in [pool.submit(decide), pool.submit(decide)]) == [200, 409]
    assert status(chair, route + "/edit")["history_count"] == 1


def test_sqlite_restores_history_json_restores_only_opinions(workspace, tmp_path, monkeypatch):
    chair, member, sid, aid, _, route = workspace
    closed = chair.post(route, json=command(status(chair, route + "/edit"), "discussion_complete")).raise_for_status().json()
    source = store.db_path()
    sqlite_copy = tmp_path / "restored-full.sqlite"
    with closing(sqlite3.connect(source)) as original, closing(sqlite3.connect(sqlite_copy)) as backup:
        original.backup(backup)
    raw = member.get("/api/backups/workspace", params={"session_id": sid}).raise_for_status().content
    assert NOTE.encode() not in raw and b"panel_decisions" not in raw and b"discussion_complete" not in raw
    forged = json.loads(raw)
    forged["sessions"][0]["panel_decisions"] = closed["history"]
    assert member.post("/api/backups/preview", json=forged).status_code == 422
    def restore_json():
        preview = member.post("/api/backups/preview", content=raw).raise_for_status().json()
        member.post("/api/backups/restore", content=raw, headers={"X-Backup-Preview": preview["fingerprint"]}).raise_for_status()
    restore_json()
    assert status(chair, route + "/private")["history"] == closed["history"]
    empty = tmp_path / "json-restore.sqlite"
    store.initialize(empty)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(empty))
    restore_json()
    restored = status(chair, route + "/edit")
    assert restored["status"] == "open" and restored["history"] == [] and restored["split"]
    store.initialize(sqlite_copy)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(sqlite_copy))
    assert status(chair, route + "/private") == closed
    marker = chair.post(f"/api/sessions/{sid}/trash").raise_for_status().json()
    assert chair.get(route).status_code == 404 and decisions(chair, "all") == []
    chair.post(f"/api/trash/{sid}/restore", json={"operation_version": marker["operation_version"]}).raise_for_status()
    assert status(chair, route + "/edit")["status"] == "discussion_complete"
    with store.connection(write=True) as db:
        SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=True, actor_email="fixture", now_iso=store.timestamp())
        assert db.execute("SELECT count(*) FROM panel_decisions WHERE answer_id=?", (aid,)).fetchone()[0] == 0
    assert chair.get(route + "/private").status_code == 404 and decisions(chair, "all") == []


def test_stale_admin_draft_cannot_be_attributed_to_another_admin(workspace, monkeypatch):
    chair, second, _, _, _, route = workspace
    new_email = "second-chair@example.test"
    monkeypatch.setenv("ADMIN_EMAILS", f"{ADMIN},{new_email}")
    stale = command(status(chair, route + "/edit"), "discussion_complete", "Private first chair draft")
    created = second.post("/api/integrations/access/signup", json={"email": new_email,
        "password": "fixture-password-123", "adminSecret": "panel-test-bootstrap-123"}).raise_for_status().json()
    assert created["admin"]
    current = status(second, route + "/edit")
    assert current["editor"] != stale["expected_editor"] and current["history"] == []
    refused = second.post(route, json=stale)
    assert refused.status_code == 409 and refused.headers["X-InterviewCheck-Conflict"] == "panel-authority"
    assert status(chair, route + "/private")["history"] == []
    good = second.post(route, json=command(current, "discussion_complete", "Second chair reasoning")).raise_for_status().json()
    assert [(e["actor_email"], e["rationale"]) for e in good["history"]] == [(new_email, "Second chair reasoning")]


def test_revoked_embedded_session_after_request_checks_cannot_write(workspace, monkeypatch):
    from api import account_db, panel_review
    chair, _, _, _, _, route = workspace
    draft = command(status(chair, route + "/edit"), "discussion_complete")
    real = panel_review._record
    def before_writer(sid, aid, payload, actor):
        with account_db.connection(write=True) as adb:
            adb.execute("UPDATE sessions SET revoked_at=? WHERE token_hash=?",
                        (account_db.now(), account_db.digest(actor.session_token)))
        return real(sid, aid, payload, actor)
    monkeypatch.setattr(panel_review, "_record", before_writer)
    assert chair.post(route, json=draft).status_code == 401
    with store.connection() as db:
        assert db.execute("SELECT COUNT(*) FROM panel_decisions").fetchone()[0] == 0


def test_restored_identical_exchange_rejects_first_unsubmitted_draft(workspace):
    chair, _, sid, _, _, route = workspace
    source = status(chair, route + "/edit")
    assert source["history_count"] == 0
    command_a = command(source, "follow_up_required", "Draft on a previous record")
    raw = chair.get("/api/backups/workspace").raise_for_status().content
    trash = chair.post(f"/api/sessions/{sid}/trash").raise_for_status().json()
    chair.post(f"/api/trash/{sid}/purge", json={"operation_version": trash["operation_version"],
                                                "confirm_session_id": sid}).raise_for_status()
    preview = chair.post("/api/backups/preview", content=raw).raise_for_status().json()
    chair.post("/api/backups/restore", content=raw, headers={"X-Backup-Preview": preview["fingerprint"]}).raise_for_status()
    current = status(chair, route + "/edit")
    assert source["evidence"] == current["evidence"] and current["editor"] != source["editor"]
    refused = chair.post(route, json=command_a)
    assert refused.status_code == 409 and refused.headers["X-InterviewCheck-Conflict"] == "panel-authority"
    assert not status(chair, route + "/private")["history"]
    chair.post(route, json=command(current, "follow_up_required")).raise_for_status()

def test_all_page_reads_material_only_for_visible_adjudicated_cases(workspace, monkeypatch):
    chair, member, sid, first_id, _, first_route = workspace
    hidden_marker = "Hidden private evidence marker"
    long_answer = hidden_marker + " Independent instrument readings were recorded." * 390
    references = [{"label": "Fixture reference", "text": hidden_marker + " Unrelated passage." * 350}]
    hidden = chair.post(f"/api/sessions/{sid}/answers", json={"question": hidden_marker + " question?",
                        "answer": long_answer, "references": references}).raise_for_status().json()
    second_id = hidden["id"]
    second_answer = f"/api/sessions/{sid}/answers/{second_id}"
    second_route = f"/api/calibration/sessions/{sid}/answers/{second_id}/panel"
    for user, disposition in ((chair, "explained"), (member, "unresolved")):
        user.patch(second_answer, json={"disposition": disposition, "note": "Opinion."}).raise_for_status()
    for route in (second_route, first_route):
        chair.post(route, json=command(status(chair, route + "/edit"), "discussion_complete")).raise_for_status()

    # The older decision is now stale. Its status must be checked when displayed or used for filtering.
    latest = status(chair, second_answer)
    chair.put(second_answer, json={"expected_revision": latest["revision"], "question": hidden["question"],
              "answer": long_answer + " Updated calibration.", "references": references}).raise_for_status()
    with store.connection(write=True) as db:
        # Purposeful deterministic order independent of wall clock or timestamp precision.
        db.execute("UPDATE panel_decisions SET created_at='2080-01-03T00:00:00Z' WHERE answer_id=?", (first_id,))
        db.execute("UPDATE panel_decisions SET created_at='2080-01-02T00:00:00Z' WHERE answer_id=?", (second_id,))

    real_connection = store.connection
    material_ids, large_rows = [], []

    @contextmanager
    def observed(*args, **kwargs):
        with real_connection(*args, **kwargs) as db:
            def row_factory(cursor, values):
                row = sqlite3.Row(cursor, values)
                if any(isinstance(value, str) and hidden_marker in value for value in values):
                    large_rows.append(True)
                if {"answer_id", "answer", "refs"} <= set(row.keys()):
                    material_ids.append(row["answer_id"])
                return row
            db.row_factory = row_factory
            yield db

    with monkeypatch.context() as capture:
        capture.setattr(store, "connection", observed)
        one = member.get(QUEUE, params={"panel_view": "all", "limit": 1, "page": 1}).raise_for_status().json()
    assert one["matching_cases"] == 2 and one["summary"]["total_disagreed_answers"] == 2
    assert [(row["answer_id"], row["panel_status"]) for row in one["items"]] == [(first_id, "discussion_complete")]
    assert not large_rows and set(material_ids) <= {first_id}
    two = member.get(QUEUE, params={"panel_view": "all", "limit": 1, "page": 2}).raise_for_status().json()
    assert [(row["answer_id"], row["panel_status"]) for row in two["items"]] == [(second_id, "changed")]
    assert [row["answer_id"] for row in decisions(member, "completed")] == [first_id]
    assert [row["answer_id"] for row in decisions(member, "open")] == [second_id]
