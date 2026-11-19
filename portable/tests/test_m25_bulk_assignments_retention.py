"""Tests for M25-W1 bulk session assignment, overdue triage, and retention cold-import fix."""
from datetime import datetime, timedelta, timezone
from pathlib import Path
import subprocess
import sys
from uuid import uuid4

from fastapi import APIRouter, Depends, FastAPI
from fastapi.exceptions import RequestValidationError
from fastapi.testclient import TestClient
import pytest

from api import access, account_db, main, model_admin, retention_policy, session_assignment, store
from api.local_boundary import LocalBoundary

PORTABLE_DIR = Path(__file__).resolve().parents[1]


def _build_app() -> FastAPI:
    test_app = FastAPI(lifespan=main.lifespan)
    test_app.add_middleware(LocalBoundary)
    test_app.add_exception_handler(RequestValidationError, main.invalid_input)
    ws = APIRouter(prefix="/api", dependencies=[Depends(access.require_entitlement)])
    ws.include_router(session_assignment.router)
    test_app.include_router(ws)
    test_app.include_router(retention_policy.router)
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


def _create_session(client: TestClient, *, candidate: str = "Ada Lovelace", role: str = "Systems") -> str:
    res = client.post(
        "/api/sessions",
        json={"candidate": candidate, "role": role, "policy": "No external help.", "consent": True},
    )
    res.raise_for_status()
    return res.json()["id"]


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


@pytest.mark.parametrize(
    "snippet",
    [
        "from api import alert_rules, store, main",
        "from api import retention_policy, model_admin, store, main",
        "import tests.test_m24_diagnostics_templates",
        "import tests.test_m23_alerts_calibration",
    ],
)
def test_cold_import_orders_have_no_circular_dependency(snippet: str):
    proc = subprocess.run(
        [sys.executable, "-c", snippet],
        cwd=str(PORTABLE_DIR),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, f"Import failed for {snippet!r}: {proc.stderr}"


def test_retention_lazy_admin_dependency_works_end_to_end(client, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    account_db.check_database()
    assert client.get("/api/admin/compliance/retention").status_code == 401
    user_tok = _seed_user(email="viewer@example.test", role="user")
    assert client.get("/api/admin/compliance/retention", headers={"Cookie": f"{access.COOKIE}={user_tok}"}).status_code == 403
    admin_tok = _seed_user(email="admin@example.test", role="admin")
    hdr = {"Cookie": f"{access.COOKIE}={admin_tok}", "X-InterviewCheck": "1"}
    got = client.get("/api/admin/compliance/retention", headers=hdr)
    assert got.status_code == 200
    assert got.json()["policy"]["anonymize_after_days"] == 90
    upd = client.put(
        "/api/admin/compliance/retention",
        headers=hdr,
        json={"anonymize_after_days": 60, "purge_trashed_after_days": 14, "preserve_scorecard_aggregates": True, "enabled": True},
    )
    assert upd.status_code == 200
    assert upd.json()["policy"]["anonymize_after_days"] == 60
    run = client.post("/api/admin/compliance/retention/run", headers=hdr, json={"dry_run": True})
    assert run.status_code == 200
    assert run.json()["dry_run"] is True


def test_bulk_assignment_assign_and_clear_round_trip(client):
    s1 = _create_session(client, candidate="Grace Hopper")
    s2 = _create_session(client, candidate="Barbara Liskov")
    assigned = client.post(
        "/api/interviews/assignments/bulk",
        json={
            "session_ids": [s1, s2],
            "action": "assign",
            "assignee_email": "  Lead.Ops@Example.COM ",
            "priority": "high",
            "due_at": "2026-12-01T14:00:00+02:00",
        },
    )
    assert assigned.status_code == 200
    body = assigned.json()
    assert body["action"] == "assign"
    assert body["updated"] == 2
    assert [item["session_id"] for item in body["assignments"]] == [s1, s2]
    assert body["assignments"][0]["assignee_email"] == "lead.ops@example.com"
    assert body["assignments"][0]["due_at"] == "2026-12-01T12:00:00+00:00"
    assert client.get(f"/api/sessions/{s1}/assignment").json()["assignment"]["priority"] == "high"
    assert client.get(f"/api/sessions/{s2}/assignment").json()["assignment"]["assignee_email"] == "lead.ops@example.com"

    cleared = client.post(
        "/api/interviews/assignments/bulk",
        json={"session_ids": [s1, s2], "action": "clear"},
    )
    assert cleared.status_code == 200
    assert cleared.json() == {"action": "clear", "updated": 2, "cleared_ids": [s1, s2]}
    assert client.get(f"/api/sessions/{s1}/assignment").json()["assignment"] is None
    assert client.get(f"/api/sessions/{s2}/assignment").json()["assignment"] is None


def test_bulk_assignment_atomic_404_rollback_on_missing_or_trashed(client):
    s1 = _create_session(client, candidate="Existing One")
    s2 = _create_session(client, candidate="Existing Two")
    s_trashed = _create_session(client, candidate="Trashed Session")
    client.post(f"/api/sessions/{s_trashed}/trash").raise_for_status()
    client.put(
        f"/api/sessions/{s1}/assignment",
        json={"assignee_email": "initial@example.test", "priority": "low"},
    ).raise_for_status()

    missing_res = client.post(
        "/api/interviews/assignments/bulk",
        json={
            "session_ids": [s1, s2, str(uuid4())],
            "action": "assign",
            "assignee_email": "overwrite@example.test",
            "priority": "high",
        },
    )
    assert missing_res.status_code == 404
    assert client.get(f"/api/sessions/{s1}/assignment").json()["assignment"]["assignee_email"] == "initial@example.test"
    assert client.get(f"/api/sessions/{s1}/assignment").json()["assignment"]["priority"] == "low"
    assert client.get(f"/api/sessions/{s2}/assignment").json()["assignment"] is None

    trashed_assign = client.post(
        "/api/interviews/assignments/bulk",
        json={"session_ids": [s1, s_trashed], "action": "assign", "assignee_email": "x@example.test"},
    )
    assert trashed_assign.status_code == 404
    trashed_clear = client.post(
        "/api/interviews/assignments/bulk",
        json={"session_ids": [s1, s_trashed], "action": "clear"},
    )
    assert trashed_clear.status_code == 404
    assert client.get(f"/api/sessions/{s1}/assignment").json()["assignment"]["assignee_email"] == "initial@example.test"


def test_bulk_assignment_422_validation_and_auth_csrf_gates(client, monkeypatch):
    s1 = _create_session(client, candidate="Validated Session")
    assert client.post("/api/interviews/assignments/bulk", json={"session_ids": [s1], "action": "clear"}, headers={"X-InterviewCheck": "0"}).status_code == 403

    bad_payloads = [
        {"session_ids": [], "action": "clear"},
        {"session_ids": [str(uuid4()) for _ in range(51)], "action": "clear"},
        {"session_ids": [s1, s1], "action": "clear"},
        {"session_ids": [s1], "action": "assign"},
        {"session_ids": [s1], "action": "assign", "assignee_email": "not-an-email"},
        {"session_ids": [s1], "action": "assign", "assignee_email": "alice@"},
        {"session_ids": [s1], "action": "assign", "assignee_email": "alice\x00@example.com"},
        {"session_ids": [s1], "action": "assign", "assignee_email": "a@example.com", "due_at": "2026-11-25T10:00:00"},
        {"session_ids": [s1], "action": "assign", "assignee_email": "a@example.com", "due_at": 1700000000},
        {"session_ids": [s1], "action": "assign", "assignee_email": "a@example.com", "extra": True},
    ]
    for payload in bad_payloads:
        assert client.post("/api/interviews/assignments/bulk", json=payload).status_code == 422
    assert client.get("/api/interviews/assignments", params={"due": "later"}).status_code == 422

    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    account_db.check_database()
    assert client.post("/api/interviews/assignments/bulk", json={"session_ids": [s1], "action": "clear"}).status_code == 401
    assert client.get("/api/interviews/assignments", params={"due": "overdue"}).status_code == 401
    unentitled = _seed_user(email="free@example.test", role="user")
    hdr = {"Cookie": f"{access.COOKIE}={unentitled}"}
    assert client.post("/api/interviews/assignments/bulk", json={"session_ids": [s1], "action": "clear"}, headers=hdr).status_code == 402
    assert client.get("/api/interviews/assignments", params={"due": "overdue"}, headers=hdr).status_code == 402
    with account_db.connection() as adb:
        assert adb.execute("PRAGMA user_version").fetchone()[0] == 8


def test_due_overdue_and_due_soon_filtering_and_counts(client):
    with store.connection(write=True) as db:
        db.execute("DROP TABLE IF EXISTS session_assignments")
    empty_q = client.get("/api/interviews/assignments", params={"due": "overdue"}).json()
    assert empty_q["due_counts"] == {"overdue": 0, "due_soon": 0}
    assert empty_q["items"] == []

    now = datetime.now(timezone.utc)
    s_overdue = _create_session(client, candidate="Overdue Candidate")
    s_soon = _create_session(client, candidate="Soon Candidate")
    s_later = _create_session(client, candidate="Later High Candidate")
    s_nodue = _create_session(client, candidate="No Due Candidate")
    _create_session(client, candidate="Unassigned Candidate")
    s_trashed = _create_session(client, candidate="Trashed Overdue")

    client.put(
        f"/api/sessions/{s_later}/assignment",
        json={"assignee_email": "rev@example.test", "priority": "high", "due_at": (now + timedelta(hours=72)).isoformat()},
    ).raise_for_status()
    client.put(
        f"/api/sessions/{s_overdue}/assignment",
        json={"assignee_email": "rev@example.test", "priority": "low", "due_at": (now - timedelta(hours=2)).isoformat()},
    ).raise_for_status()
    client.put(
        f"/api/sessions/{s_soon}/assignment",
        json={"assignee_email": "rev@example.test", "priority": "normal", "due_at": (now + timedelta(hours=12)).isoformat()},
    ).raise_for_status()
    client.put(
        f"/api/sessions/{s_nodue}/assignment",
        json={"assignee_email": "rev@example.test", "priority": "normal"},
    ).raise_for_status()
    client.put(
        f"/api/sessions/{s_trashed}/assignment",
        json={"assignee_email": "rev@example.test", "priority": "high", "due_at": (now - timedelta(hours=5)).isoformat()},
    ).raise_for_status()
    client.post(f"/api/sessions/{s_trashed}/trash").raise_for_status()

    all_q = client.get("/api/interviews/assignments").json()
    assert all_q["due_counts"] == {"overdue": 1, "due_soon": 1}
    assert all_q["counts"] == {"assigned_to_me": 0, "high_priority": 1, "unassigned": 1}

    overdue_q = client.get("/api/interviews/assignments", params={"due": "overdue", "limit": 1}).json()
    assert overdue_q["due_counts"] == {"overdue": 1, "due_soon": 1}
    assert [it["session_id"] for it in overdue_q["items"]] == [s_overdue]

    soon_q = client.get("/api/interviews/assignments", params={"due": "soon"}).json()
    assert [it["session_id"] for it in soon_q["items"]] == [s_soon]
