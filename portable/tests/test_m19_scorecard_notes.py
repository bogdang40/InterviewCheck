"""Tests for M19-W1 per-session rubric scorecards and panel handoff notes."""
import sqlite3
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import session_scorecard, store
from api.main import app


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
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def _create_role(client, *, name="Staff Engineer", rubric=None):
    payload = {
        "name": name,
        "description": "Architecture and execution",
        "policy": "No external assistance.",
        "questions": ["Describe WAL recovery."],
    }
    if rubric is not None:
        payload["rubric"] = rubric
    res = client.post("/api/roles", json=payload)
    res.raise_for_status()
    return res.json()


def _create_session(client, *, candidate="Ada Lovelace", role="Staff Engineer", role_id=None):
    payload = {
        "candidate": candidate,
        "role": role,
        "policy": "No external assistance.",
        "consent": True,
    }
    if role_id is not None:
        payload["role_id"] = role_id
    res = client.post("/api/sessions", json=payload)
    res.raise_for_status()
    return res.json()


def test_schema_migration_and_pre_m12_roles_defensive_check(tmp_path):
    db_file = tmp_path / "legacy.sqlite3"
    conn = sqlite3.connect(db_file)
    conn.row_factory = sqlite3.Row
    conn.executescript(
        """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, candidate TEXT NOT NULL, role TEXT NOT NULL,
            policy TEXT NOT NULL, consent INTEGER NOT NULL, created_at TEXT NOT NULL, legacy TEXT
        );
        CREATE TABLE session_trash (
            session_id TEXT PRIMARY KEY REFERENCES sessions(id),
            trashed_at TEXT NOT NULL, operation_version TEXT NOT NULL
        );
        CREATE VIEW active_sessions AS
            SELECT s.rowid AS rowid, s.* FROM sessions s
            WHERE NOT EXISTS (SELECT 1 FROM session_trash t WHERE t.session_id=s.id);
        CREATE TABLE roles (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT NOT NULL,
            questions TEXT NOT NULL, legacy TEXT
        );
        CREATE TABLE session_context (
            session_id TEXT PRIMARY KEY REFERENCES sessions(id),
            role_id TEXT REFERENCES roles(id),
            questions TEXT NOT NULL DEFAULT '[]', ended_at TEXT,
            permitted_sources TEXT NOT NULL DEFAULT '[]'
        );
        CREATE TABLE answers (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id),
            question TEXT NOT NULL, answer TEXT NOT NULL, refs TEXT NOT NULL,
            result TEXT NOT NULL, status TEXT NOT NULL,
            disposition TEXT NOT NULL DEFAULT 'pending', note TEXT NOT NULL DEFAULT ''
        );
        """
    )
    sid = str(uuid4())
    rid = str(uuid4())
    conn.execute("INSERT INTO roles VALUES (?,?,?,?,NULL)", (rid, "Legacy Role", "", "[]"))
    conn.execute(
        "INSERT INTO sessions VALUES (?,?,?,?,1,?,NULL)",
        (sid, "Grace", "Legacy Role", "Closed", "2026-11-19T00:00:00Z"),
    )
    conn.execute("INSERT INTO session_context(session_id, role_id) VALUES (?,?)", (sid, rid))
    session_scorecard.migrate(conn)
    indexes = {row[1] for row in conn.execute("PRAGMA index_list(session_handoff_notes)")}
    assert "idx_handoff_notes_session" in indexes
    state = session_scorecard._load_scorecard_state(conn, sid)
    assert state["items"] == []
    assert state["weighted_score_pct"] is None
    assert state["handoff_notes"] == []
    conn.close()


def test_scorecard_merges_role_rubric_saves_atomically_and_computes_weighted_pct(client):
    role = _create_role(
        client,
        rubric=[
            {"id": "sys-design", "criterion": "System Design", "weight": 3},
            {"id": "comm", "criterion": "Communication", "weight": 1},
        ],
    )
    sid = _create_session(client, role=role["name"], role_id=role["id"])["id"]

    initial = client.get(f"/api/sessions/{sid}/scorecard")
    assert initial.status_code == 200
    body = initial.json()
    assert body["weighted_score_pct"] is None
    assert body["handoff_notes"] == []
    assert [(item["criterion_id"], item["weight"], item["rating"]) for item in body["items"]] == [
        ("sys-design", 3, None),
        ("comm", 1, None),
    ]

    saved = client.put(
        f"/api/sessions/{sid}/scorecard",
        json={
            "items": [
                {
                    "criterion_id": "sys-design",
                    "criterion_label": "System Design",
                    "weight": 3,
                    "rating": 5,
                    "rationale": "Clear\x00 WAL\x07 model.\nCovered failover.",
                },
                {
                    "criterion_id": "adhoc-sec",
                    "criterion_label": "Security\x1b Posture",
                    "weight": 1,
                    "rating": 1,
                    "rationale": "Missed threat model.",
                },
            ]
        },
    )
    assert saved.status_code == 200
    sbody = saved.json()
    # Weighted: (5*3 + 1*1) / ((3+1)*5) * 100 = 16 / 20 * 100 = 80.0
    assert sbody["weighted_score_pct"] == 80.0
    by_id = {item["criterion_id"]: item for item in sbody["items"]}
    assert by_id["sys-design"]["rationale"] == "Clear WAL model.\nCovered failover."
    assert by_id["sys-design"]["updated_by"] == "local-operator"
    assert by_id["comm"]["rating"] is None
    assert by_id["adhoc-sec"]["criterion_label"] == "Security Posture"

    reloaded = client.get(f"/api/sessions/{sid}/scorecard").json()
    assert reloaded["weighted_score_pct"] == 80.0
    assert [it["criterion_id"] for it in reloaded["items"]] == ["sys-design", "comm", "adhoc-sec"]

    cleared = client.put(f"/api/sessions/{sid}/scorecard", json={"items": []})
    assert cleared.status_code == 200
    assert cleared.json()["weighted_score_pct"] is None
    assert [it["rating"] for it in cleared.json()["items"]] == [None, None]


def test_scorecard_validation_limits_and_control_char_rejection(client):
    sid = _create_session(client)["id"]
    too_many = [
        {"criterion_id": f"c-{i}", "criterion_label": f"Crit {i}", "weight": 1, "rating": 3, "rationale": ""}
        for i in range(26)
    ]
    assert client.put(f"/api/sessions/{sid}/scorecard", json={"items": too_many}).status_code == 422

    bad_payloads = [
        {"items": [{"criterion_id": "c1", "criterion_label": "A", "weight": 1, "rating": 0, "rationale": ""}]},
        {"items": [{"criterion_id": "c1", "criterion_label": "A", "weight": 1, "rating": 6, "rationale": ""}]},
        {"items": [{"criterion_id": "c1", "criterion_label": "A", "weight": 1, "rating": True, "rationale": ""}]},
        {"items": [{"criterion_id": "c1", "criterion_label": "A", "weight": 0, "rating": 3, "rationale": ""}]},
        {"items": [{"criterion_id": "c1", "criterion_label": "A", "weight": 101, "rating": 3, "rationale": ""}]},
        {"items": [{"criterion_id": "c1", "criterion_label": "A", "weight": 1, "rating": 3, "rationale": "x" * 2001}]},
        {"items": [{"criterion_id": "\x00\x07", "criterion_label": "A", "weight": 1, "rating": 3, "rationale": ""}]},
        {"items": [
            {"criterion_id": "dup", "criterion_label": "A", "weight": 1, "rating": 3, "rationale": ""},
            {"criterion_id": "dup", "criterion_label": "B", "weight": 1, "rating": 4, "rationale": ""},
        ]},
        {"items": [], "extra": 1},
    ]
    for bad in bad_payloads:
        assert client.put(f"/api/sessions/{sid}/scorecard", json=bad).status_code == 422


def test_handoff_notes_lifecycle_validation_and_session_isolation(client):
    s1 = _create_session(client, candidate="Ada")["id"]
    s2 = _create_session(client, candidate="Grace")["id"]

    created_ids = []
    for cat in ("observation", "follow_up", "decision", "concern"):
        res = client.post(
            f"/api/sessions/{s1}/handoff-notes",
            json={"category": cat, "body": f"  Note\x00 for {cat}\x07  "},
        )
        assert res.status_code == 201
        note = res.json()
        assert note["category"] == cat
        assert note["body"] == f"Note for {cat}"
        assert note["author_email"] == "local-operator"
        created_ids.append(note["id"])

    sc = client.get(f"/api/sessions/{s1}/scorecard").json()
    assert [n["id"] for n in sc["handoff_notes"]] == list(reversed(created_ids))

    for bad in (
        {"category": "other", "body": "Valid"},
        {"category": "observation", "body": "   \x00\x01  "},
        {"category": "concern", "body": "x" * 2001},
    ):
        assert client.post(f"/api/sessions/{s1}/handoff-notes", json=bad).status_code == 422

    # Wrong session or missing note ID returns 404 without deleting the note.
    assert client.delete(f"/api/sessions/{s2}/handoff-notes/{created_ids[0]}").status_code == 404
    assert client.delete(f"/api/sessions/{s1}/handoff-notes/{uuid4()}").status_code == 404

    del_res = client.delete(f"/api/sessions/{s1}/handoff-notes/{created_ids[0]}")
    assert del_res.status_code == 200
    assert del_res.json() == {"deleted": True, "id": created_ids[0]}
    remaining = [n["id"] for n in client.get(f"/api/sessions/{s1}/scorecard").json()["handoff_notes"]]
    assert created_ids[0] not in remaining and len(remaining) == 3


def test_trashed_404_and_purge_deletes_scorecards_and_notes(client):
    s1 = _create_session(client, candidate="One")["id"]
    s2 = _create_session(client, candidate="Two")["id"]

    for sid in (s1, s2):
        client.put(
            f"/api/sessions/{sid}/scorecard",
            json={"items": [{"criterion_id": "c1", "criterion_label": "Depth", "weight": 2, "rating": 4, "rationale": "Solid"}]},
        ).raise_for_status()
        client.post(
            f"/api/sessions/{sid}/handoff-notes",
            json={"category": "decision", "body": "Advance to panel."},
        ).raise_for_status()

    missing = str(uuid4())
    assert client.get(f"/api/sessions/{missing}/scorecard").status_code == 404
    assert client.put(f"/api/sessions/{missing}/scorecard", json={"items": []}).status_code == 404
    assert client.post(f"/api/sessions/{missing}/handoff-notes", json={"category": "observation", "body": "Hi"}).status_code == 404

    marker = client.post(f"/api/sessions/{s1}/trash").json()
    assert client.get(f"/api/sessions/{s1}/scorecard").status_code == 404
    assert client.put(f"/api/sessions/{s1}/scorecard", json={"items": []}).status_code == 404
    assert client.post(f"/api/sessions/{s1}/handoff-notes", json={"category": "observation", "body": "Hi"}).status_code == 404
    n1 = client.post(f"/api/sessions/{s2}/handoff-notes", json={"category": "observation", "body": "Keep"}).json()["id"]
    assert client.delete(f"/api/sessions/{s1}/handoff-notes/{n1}").status_code == 404

    client.post(
        f"/api/trash/{s1}/purge",
        json={"operation_version": marker["operation_version"], "confirm_session_id": s1},
    ).raise_for_status()

    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM session_scorecards WHERE session_id=?", (s1,)).fetchone()[0] == 0
        assert db.execute("SELECT count(*) FROM session_handoff_notes WHERE session_id=?", (s1,)).fetchone()[0] == 0
        assert db.execute("SELECT count(*) FROM session_scorecards WHERE session_id=?", (s2,)).fetchone()[0] == 1
        assert db.execute("SELECT count(*) FROM session_handoff_notes WHERE session_id=?", (s2,)).fetchone()[0] == 2
        assert not db.execute("PRAGMA foreign_key_check").fetchall()


def test_entitlement_csrf_and_embedded_actor_attribution(client, monkeypatch):
    sid = _create_session(client)["id"]

    assert client.put(f"/api/sessions/{sid}/scorecard", json={"items": []}, headers={"X-InterviewCheck": "0"}).status_code == 403
    assert client.post(
        f"/api/sessions/{sid}/handoff-notes",
        json={"category": "observation", "body": "Blocked"},
        headers={"X-InterviewCheck": "0"},
    ).status_code == 403
    assert client.delete(f"/api/sessions/{sid}/handoff-notes/{uuid4()}", headers={"X-InterviewCheck": "0"}).status_code == 403

    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "http://127.0.0.1:8787")
    assert client.get(f"/api/sessions/{sid}/scorecard").status_code == 401
    assert client.put(f"/api/sessions/{sid}/scorecard", json={"items": []}).status_code == 401
    assert client.post(f"/api/sessions/{sid}/handoff-notes", json={"category": "observation", "body": "Unauth"}).status_code == 401
    assert client.delete(f"/api/sessions/{sid}/handoff-notes/{uuid4()}").status_code == 401

    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_URL", raising=False)
    monkeypatch.delenv("INTERVIEWCHECK_SIGNUP_SECRET", raising=False)
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("TRIAL_DAYS", "7")
    client.post(
        "/api/integrations/access/signup",
        json={"email": "panelist@example.test", "password": "StrongPassphrase123!"},
    ).raise_for_status()

    saved = client.put(
        f"/api/sessions/{sid}/scorecard",
        json={"items": [{"criterion_id": "c1", "criterion_label": "Correctness", "weight": 1, "rating": 5, "rationale": "Great"}]},
    )
    assert saved.status_code == 200
    assert saved.json()["items"][0]["updated_by"] == "panelist@example.test"

    note = client.post(
        f"/api/sessions/{sid}/handoff-notes",
        json={"category": "follow_up", "body": "Ask concurrency follow-up."},
    )
    assert note.status_code == 201
    assert note.json()["author_email"] == "panelist@example.test"
