"""Tests for M24-W2 session interviewer assignment and review queue API."""
from contextlib import contextmanager
import sqlite3
from uuid import uuid4

from fastapi import APIRouter, Depends, FastAPI
from fastapi.exceptions import RequestValidationError
from fastapi.testclient import TestClient
import pytest

from api import access, account_db, session_assignment, store
from api import main
from api.local_boundary import LocalBoundary


def _build_app() -> FastAPI:
    test_app = FastAPI(lifespan=main.lifespan)
    test_app.add_middleware(LocalBoundary)
    test_app.add_exception_handler(RequestValidationError, main.invalid_input)
    ws = APIRouter(prefix="/api", dependencies=[Depends(access.require_entitlement)])
    ws.include_router(session_assignment.router)
    test_app.include_router(ws)
    test_app.include_router(main.workspace)
    test_app.include_router(main.integrations)
    return test_app


def _seed_user(*, email: str, role: str = "user") -> str:
    uid, ts = str(uuid4()), account_db.now()
    with account_db.connection(write=True) as db:
        db.execute(
            "INSERT INTO users(id, email, password_hash, role, disabled, created_at, updated_at) VALUES (?,?,?,?,0,?,?)",
            (uid, email, account_db.DECOY, role, ts, ts),
        )
        return account_db.issue(db, uid, "pytest")


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    for key in (
        "INTERVIEWCHECK_ACCESS_MODE",
        "INTERVIEWCHECK_ACCESS_URL",
        "INTERVIEWCHECK_OPERATOR_EMAIL",
        "INTERVIEWCHECK_PUBLIC_ORIGIN",
        "INTERVIEWCHECK_PRODUCTION",
    ):
        monkeypatch.delenv(key, raising=False)
    with TestClient(_build_app(), base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def _create_session(client: TestClient, *, candidate: str = "Ada Lovelace", role: str = "Staff Engineer") -> str:
    res = client.post(
        "/api/sessions",
        json={"candidate": candidate, "role": role, "policy": "No external help.", "consent": True},
    )
    res.raise_for_status()
    return res.json()["id"]


def test_migration_schema_and_defensive_without_review_events(tmp_path):
    db_file = tmp_path / "review.sqlite3"
    store.initialize(db_file)
    with store.connection(db_file) as db:
        cols = {row[1] for row in db.execute("PRAGMA table_info(session_assignments)")}
        assert cols == {"session_id", "assignee_email", "assigned_by", "priority", "due_at", "updated_at"}
        indexes = {row[1] for row in db.execute("PRAGMA index_list(session_assignments)")}
        assert "idx_session_assignments_assignee" in indexes

    minimal = sqlite3.connect(tmp_path / "minimal.sqlite3")
    minimal.row_factory = sqlite3.Row
    minimal.executescript(
        """
        CREATE TABLE sessions (id TEXT PRIMARY KEY, candidate TEXT NOT NULL, role TEXT NOT NULL,
            policy TEXT NOT NULL, consent INTEGER NOT NULL, created_at TEXT NOT NULL, legacy TEXT);
        CREATE TABLE session_trash (session_id TEXT PRIMARY KEY REFERENCES sessions(id),
            trashed_at TEXT NOT NULL, operation_version TEXT NOT NULL);
        CREATE VIEW active_sessions AS
            SELECT s.rowid AS rowid, s.* FROM sessions s
            WHERE NOT EXISTS (SELECT 1 FROM session_trash t WHERE t.session_id=s.id);
        """
    )
    session_assignment.migrate(minimal)
    assert session_assignment._suggested_reviewers(minimal, "local-operator") == []
    minimal.close()


def test_put_get_delete_assignment_and_suggested_reviewers(client):
    sid = _create_session(client)
    init = client.get(f"/api/sessions/{sid}/assignment")
    assert init.status_code == 200
    assert init.json() == {"assignment": None, "suggested_reviewers": []}

    saved = client.put(
        f"/api/sessions/{sid}/assignment",
        json={"assignee_email": "  Lead.Reviewer@Example.COM ", "priority": "high", "due_at": "2026-11-25T14:30:00+02:00"},
    )
    assert saved.status_code == 200
    body = saved.json()["assignment"]
    assert body["session_id"] == sid
    assert body["assignee_email"] == "lead.reviewer@example.com"
    assert body["assigned_by"] == "local-operator"
    assert body["priority"] == "high"
    assert body["due_at"] == "2026-11-25T12:30:00+00:00"

    updated = client.put(
        f"/api/sessions/{sid}/assignment",
        json={"assignee_email": "second@example.com", "priority": "low", "due_at": None},
    )
    assert updated.status_code == 200
    assert updated.json()["assignment"]["assignee_email"] == "second@example.com"
    assert updated.json()["assignment"]["priority"] == "low"
    assert updated.json()["assignment"]["due_at"] is None

    aid = client.post(
        f"/api/sessions/{sid}/answers",
        json={"question": "Q1", "answer": "Answer text.", "references": []},
    ).json()["id"]
    with store.connection(write=True) as db:
        for i in range(30):
            db.execute(
                """INSERT INTO answer_review_events(
                       session_id, answer_id, role_id, reviewer_id, reviewer_email,
                       previous_disposition, disposition, created_at
                   ) VALUES (?,?,?,?,?,?,?,?)""",
                (sid, aid, None, f"rev-{i}", f"rev{i:02d}@example.com", "pending", "explained", store.timestamp()),
            )
    fetched = client.get(f"/api/sessions/{sid}/assignment").json()
    assert fetched["assignment"]["assignee_email"] == "second@example.com"
    assert len(fetched["suggested_reviewers"]) == 25
    assert "local-operator" not in fetched["suggested_reviewers"]

    cleared = client.delete(f"/api/sessions/{sid}/assignment")
    assert cleared.status_code == 200
    assert cleared.json() == {"cleared": True, "session_id": sid}
    assert client.get(f"/api/sessions/{sid}/assignment").json()["assignment"] is None


def test_assignment_404_and_422_validation(client):
    missing = str(uuid4())
    assert client.get(f"/api/sessions/{missing}/assignment").status_code == 404
    assert client.put(f"/api/sessions/{missing}/assignment", json={"assignee_email": "a@example.com"}).status_code == 404
    assert client.delete(f"/api/sessions/{missing}/assignment").status_code == 404

    sid = _create_session(client)
    for bad in (
        {"assignee_email": "not-an-email"},
        {"assignee_email": "alice@"},
        {"assignee_email": "alice\x00@example.com"},
        {"assignee_email": "alice@example.com", "priority": "urgent"},
        {"assignee_email": "alice@example.com", "due_at": "2026-11-25T10:00:00"},
        {"assignee_email": "alice@example.com", "due_at": 1700000000},
        {"assignee_email": "alice@example.com", "extra": "nope"},
    ):
        assert client.put(f"/api/sessions/{sid}/assignment", json=bad).status_code == 422

    client.post(f"/api/sessions/{sid}/trash").raise_for_status()
    assert client.get(f"/api/sessions/{sid}/assignment").status_code == 404
    assert client.put(f"/api/sessions/{sid}/assignment", json={"assignee_email": "a@example.com"}).status_code == 404
    assert client.delete(f"/api/sessions/{sid}/assignment").status_code == 404


def test_interviews_assignments_queue_filters_counts_and_ordering(client, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("TRIAL_DAYS", "7")
    client.post(
        "/api/integrations/access/signup",
        json={"email": "panelist@example.test", "password": "StrongPassphrase123!"},
    ).raise_for_status()

    s_me_high = _create_session(client, candidate="Ada High", role="Systems")
    s_other_high = _create_session(client, candidate="Grace Urgent", role="Security")
    s_low = _create_session(client, candidate="Linus Low", role="Kernel")
    s_unassigned = _create_session(client, candidate="Alan Unassigned", role="Algorithms")
    s_trashed = _create_session(client, candidate="Trashed Candidate", role="QA")

    ref_text = "Hydraulic pressure relief valve calibrated to four hundred kilopascals during load testing."
    client.post(
        f"/api/sessions/{s_me_high}/answers",
        json={"question": "Q1", "answer": ref_text, "references": [{"label": "Manual", "text": ref_text}]},
    ).raise_for_status()

    client.put(
        f"/api/sessions/{s_me_high}/assignment",
        json={"assignee_email": "panelist@example.test", "priority": "high", "due_at": "2026-11-26T09:00:00Z"},
    ).raise_for_status()
    client.put(
        f"/api/sessions/{s_other_high}/assignment",
        json={"assignee_email": "other@example.test", "priority": "high", "due_at": "2026-11-24T09:00:00Z"},
    ).raise_for_status()
    client.put(
        f"/api/sessions/{s_low}/assignment",
        json={"assignee_email": "panelist@example.test", "priority": "low"},
    ).raise_for_status()
    client.put(
        f"/api/sessions/{s_trashed}/assignment",
        json={"assignee_email": "panelist@example.test", "priority": "high"},
    ).raise_for_status()
    client.post(f"/api/sessions/{s_trashed}/trash").raise_for_status()

    all_q = client.get("/api/interviews/assignments").json()
    assert all_q["viewer_email"] == "panelist@example.test"
    assert all_q["counts"] == {"assigned_to_me": 2, "high_priority": 2, "unassigned": 1}
    assert [it["session_id"] for it in all_q["items"]] == [s_other_high, s_me_high, s_low, s_unassigned]
    expected_keys = {
        "session_id", "candidate", "role", "lifecycle", "review_count",
        "assignee_email", "assigned_by", "priority", "due_at", "updated_at",
    }
    assert set(all_q["items"][0].keys()) == expected_keys
    assert all_q["items"][1]["review_count"] == 1
    assert all_q["items"][1]["assigned_by"] == "panelist@example.test"

    me_q = client.get("/api/interviews/assignments", params={"assignee": "me"}).json()
    assert me_q["counts"] == {"assigned_to_me": 2, "high_priority": 2, "unassigned": 1}
    assert [it["session_id"] for it in me_q["items"]] == [s_me_high, s_low]

    high_me = client.get("/api/interviews/assignments", params={"assignee": "me", "priority": "high"}).json()
    assert [it["session_id"] for it in high_me["items"]] == [s_me_high]

    unassigned_q = client.get("/api/interviews/assignments", params={"assignee": "unassigned"}).json()
    assert [it["session_id"] for it in unassigned_q["items"]] == [s_unassigned]
    assert unassigned_q["items"][0]["assignee_email"] is None

    exact_q = client.get("/api/interviews/assignments", params={"assignee": "OTHER@example.test"}).json()
    assert [it["session_id"] for it in exact_q["items"]] == [s_other_high]

    limited = client.get("/api/interviews/assignments", params={"limit": 2}).json()
    assert len(limited["items"]) == 2
    assert client.get("/api/interviews/assignments", params={"priority": "urgent"}).status_code == 422


def test_trash_purge_cleans_assignment_even_without_fk_and_auth_gates_hold(client, monkeypatch):
    s1 = _create_session(client, candidate="Purge Me")
    s2 = _create_session(client, candidate="Keep Me")
    client.put(f"/api/sessions/{s1}/assignment", json={"assignee_email": "a@example.com", "priority": "high"}).raise_for_status()
    client.put(f"/api/sessions/{s2}/assignment", json={"assignee_email": "b@example.com"}).raise_for_status()
    marker = client.post(f"/api/sessions/{s1}/trash").json()

    orig_conn = store.connection

    @contextmanager
    def no_fk_conn(path=None, *, write=False):
        with orig_conn(path, write=write) as db:
            db.execute("PRAGMA foreign_keys=OFF")
            yield db

    # Verify trash.purge explicitly deletes session_assignments even with foreign_keys=OFF.
    with monkeypatch.context() as m:
        m.setattr(store, "connection", no_fk_conn)
        client.post(
            f"/api/trash/{s1}/purge",
            json={"operation_version": marker["operation_version"], "confirm_session_id": s1},
        ).raise_for_status()
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM session_assignments WHERE session_id=?", (s1,)).fetchone()[0] == 0
        assert db.execute("SELECT count(*) FROM session_assignments WHERE session_id=?", (s2,)).fetchone()[0] == 1

    assert client.put(f"/api/sessions/{s2}/assignment", json={"assignee_email": "c@example.com"}, headers={"X-InterviewCheck": "0"}).status_code == 403
    assert client.delete(f"/api/sessions/{s2}/assignment", headers={"X-InterviewCheck": "0"}).status_code == 403

    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    account_db.check_database()
    assert client.get(f"/api/sessions/{s2}/assignment").status_code == 401
    assert client.put(f"/api/sessions/{s2}/assignment", json={"assignee_email": "c@example.com"}).status_code == 401
    assert client.delete(f"/api/sessions/{s2}/assignment").status_code == 401
    assert client.get("/api/interviews/assignments").status_code == 401

    unentitled = _seed_user(email="free@example.test", role="user")
    hdr = {"Cookie": f"{access.COOKIE}={unentitled}"}
    assert client.get(f"/api/sessions/{s2}/assignment", headers=hdr).status_code == 402
    assert client.put(f"/api/sessions/{s2}/assignment", json={"assignee_email": "c@example.com"}, headers=hdr).status_code == 402
    assert client.delete(f"/api/sessions/{s2}/assignment", headers=hdr).status_code == 402
    assert client.get("/api/interviews/assignments", headers=hdr).status_code == 402

    with account_db.connection() as adb:
        assert adb.execute("PRAGMA user_version").fetchone()[0] == 8
    assert account_db.VERSION == 8
