"""Interview lifecycle, purge races and visibility with temporary databases only."""

import asyncio
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier, Event
from unittest.mock import AsyncMock
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import ats_notes, store
from api.main import app

NAME = "Trash fixture name"
QUESTION = "Fixture question about rail inspection"
ANSWER = "We measured the ultrasonic response at the rail splice."
SESSION = {"candidate": NAME, "role": "Inspector", "policy": "Manuals permitted.", "consent": True}


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "temp.sqlite"))
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as c:
        yield c


def session(c):
    role = c.post("/api/roles", json={"name": "Inspector", "questions": [QUESTION]}).json()
    record = c.post("/api/sessions", json={**SESSION, "role_id": role["id"]}).json()
    return record["id"], role["id"]


def populate(c):
    sid, rid = session(c)
    base = "/api/sessions/" + sid
    answer = c.post(base + "/answers", json={"question": QUESTION, "answer": ANSWER}).json()
    draft = {"id": str(uuid4()), "question": "Partial", "answer": "Kept", "expected_revision": 0}
    c.put(base + "/draft", json=draft).raise_for_status()
    note_id = str(uuid4())
    with store.connection(write=True) as db:
        db.execute(
            "INSERT INTO note_exports VALUES(?,?,?,?,?,?,?,?)",
            (
                note_id,
                sid,
                "lever",
                "private-vendor-id",
                "Private recipient",
                "Note body",
                "draft",
                store.timestamp(),
            ),
        )
        db.execute("INSERT INTO transcript_imports VALUES(?,?,?,?)", (str(uuid4()), sid, "digest", "[]"))
    return sid, rid, answer, draft, note_id


def test_soft_remove_hides_all_access_and_restore_preserves_data(client):
    sid, rid, answer, draft, note_id = populate(client)
    path = "/api/sessions/" + sid
    before = client.get(path).json()
    marker = client.post(path + "/trash").json()
    version = marker["operation_version"]
    assert client.post(path + "/trash").json()["operation_version"] == version
    assert client.get("/api/trash").json()["items"] == [marker]
    assert set(marker) == {
        "id",
        "candidate",
        "role",
        "created_at",
        "trashed_at",
        "operation_version",
        "answer_count",
    }
    assert (
        not client.get("/api/sessions").json() and NAME not in client.get("/api/exports/interviews.csv").text
    )
    for suffix in ("", "/print", "/report", "/brief", "/draft", "/answers/" + answer["id"], "/ats"):
        response = client.get(path + suffix)
        assert response.status_code == 404 and NAME not in response.text and ANSWER not in response.text
    for suffix, body in (
        ("/preview", {"question": QUESTION, "answer": ANSWER}),
        ("/finish", {}),
        ("/reopen", {}),
        ("/draft/discard", {"id": draft["id"], "expected_revision": 1}),
        ("/draft/publish", {**draft, "expected_revision": 1}),
        ("/answers", {"question": QUESTION, "answer": ANSWER}),
        (f"/ats/drafts/{note_id}/send", {"confirmed": True, "note": "private note"}),
        ("/ats/recipients", {"provider": "lever", "email": "fake@example.test"}),
    ):
        assert client.post(path + suffix, json=body).status_code == 404, suffix
    assert (
        client.patch(
            path + "/answers/" + answer["id"], json={"disposition": "explained", "note": "lost"}
        ).status_code
        == 404
    )
    assert (
        client.put(
            path + "/answers/" + answer["id"], json={"question": QUESTION, "answer": "lost"}
        ).status_code
        == 404
    )
    assert (
        client.put(path + "/draft", json={**draft, "expected_revision": 1, "answer": "lost"}).status_code
        == 404
    )
    assert client.post("/api/sessions", json={**SESSION, "id": sid}).status_code == 404
    response = client.post(f"/api/trash/{sid}/restore", json={"operation_version": version})
    assert response.status_code == 200
    assert client.get(path).json() == before and client.get(path + "/draft").json()["answer"] == "Kept"
    assert client.get(path + "/ats").json()["history"][0]["id"] == note_id


def test_purge_requires_exact_version_and_removes_only_session_children(client):
    sid, rid, _, _, _ = populate(client)
    other = client.post("/api/sessions", json={**SESSION, "role_id": rid}).json()["id"]
    base = f"/api/trash/{sid}"
    confirm = {"operation_version": str(uuid4()), "confirm_session_id": sid}
    assert client.post(base + "/purge", json=confirm).status_code == 404
    marker = client.post(f"/api/sessions/{sid}/trash").json()
    old = {**confirm, "operation_version": marker["operation_version"]}
    assert client.post(base + "/purge", json={**old, "confirm_session_id": other}).status_code == 422
    client.post(base + "/restore", json={"operation_version": old["operation_version"]}).raise_for_status()
    fresh = client.post(f"/api/sessions/{sid}/trash").json()["operation_version"]
    assert fresh != old["operation_version"]
    assert client.post(base + "/purge", json=old).status_code == 409
    assert (
        client.post(base + "/restore", json={"operation_version": old["operation_version"]}).status_code
        == 409
    )
    assert client.post(
        base + "/purge", json={"operation_version": fresh, "confirm_session_id": sid}
    ).json() == {"purged": True}
    assert client.get("/api/trash").json()["total"] == 0
    assert client.get(f"/api/sessions/{other}").status_code == 200
    with store.connection() as db:
        for table in (
            "session_context",
            "session_drafts",
            "answers",
            "transcript_imports",
            "note_exports",
            "ats_access_versions",
            "session_trash",
        ):
            assert db.execute(f"SELECT count(*) FROM {table} WHERE session_id=?", (sid,)).fetchone()[0] == 0
        assert db.execute("SELECT count(*) FROM roles WHERE id=?", (rid,)).fetchone()[0] == 1
        assert not db.execute("PRAGMA foreign_key_check").fetchall()


def test_restore_and_purge_are_serialized(client):
    sid, _ = session(client)
    marker = client.post(f"/api/sessions/{sid}/trash").json()["operation_version"]
    gate = Barrier(2)

    def change(action):
        payload = {"operation_version": marker}
        if action == "purge":
            payload["confirm_session_id"] = sid
        gate.wait(timeout=5)
        return action, client.post(f"/api/trash/{sid}/{action}", json=payload).status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = dict(pool.map(change, ("restore", "purge")))
    assert sorted(results.values()) == [200, 404]
    assert client.get(f"/api/sessions/{sid}").status_code == (200 if results["restore"] == 200 else 404)


@pytest.mark.parametrize("purge", [False, True])
def test_late_ats_receipt_cannot_revive_or_disclose_hidden_session(client, monkeypatch, purge):
    sid, _, _, _, eid = populate(client)
    path = f"/api/sessions/{sid}"
    monkeypatch.setenv("LEVER_API_KEY", "fixture")
    entered, release = Event(), Event()

    async def slow(*args, **kwargs):
        entered.set()
        assert await asyncio.to_thread(release.wait, 5)

    monkeypatch.setattr(ats_notes, "send_private", slow)
    with ThreadPoolExecutor() as pool:
        result = pool.submit(
            client.post, f"{path}/ats/drafts/{eid}/send", json={"confirmed": True, "note": "Fixture"}
        )
        assert entered.wait(4)
        marker = client.post(path + "/trash").json()
        if purge:
            client.post(
                f"/api/trash/{sid}/purge",
                json={"operation_version": marker["operation_version"], "confirm_session_id": sid},
            ).raise_for_status()
        release.set()
        response = result.result(timeout=5)
    assert response.status_code == 404 and "private-vendor-id" not in response.text
    with store.connection() as db:
        row = db.execute("SELECT state FROM note_exports WHERE id=?", (eid,)).fetchone()
        assert (row[0] if row else None) == (None if purge else "attempted")


def test_recipient_lookup_started_before_move_and_restore_cannot_prepare(client, monkeypatch):
    sid, _ = session(client)
    monkeypatch.setenv("LEVER_API_KEY", "fixture")
    path = f"/api/sessions/{sid}"
    entered, release = Event(), Event()

    async def lookup(*args, **kwargs):
        entered.set()
        assert await asyncio.to_thread(release.wait, 5)
        return [{"candidate": "Private recipient", "target_id": "sensitive"}]

    monkeypatch.setattr(ats_notes.ats, "lookup", lookup)
    with ThreadPoolExecutor() as pool:
        response = pool.submit(
            client.post,
            path + "/ats/drafts",
            json={"provider": "lever", "email": "fake@example.test", "target_id": "sensitive"},
        )
        assert entered.wait(4)
        marker = client.post(path + "/trash").json()
        client.post(
            f"/api/trash/{sid}/restore", json={"operation_version": marker["operation_version"]}
        ).raise_for_status()
        release.set()
        reply = response.result(timeout=5)
    assert reply.status_code == 404 and "sensitive" not in reply.text
    assert client.get(path + "/ats").json()["history"] == []
