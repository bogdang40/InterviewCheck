import sqlite3
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from threading import Barrier
from unittest.mock import AsyncMock
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import access, store
from api.main import app


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite"))
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_URL", raising=False)
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_MODE", raising=False)
    monkeypatch.delenv("INTERVIEWCHECK_PUBLIC_ORIGIN", raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        yield client


def prepare(client):
    session = client.post(
        "/api/sessions",
        json={"candidate": "Fixture", "role": "SRE", "policy": "Notes allowed.", "consent": True},
    )
    session.raise_for_status()
    base = "/api/sessions/" + session.json()["id"] + "/answers"
    answer = client.post(base, json={"question": "How?", "answer": "The old answer."})
    answer.raise_for_status()
    assert answer.json()["revision"] == 1
    return base + "/" + answer.json()["id"]


def test_review_and_exchange_share_a_revision(client):
    path = prepare(client)
    review = {"note": "Saved evidence.", "disposition": "unresolved", "expected_revision": 1}
    assert client.patch(path, json=review).json()["revision"] == 2
    edit = {"question": "Why?", "answer": "New content.", "expected_revision": 1}
    stale = client.put(path, json=edit)
    assert stale.status_code == 409 and stale.headers["x-interviewcheck-conflict"] == "answer-revision"
    assert client.get(path).json()["note"] == "Saved evidence."
    assert client.get(path).json()["question"] == "How?"
    edit["expected_revision"] = 2
    assert client.put(path, json=edit).json()["revision"] == 3
    assert client.patch(path, json={**review, "expected_revision": 2}).status_code == 409
    current = client.get(path).json()
    assert current["disposition"] == "pending" and current["note"].endswith("Saved evidence.")
    assert client.put(path, json={**edit, "expected_revision": 3}).json()["revision"] == 3
    # Older clients can still make edits. Current clients then see the new revision.
    assert (
        client.patch(path, json={"note": "Legacy client", "disposition": "explained"}).json()["revision"] == 4
    )
    assert client.patch(path, json={**review, "expected_revision": True}).status_code == 422
    assert client.patch(path, json={**review, "expected_revision": 0}).status_code == 422
    history = client.get(path + "/history").raise_for_status().json()
    assert [entry["revision"] for entry in history["entries"]] == [4, 3, 2, 1]
    assert [entry["kind"] for entry in history["entries"]] == ["review_update", "answer_edit", "review_update", "baseline"]
    earlier = client.get(path + "/history/2").raise_for_status().json()
    assert earlier["snapshot"]["disposition"] == "unresolved"
    assert earlier["snapshot"]["note"] == "Saved evidence."
    assert earlier["snapshot"]["question"] == "How?"
    assert earlier["actor"] == {"kind": "local_operator"}
    assert datetime.fromisoformat(earlier["saved_at"]).utcoffset() == timedelta(0)


def test_competing_within_same_revision_has_one_winner(client):
    path = prepare(client)
    barrier = Barrier(2)

    def change(note):
        barrier.wait()
        return client.patch(path, json={"expected_revision": 1, "note": note, "disposition": "explained"})

    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(change, ("Reviewer one", "Reviewer two")))
    assert sorted(result.status_code for result in responses) == [200, 409]
    assert client.get(path).json()["revision"] == 2
    assert client.get(path).json()["note"] == next(
        result.json()["note"] for result in responses if result.is_success
    )
    assert len(client.get(path + "/history").raise_for_status().json()["entries"]) == 2


def test_existing_answer_gains_revision_without_losing_review(client):
    path = prepare(client)
    client.patch(path, json={"note": "Keep this", "disposition": "explained"}).raise_for_status()
    with sqlite3.connect(store.db_path()) as db:
        # The historical schema predates receipt validation against stored answer history.
        db.execute("DROP TRIGGER retention_hold_receipt")
        db.execute("DROP TABLE answer_history")
        db.execute("ALTER TABLE answers DROP COLUMN revision")
    store.initialize(store.db_path())
    store.initialize(store.db_path())
    current = client.get(path).json()
    assert (current["revision"], current["note"], current["disposition"]) == (1, "Keep this", "explained")


def test_history_capture_starts_at_existing_revision_without_backfill(client):
    path = prepare(client)
    aid = path.rsplit("/", 1)[1]
    with store.connection(write=True) as db:
        db.execute("DROP TABLE answer_history")
        db.execute("UPDATE answers SET revision=8 WHERE id=?", (aid,))
    store.initialize(store.db_path())
    store.initialize(store.db_path())
    baseline = {"revision": 8, "kind": "baseline", "saved_at": None, "actor": None}
    assert client.get(path + "/history").raise_for_status().json() == {
        "current_revision": 8, "baseline_revision": 8, "entries": [baseline], "next_before_revision": None,
    }
    initial = client.get(path + "/history/8").raise_for_status().json()
    assert initial["snapshot"]["answer"] == "The old answer."
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM answer_history").fetchone()[0] == 0
    assert client.get(path + "/history/7").status_code == 404
    client.put(path, json={"question": "How?", "answer": "A new answer.", "expected_revision": 8}).raise_for_status()
    assert client.get(path + "/history/8").raise_for_status().json() == initial
    assert [entry["revision"] for entry in client.get(path + "/history").json()["entries"]] == [9, 8]


def test_writes_during_an_application_rollback_leave_an_honest_gap(client):
    path = prepare(client)
    history = path + "/history"
    client.patch(path, json={"disposition": "explained", "note": "First review."}).raise_for_status()
    previous = client.get(history + "/2").raise_for_status().json()
    with store.connection(write=True) as db:
        # An older application modifies only the current state and revision.
        db.execute("UPDATE answers SET note=?, revision=4 WHERE id=?", ("Saved during rollback.", path.rsplit("/", 1)[1]))
    first = client.get(history, params={"limit": 1}).raise_for_status().json()
    assert first["next_before_revision"] == 4
    assert first["entries"] == [{"revision": 4, "kind": "baseline", "saved_at": None, "actor": None}]
    assert client.get(history + "/3").status_code == 404
    virtual = client.get(history + "/4").raise_for_status().json()
    assert virtual["snapshot"]["note"] == "Saved during rollback."
    client.patch(path, json={"disposition": "explained", "note": "Review resumed.", "expected_revision": 4}).raise_for_status()
    assert client.get(history + "/2").raise_for_status().json() == previous
    assert client.get(history + "/4").raise_for_status().json() == virtual
    assert [entry["revision"] for entry in client.get(history).json()["entries"]] == [5, 4, 2, 1]


def test_content_edit_preserves_earlier_evidence_and_lineage(client):
    parent = prepare(client)
    base, parent_id = parent.rsplit("/", 1)
    phrase = "Separate the winding terminals before measuring the resistance between each pair."
    child = client.post(base, json={"question": "What checks?", "answer": phrase, "parent_answer_id": parent_id,
                                   "references": [{"label": "Example", "text": phrase}]}).raise_for_status().json()
    path = base + "/" + child["id"]
    assert child["result"]["status"] == "match"
    edit = {"question": "What checks?", "answer": "Inspect again.", "parent_answer_id": None, "expected_revision": 1}
    client.put(path, json=edit).raise_for_status()
    saved = client.get(path + "/history/1").raise_for_status().json()["snapshot"]
    assert saved["result"] == child["result"] and saved["references"] == child["references"]
    assert saved["parent_answer_id"] == parent_id
    assert client.get(path).raise_for_status().json()["parent_answer_id"] is None


def test_failed_snapshot_rolls_back_answer_and_lazy_baseline(client):
    path = prepare(client)
    with store.connection(write=True) as db:
        db.execute("""CREATE TRIGGER fail_history BEFORE INSERT ON answer_history
                      WHEN NEW.kind='answer_edit' BEGIN SELECT RAISE(ABORT, 'Synthetic failure'); END""")
    edit = {"question": "What changed?", "answer": "Uncommitted answer.", "expected_revision": 1}
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"},
                    raise_server_exceptions=False) as requests:
        assert requests.put(path, json=edit).status_code == 500
    assert client.get(path).json()["revision"] == 1
    assert client.get(path).json()["answer"] == "The old answer."
    with store.connection(write=True) as db:
        assert db.execute("SELECT count(*) FROM answer_history").fetchone()[0] == 0
        db.execute("DROP TRIGGER fail_history")
    assert client.put(path, json=edit).raise_for_status().json()["revision"] == 2


def test_actor_uses_one_workspace_authorization_decision(client, monkeypatch):
    path = prepare(client)
    account_id = str(uuid4())
    email = "operator@example.test"
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://access.example.test")
    monkeypatch.setenv("INTERVIEWCHECK_OPERATOR_EMAIL", email)
    user = {"id": account_id.upper(), "email": email}
    authorize = AsyncMock(return_value={"user": user, "entitlement": {"active": True}})
    monkeypatch.setattr(access, "upstream", authorize)
    assert client.get(path + "/history").status_code == 401
    assert client.get(path + "/history/1").status_code == 401
    client.cookies.set(access.COOKIE, "fixture-session")
    review = {"disposition": "explained", "note": "Operator reviewed.", "expected_revision": 1}
    client.patch(path, json=review).raise_for_status()
    authorize.assert_awaited_once_with("me", token="fixture-session")
    saved = client.get(path + "/history/2").raise_for_status().json()
    assert saved["actor"] == {"kind": "account", "id": account_id}
    assert email not in str(saved)
    user.pop("id")
    client.patch(path, json={**review, "note": "New note.", "expected_revision": 2}).raise_for_status()
    assert client.get(path + "/history/3").raise_for_status().json()["actor"] is None


def test_history_respects_session_scope_and_trash(client):
    path = prepare(client)
    key = path.split("/")[3]
    session = "/api/sessions/" + key
    history = path + "/history"
    client.patch(path, json={"disposition": "explained", "note": "Private review note."}).raise_for_status()
    saved = client.get(history + "/2").raise_for_status().json()
    other = prepare(client).split("/")[3]
    for suffix in ("", "/2"):
        assert client.get(history.replace(key, other) + suffix).status_code == 404
    assert client.get(history + "/0").status_code == 422
    assert client.get(history, params={"limit": 51}).status_code == 422

    tombstone = client.post(session + "/trash").raise_for_status().json()
    assert client.get(history).status_code == 404 and client.get(history + "/2").status_code == 404
    assert "Private review note" not in client.get("/api/trash").raise_for_status().text
    trash_path = "/api/trash/" + key
    client.post(trash_path + "/restore", json={"operation_version": tombstone["operation_version"]}).raise_for_status()
    assert client.get(history + "/2").raise_for_status().json() == saved
    tombstone = client.post(session + "/trash").raise_for_status().json()
    client.post(trash_path + "/purge", json={"operation_version": tombstone["operation_version"],
                                            "confirm_session_id": key}).raise_for_status()
    assert client.get(history).status_code == 404 and client.get(history + "/2").status_code == 404
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM answer_history").fetchone()[0] == 0
