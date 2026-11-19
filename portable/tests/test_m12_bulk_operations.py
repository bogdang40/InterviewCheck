"""Tests for M12-W2: bulk archive/restore/tag/export, feed tag filter, purge, and backup."""
import csv
from io import StringIO
import json
from uuid import uuid4

from fastapi import APIRouter, Depends, FastAPI
from fastapi.testclient import TestClient
import pytest

from api import bulk_operations, main, store
from api.access import require_entitlement
from api.local_boundary import LocalBoundary
from api.security_headers import SecurityHeadersMiddleware


def _build_app():
    if any(getattr(r, "path", "") == "/api/interviews/bulk/archive" for r in main.app.routes):
        return main.app
    test_app = FastAPI(lifespan=main.lifespan)
    test_app.add_middleware(LocalBoundary)
    test_app.add_middleware(SecurityHeadersMiddleware, static_dir=None)
    for exc_type, handler in main.app.exception_handlers.items():
        test_app.add_exception_handler(exc_type, handler)
    ws = APIRouter(prefix="/api", dependencies=[Depends(require_entitlement)])
    ws.include_router(bulk_operations.router)
    test_app.include_router(ws)
    test_app.include_router(main.workspace)
    test_app.include_router(main.integrations)
    return test_app


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "bulk.sqlite"))
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    with TestClient(_build_app(), base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def _new_session(client, candidate: str, role: str = "Systems Engineer", role_id: str | None = None) -> str:
    payload = {"candidate": candidate, "role": role, "policy": "Manuals permitted.", "consent": True}
    if role_id:
        payload["role_id"] = role_id
    res = client.post("/api/sessions", json=payload)
    res.raise_for_status()
    return res.json()["id"]


def test_bulk_archive_and_atomic_restore(client):
    s1 = _new_session(client, "Candidate One")
    s2 = _new_session(client, "Candidate Two")
    s3 = _new_session(client, "Candidate Three")

    # confirm_count mismatch -> 409 with zero sessions trashed.
    assert client.post("/api/interviews/bulk/archive", json={"session_ids": [s1, s2], "confirm_count": 1}).status_code == 409
    assert client.get("/api/trash").json()["total"] == 0

    # Missing session -> 404 with zero sessions trashed.
    assert client.post("/api/interviews/bulk/archive", json={"session_ids": [s1, str(uuid4())], "confirm_count": 2}).status_code == 404
    assert client.get("/api/trash").json()["total"] == 0

    # Pre-trash s1 so ON CONFLICT DO NOTHING preserves its existing operation_version.
    v1_orig = client.post(f"/api/sessions/{s1}/trash").json()["operation_version"]
    archived = client.post("/api/interviews/bulk/archive", json={"session_ids": [s1, s2, s3], "confirm_count": 3})
    assert archived.status_code == 200
    body = archived.json()
    assert body["archived"] == 3 and body["newly_archived"] == 2
    markers = {item["id"]: item["operation_version"] for item in client.get("/api/trash").json()["items"]}
    assert markers[s1] == v1_orig and len(markers) == 3

    # One stale operation_version aborts entire bulk restore with 409 and zero partial restores.
    stale_restore = client.post(
        "/api/interviews/bulk/restore",
        json={
            "items": [
                {"session_id": s1, "operation_version": markers[s1]},
                {"session_id": s2, "operation_version": str(uuid4())},
            ]
        },
    )
    assert stale_restore.status_code == 409
    assert client.get("/api/trash").json()["total"] == 3
    assert client.get(f"/api/sessions/{s1}").status_code == 404

    # Missing trashed item aborts restore with 404 and zero partial restores.
    assert client.post(
        "/api/interviews/bulk/restore",
        json={"items": [{"session_id": s1, "operation_version": markers[s1]}, {"session_id": str(uuid4()), "operation_version": str(uuid4())}]},
    ).status_code == 404
    assert client.get("/api/trash").json()["total"] == 3

    # Valid bulk restore restores all selected sessions.
    ok_restore = client.post(
        "/api/interviews/bulk/restore",
        json={"items": [{"session_id": sid, "operation_version": markers[sid]} for sid in (s1, s2, s3)]},
    )
    assert ok_restore.status_code == 200 and ok_restore.json()["restored"] == 3
    assert client.get("/api/trash").json()["total"] == 0
    assert client.get(f"/api/sessions/{s2}").status_code == 200


def test_bulk_tag_feed_filtering_and_atomicity(client):
    s1 = _new_session(client, "Alpha Candidate", "Backend")
    s2 = _new_session(client, "Beta Candidate", "Frontend")
    phrase = "Measure winding insulation resistance before powering the stator test rig."
    client.post(f"/api/sessions/{s1}/answers", json={"question": "Q1?", "answer": phrase, "references": [{"label": "Doc", "text": phrase}]}).raise_for_status()
    client.post(f"/api/sessions/{s1}/finish").raise_for_status()

    # Feed works cleanly even before bulk_operations.migrate / session_tags table exists.
    pre_feed = client.get("/api/interviews/feed").json()
    assert pre_feed["total"] == 2 and all(item["tags"] == [] for item in pre_feed["items"])
    assert client.get("/api/interviews/feed", params={"tag": "urgent"}).json()["filtered"] == 0

    res = client.post("/api/interviews/bulk/tag", json={"session_ids": [s1, s2], "add": ["urgent", "backend-team"]})
    assert res.status_code == 200 and res.json()["updated"] == 2

    all_items = {item["id"]: item for item in client.get("/api/interviews/feed").json()["items"]}
    assert all_items[s1]["tags"] == ["backend-team", "urgent"]
    assert client.get("/api/interviews/feed", params={"tag": "urgent"}).json()["filtered"] == 2
    assert [i["id"] for i in client.get("/api/interviews/feed", params={"tag": "urgent", "status": "finished", "review": "pending", "q": "Alpha"}).json()["items"]] == [s1]

    # Remove tag from s2 only.
    client.post("/api/interviews/bulk/tag", json={"session_ids": [s2], "remove": ["backend-team"]}).raise_for_status()
    assert [i["id"] for i in client.get("/api/interviews/feed", params={"tag": "backend-team"}).json()["items"]] == [s1]

    # Overflowing max 10 tags on s1 rolls back tag addition on s2 as well.
    client.post("/api/interviews/bulk/tag", json={"session_ids": [s1], "add": [f"t{i}" for i in range(8)]}).raise_for_status()
    overflow = client.post("/api/interviews/bulk/tag", json={"session_ids": [s2, s1], "add": ["overflow-tag"]})
    assert overflow.status_code == 422
    after_items = {item["id"]: item for item in client.get("/api/interviews/feed").json()["items"]}
    assert "overflow-tag" not in after_items[s2]["tags"]

    # Validation and trashed-session guards.
    for bad in (
        {"session_ids": [s1, s1], "add": ["x"]},
        {"session_ids": [s1], "add": ["x"], "remove": ["x"]},
        {"session_ids": [s1], "add": []},
        {"session_ids": [s1], "add": ["bad,tag"]},
        {"session_ids": [s1], "add": ["a" * 33]},
    ):
        assert client.post("/api/interviews/bulk/tag", json=bad).status_code == 422
    client.post(f"/api/sessions/{s2}/trash").raise_for_status()
    assert client.post("/api/interviews/bulk/tag", json={"session_ids": [s1, s2], "add": ["no-partial"]}).status_code == 404
    assert "no-partial" not in {i["id"]: i["tags"] for i in client.get("/api/interviews/feed").json()["items"]}[s1]


def test_bulk_export_csv_formula_neutralization_json_and_security_gates(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "sec.sqlite"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("TRIAL_DAYS", "7")
    for key in ("INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN", "INTERVIEWCHECK_SIGNUP_SECRET"):
        monkeypatch.delenv(key, raising=False)
    app_inst = _build_app()

    # Missing X-InterviewCheck CSRF header -> 403.
    with TestClient(app_inst, base_url="http://127.0.0.1") as raw:
        assert raw.post("/api/interviews/bulk/archive", json={"session_ids": [str(uuid4())], "confirm_count": 1}).status_code == 403

    # Unauthenticated request under embedded auth -> 401.
    with TestClient(app_inst, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as anon:
        for path, body in (
            ("/api/interviews/bulk/archive", {"session_ids": [str(uuid4())], "confirm_count": 1}),
            ("/api/interviews/bulk/restore", {"items": [{"session_id": str(uuid4()), "operation_version": str(uuid4())}]}),
            ("/api/interviews/bulk/tag", {"session_ids": [str(uuid4())], "add": ["x"]}),
            ("/api/interviews/bulk/export", {"session_ids": [str(uuid4())], "format": "json"}),
        ):
            assert anon.post(path, json=body).status_code == 401

        anon.post("/api/integrations/access/signup", json={"email": "reviewer@example.invalid", "password": "strong-password-123"}).raise_for_status()
        s1 = _new_session(anon, "=CMD|'/C calc'!A0", "+Role")
        s2 = _new_session(anon, "@Candidate", "-Role")
        anon.post(f"/api/sessions/{s1}/answers", json={"question": "=SUM(1,2)", "answer": "-evil", "references": []}).raise_for_status()
        a2 = anon.post(f"/api/sessions/{s2}/answers", json={"question": "Q?", "answer": "Ans", "references": []}).json()
        with store.connection(write=True) as db:
            db.execute("UPDATE answers SET note=? WHERE id=?", ("\t-tabbed", a2["id"]))
        anon.post("/api/interviews/bulk/tag", json={"session_ids": [s1, s2], "add": ["=tag", "safe"]}).raise_for_status()

        csv_res = anon.post("/api/interviews/bulk/export", json={"session_ids": [s1, s2], "format": "csv"})
        assert csv_res.status_code == 200
        assert "no-store" in csv_res.headers["cache-control"]
        assert csv_res.content.startswith(b"\xef\xbb\xbf")
        rows = {r["Session ID"]: r for r in csv.DictReader(StringIO(csv_res.content.decode("utf-8-sig")))}
        assert rows[s1]["Candidate"] == "'=CMD|'/C calc'!A0"
        assert rows[s1]["Role"] == "'+Role"
        assert rows[s1]["Question"] == "'=SUM(1,2)"
        assert rows[s1]["Answer"] == "'-evil"
        assert rows[s1]["Tags"] == "'=tag; safe"
        assert rows[s2]["Candidate"] == "'@Candidate" and rows[s2]["Role"] == "'-Role"
        assert rows[s2]["Interviewer note"] == "'\t-tabbed"

        json_res = anon.post("/api/interviews/bulk/export", json={"session_ids": [s1], "format": "json"})
        assert json_res.status_code == 200 and "no-store" in json_res.headers["cache-control"]
        payload = json_res.json()
        assert payload["count"] == 1 and payload["sessions"][0]["tags"] == ["=tag", "safe"]

        anon.post(f"/api/sessions/{s2}/trash").raise_for_status()
        assert anon.post("/api/interviews/bulk/export", json={"session_ids": [s1, s2], "format": "csv"}).status_code == 404


def test_trash_purge_cleans_tags_and_review_events(client):
    s1 = _new_session(client, "Purge Target")
    s2 = _new_session(client, "Keep Target")
    ans = client.post(f"/api/sessions/{s1}/answers", json={"question": "Q?", "answer": "A", "references": []}).json()
    client.patch(f"/api/sessions/{s1}/answers/{ans['id']}", json={"disposition": "explained", "note": "Verified"}).raise_for_status()
    client.post("/api/interviews/bulk/tag", json={"session_ids": [s1, s2], "add": ["keep-tag"]}).raise_for_status()

    version = client.post(f"/api/sessions/{s1}/trash").json()["operation_version"]
    assert client.post(f"/api/trash/{s1}/purge", json={"operation_version": version, "confirm_session_id": s1}).json() == {"purged": True}
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM session_tags WHERE session_id=?", (s1,)).fetchone()[0] == 0
        assert db.execute("SELECT count(*) FROM answer_review_events WHERE session_id=?", (s1,)).fetchone()[0] == 0
        assert db.execute("SELECT count(*) FROM session_tags WHERE session_id=?", (s2,)).fetchone()[0] == 1
        assert not db.execute("PRAGMA foreign_key_check").fetchall()


def test_backup_round_trip_and_legacy_v1_v2_compatibility(client, tmp_path, monkeypatch):
    role = client.post(
        "/api/roles",
        json={
            "name": "Principal Engineer",
            "questions": ["Q1?"],
            "rubric": [{"id": "c1", "criterion": "Depth", "weight": 50, "expected_signals": ["Tradeoffs"], "red_flags": []}],
            "change_note": "v1",
        },
    ).json()
    role_v2 = client.put(
        f"/api/roles/{role['id']}",
        json={"name": role["name"], "description": "Updated", "questions": ["Q1?", "Q2?"], "version": role["version"], "change_note": "v2"},
    ).json()
    sid = _new_session(client, "Backup Candidate", role_v2["name"], role["id"])
    ans = client.post(f"/api/sessions/{sid}/answers", json={"question": "Q1?", "answer": "Detailed answer.", "references": []}).json()
    client.patch(f"/api/sessions/{sid}/answers/{ans['id']}", json={"disposition": "explained", "note": "Good"}).raise_for_status()
    client.post("/api/interviews/bulk/tag", json={"session_ids": [sid], "add": ["calibrated", "finalist"]}).raise_for_status()

    raw = client.get("/api/backups/workspace").content
    target = tmp_path / "restored.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))

    plan = client.post("/api/backups/preview", content=raw).json()
    assert plan["roles"]["new"] == 1 and plan["sessions"]["new"] == 1
    client.post("/api/backups/restore", content=raw, headers={"X-Backup-Preview": plan["fingerprint"]}).raise_for_status()

    # Exact round-trip equality and identical re-preview.
    assert json.loads(client.get("/api/backups/workspace").content) == json.loads(raw)
    assert client.post("/api/backups/preview", content=raw).json()["sessions"]["identical"] == 1
    assert client.get(f"/api/roles/{role['id']}/versions").json()["current_version_number"] == 2
    assert client.get("/api/interviews/feed", params={"tag": "finalist"}).json()["filtered"] == 1
    assert client.get("/api/roles/analytics").json()["roles"][0]["explained_count"] == 1

    # Invalid review_events / role_versions rejected with 422.
    bad_ev = json.loads(raw)
    bad_ev["sessions"][0]["review_events"][0]["answer_id"] = str(uuid4())
    assert client.post("/api/backups/preview", json=bad_ev).status_code == 422

    # Legacy v1/v2 backup payloads lacking M12 fields still preview and restore cleanly.
    legacy_db = tmp_path / "legacy_v1_v2.sqlite"
    store.initialize(legacy_db)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(legacy_db))
    legacy_doc = {
        "format": "interviewcheck.workspace",
        "version": 2,
        "roles": [{"id": role["id"], "name": "Legacy", "description": "", "questions": ["Q?"], "policy": "", "permitted_sources": []}],
        "sessions": [{
            "id": sid, "candidate": "Legacy Cand", "role": "Legacy", "role_id": role["id"],
            "planned_questions": ["Q?"], "policy": "Strict", "permitted_sources": [],
            "consent": True, "created_at": "2026-11-01T10:00:00Z", "ended_at": None, "answers": [],
        }],
    }
    legacy_raw = json.dumps(legacy_doc).encode()
    l_plan = client.post("/api/backups/preview", content=legacy_raw).json()
    client.post("/api/backups/restore", content=legacy_raw, headers={"X-Backup-Preview": l_plan["fingerprint"]}).raise_for_status()
    assert client.post("/api/backups/preview", content=legacy_raw).json()["roles"]["identical"] == 1
