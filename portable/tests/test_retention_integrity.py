"""Anonymized interviews restore from backups, keep no readable originals, and purge through one path."""
from datetime import datetime, timedelta, timezone
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import retention_policy, session_purge, store, trash
from api.main import app

CANDIDATE = "Beatrix Quillfeather"
SOURCE = "Hydraulic pressure relief valve calibrated to four hundred kilopascals during load testing."
ANSWER = f"{CANDIDATE} said the hydraulic pressure relief valve calibrated to four hundred kilopascals during load testing held."
EDITED = ANSWER + " The pump kept running."
DISCLOSED_NOTE = f"{CANDIDATE} disclosed reading the vendor manual."


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "source.sqlite3"))
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def _interview(client) -> tuple[str, list[str]]:
    sid = client.post("/api/sessions", json={
        "candidate": CANDIDATE, "role": "Reliability Engineer", "policy": "Manual permitted.", "consent": True,
        "permitted_sources": [{"label": "Safety sheet", "text": "Wear gloves near the relief valve."}],
    }).json()["id"]
    base = f"/api/sessions/{sid}/answers"
    refs = [{"label": "Manual", "text": SOURCE}]
    first = client.post(base, json={"question": "Describe calibration.", "answer": ANSWER, "references": refs}).json()
    edited = client.put(f"{base}/{first['id']}", json={
        "question": "Describe calibration.", "answer": EDITED, "references": refs, "expected_revision": 1,
    })
    edited.raise_for_status()
    assert edited.json()["result"]["status"] == "match"
    client.patch(f"{base}/{first['id']}", json={"disposition": "disclosed", "note": DISCLOSED_NOTE}).raise_for_status()
    second = client.post(base, json={"question": "Why?", "answer": f"Because {CANDIDATE} trusted the gauge readings."}).json()
    client.patch(f"{base}/{second['id']}", json={"disposition": "explained", "note": f"Private note on {CANDIDATE}"}).raise_for_status()
    client.post(f"/api/sessions/{sid}/finish").raise_for_status()
    old = (datetime.now(timezone.utc) - timedelta(days=200)).isoformat()
    with store.connection(write=True) as db:
        db.execute("UPDATE sessions SET created_at=? WHERE id=?", (old, sid))
        db.execute("UPDATE session_context SET ended_at=? WHERE session_id=?", (old, sid))
        db.execute("INSERT INTO note_exports VALUES (?,?,?,?,?,?,?,?)", (
            str(uuid4()), sid, "lever", "cand-1", f"{CANDIDATE} (cand-1)", f"Interview with {CANDIDATE}", "sent", old,
        ))
    return sid, [first["id"], second["id"]]


def _anonymize(sid: str) -> None:
    with store.connection(write=True) as db:
        result = retention_policy.execute_retention_job(db, dry_run=False, actor_email="job@example.test")
    assert result["anonymized_session_ids"] == [sid]


def test_anonymized_workspace_backup_previews_and_restores_into_empty_database(client, tmp_path, monkeypatch):
    sid, (first, second) = _interview(client)
    _anonymize(sid)
    exported = client.get("/api/backups/workspace")
    exported.raise_for_status()
    assert CANDIDATE.encode() not in exported.content

    target = tmp_path / "recovered.sqlite3"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
    plan = client.post("/api/backups/preview", content=exported.content)
    assert plan.status_code == 200, plan.text
    assert plan.json()["sessions"]["new"] == 1
    restored = client.post("/api/backups/restore", content=exported.content,
                           headers={"X-Backup-Preview": plan.json()["fingerprint"]})
    assert restored.status_code == 200, restored.text

    answers = {a["id"]: a for a in client.get(f"/api/sessions/{sid}").json()["answers"]}
    assert answers[first]["answer"] == retention_policy.REDACTED_TEXT
    assert answers[first]["result"]["status"] == "insufficient"
    # The disclosure lost the note that recorded it, so its outcome is pending again.
    assert (answers[first]["disposition"], answers[first]["note"]) == ("pending", "")
    assert (answers[second]["disposition"], answers[second]["note"]) == ("explained", "")


def test_retention_run_leaves_no_original_text_in_history_or_note_exports(client):
    sid, (first, _) = _interview(client)
    history = f"/api/sessions/{sid}/answers/{first}/history"
    assert len(client.get(history).json()["entries"]) >= 3
    assert EDITED in client.get(f"{history}/2").text

    _anonymize(sid)

    page = client.get(history).json()
    assert [entry["kind"] for entry in page["entries"]] == ["baseline"]
    assert client.get(f"{history}/1").status_code == 404
    current = client.get(f"{history}/{page['current_revision']}")
    assert current.status_code == 200 and CANDIDATE not in current.text
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM answer_history").fetchone()[0] == 0
        export = db.execute("SELECT recipient, draft FROM note_exports WHERE session_id=?", (sid,)).fetchone()
        assert tuple(export) == (retention_policy.REDACTED_TEXT, retention_policy.REDACTED_TEXT)
        dump = "\n".join(db.iterdump())
    for original in (CANDIDATE, "four hundred kilopascals during load testing held", DISCLOSED_NOTE):
        assert original not in dump


def _assert_gone(sid: str) -> None:
    with store.connection() as db:
        for table in (*session_purge.SESSION_CHILD_TABLES, *session_purge.SESSION_TAIL_TABLES):
            assert db.execute(f"SELECT count(*) FROM {table} WHERE session_id=?", (sid,)).fetchone()[0] == 0, table
        assert db.execute("SELECT count(*) FROM sessions WHERE id=?", (sid,)).fetchone()[0] == 0
        assert db.execute("SELECT count(*) FROM answer_history").fetchone()[0] == 0
        assert not db.execute("PRAGMA foreign_key_check").fetchall()


def _assign(sid: str) -> None:
    with store.connection(write=True) as db:
        db.execute("INSERT INTO session_assignments(session_id, assignee_email, assigned_by, updated_at) VALUES (?,?,?,?)",
                   (sid, "lead@example.test", "lead@example.test", store.timestamp()))


def test_trash_and_retention_purge_remove_the_same_rows(client):
    assert trash.purge_session is retention_policy.purge_session is session_purge.purge_session
    manual, _ = _interview(client)
    _assign(manual)
    marker = client.post(f"/api/sessions/{manual}/trash").json()
    client.post(f"/api/trash/{manual}/purge", json={
        "operation_version": marker["operation_version"], "confirm_session_id": manual,
    }).raise_for_status()
    _assert_gone(manual)

    scheduled, _ = _interview(client)
    _assign(scheduled)
    client.post(f"/api/sessions/{scheduled}/trash").raise_for_status()
    with store.connection(write=True) as db:
        db.execute("UPDATE session_trash SET trashed_at=? WHERE session_id=?",
                   ((datetime.now(timezone.utc) - timedelta(days=60)).isoformat(), scheduled))
        result = retention_policy.execute_retention_job(db, dry_run=False, actor_email="job@example.test")
    assert result["purged_session_ids"] == [scheduled]
    _assert_gone(scheduled)
