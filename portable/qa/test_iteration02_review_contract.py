"""Independent checks of history privacy, recovery, and role file capacity."""

from contextlib import closing
from datetime import datetime, timezone
import sqlite3

from fastapi.testclient import TestClient
import httpx
import pytest


HEADERS = {"X-InterviewCheck": "1"}


def restore_backup(client, archive):
    preview = client.post("/api/backups/preview", content=archive).raise_for_status().json()
    client.post(
        "/api/backups/restore", content=archive, headers={"X-Backup-Preview": preview["fingerprint"]}
    ).raise_for_status()


def test_history_keeps_the_actor_and_time_of_each_saved_write(monkeypatch, tmp_path):
    from api import access
    from api.main import app

    first = "11111111-1111-4111-8111-111111111111"
    second = "22222222-2222-4222-8222-222222222222"
    email = "fixture-operator@example.test"
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "actors.sqlite"))
    monkeypatch.setenv("INTERVIEWCHECK_PUBLIC_ORIGIN", "https://review.example.test")
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://accounts.example.test")
    monkeypatch.setenv("INTERVIEWCHECK_OPERATOR_EMAIL", email)
    monkeypatch.setenv("INTERVIEWCHECK_OPERATOR_ID", first)
    verifications = []

    async def fake_service(path, *, token):
        assert path == "me"
        verifications.append(token)
        return {"user": {"id": token, "email": email}, "entitlement": {"active": True}}

    monkeypatch.setattr(access, "upstream", fake_service)
    headers = {**HEADERS, "X-Forwarded-Host": "review.example.test", "Origin": "https://review.example.test"}
    with TestClient(app, base_url="http://127.0.0.1:8000", headers=headers) as client:
        client.cookies.set(access.COOKIE, first)
        session = client.post("/api/sessions", json={
            "candidate": "Fixture Candidate", "role": "Fixture Role", "policy": "No assistance", "consent": True,
        }).raise_for_status().json()
        answers = "/api/sessions/" + session["id"] + "/answers"
        original = {"question": "What would you verify?", "answer": "First answer"}
        answer = client.post(answers, json=original).raise_for_status().json()
        path = answers + "/" + answer["id"]

        verifications.clear()
        start = datetime.now(timezone.utc)
        client.patch(path, json={"disposition": "explained", "note": "First note", "expected_revision": 1}).raise_for_status()
        end = datetime.now(timezone.utc)
        assert verifications == [first]
        earlier = client.get(path + "/history/2").raise_for_status().json()
        assert earlier["actor"] == {"kind": "account", "id": first}
        assert start <= datetime.fromisoformat(earlier["saved_at"]) <= end

        monkeypatch.setenv("INTERVIEWCHECK_OPERATOR_ID", second)
        client.cookies.set(access.COOKIE, second)
        verifications.clear()
        start = datetime.now(timezone.utc)
        client.put(path, json={**original, "answer": "Second answer", "expected_revision": 2}).raise_for_status()
        end = datetime.now(timezone.utc)
        assert verifications == [second]
        latest = client.get(path + "/history/3").raise_for_status().json()
        assert latest["actor"] == {"kind": "account", "id": second}
        assert start <= datetime.fromisoformat(latest["saved_at"]) <= end
        assert latest["snapshot"]["note"].endswith("First note")
        assert client.get(path + "/history/2").raise_for_status().json() == earlier


def test_history_is_private_and_sqlite_recovery_preserves_it(workspace_url, tmp_path, monkeypatch):
    from api.main import app

    old_answer = "Fixture earlier answer Q019"
    old_note = "Fixture earlier interviewer note R023"
    markers = [old_answer, old_note]
    with httpx.Client(base_url=workspace_url, headers=HEADERS, trust_env=False) as client:
        session = client.post("/api/sessions", json={
            "candidate": "Fixture Candidate", "role": "Fixture Role", "policy": "No assistance", "consent": True,
        }).raise_for_status().json()
        session_url = "/api/sessions/" + session["id"]
        answer = client.post(session_url + "/answers", json={
            "question": "What would you verify?", "answer": old_answer,
        }).raise_for_status().json()
        answer_url = session_url + "/answers/" + answer["id"]
        history = answer_url + "/history"
        client.patch(answer_url, json={
            "disposition": "explained", "note": old_note, "expected_revision": 1,
        }).raise_for_status()
        client.put(answer_url, json={
            "question": answer["question"], "answer": "Current verified answer", "expected_revision": 2,
        }).raise_for_status()
        client.patch(answer_url, json={
            "disposition": "explained", "note": "Current interviewer note", "expected_revision": 3,
        }).raise_for_status()

        first = client.get(history, params={"limit": 2}).raise_for_status()
        assert first.headers["cache-control"] == "no-store"
        page = first.json()
        assert [entry["revision"] for entry in page["entries"]] == [4, 3]
        assert all("snapshot" not in entry for entry in page["entries"])
        later = client.get(history, params={"before_revision": page["next_before_revision"], "limit": 2})
        assert [entry["revision"] for entry in later.raise_for_status().json()["entries"]] == [2, 1]
        old = client.get(history + "/2").raise_for_status().json()
        assert old["snapshot"]["answer"] == old_answer and old["snapshot"]["note"] == old_note
        assert old["kind"] == "review_update" and old["actor"] == {"kind": "local_operator"}

        selection = {"excerpt_ids": [answer["id"]], "note_ids": [answer["id"]]}
        preview = client.post(session_url + "/brief", json=selection).raise_for_status().json()
        brief = client.post(session_url + "/brief/download", json={
            **selection, "preview_sha256": preview["preview_sha256"],
        }).raise_for_status()
        assert "Current interviewer note" in brief.text
        archive = client.get("/api/backups/workspace").raise_for_status()
        assert archive.json()["version"] == 5
        for response in (client.get(answer_url), client.get(session_url), client.get(session_url + "/report"),
                         client.get(session_url + "/brief"), brief, archive):
            assert all(marker not in response.raise_for_status().text for marker in markers)
        restore_backup(client, archive.content)
        assert client.get(history + "/2").raise_for_status().json() == old

    db_path = tmp_path / "workspace.sqlite"
    sqlite_copy = tmp_path / "restored-sqlite.sqlite"
    with closing(sqlite3.connect(db_path)) as source, closing(sqlite3.connect(sqlite_copy)) as destination:
        source.backup(destination)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(sqlite_copy))
    with TestClient(app, base_url="http://127.0.0.1:8765", headers=HEADERS) as restored:
        assert restored.get(history + "/2").raise_for_status().json() == old

    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "restored-json.sqlite"))
    with TestClient(app, base_url="http://127.0.0.1:8765", headers=HEADERS) as restored:
        restore_backup(restored, archive.content)
        assert restored.get(history + "/2").status_code == 404
        entry, = restored.get(history).raise_for_status().json()["entries"]
        assert entry == {"revision": 4, "kind": "baseline", "saved_at": None, "actor": None}


@pytest.mark.parametrize(("character", "export_bytes"), [("😀", 2_103_140), ("\x01", 3_154_380)])
def test_role_file_round_trips_at_field_limits(monkeypatch, tmp_path, character, export_bytes):
    from api.main import app

    payload = {
        "name": character * 180,
        "description": character * 24000,
        "questions": [character * 4000] * 100,
        "policy": character * 4000,
        "permitted_sources": [{"label": character * 180, "text": character * 12000}] * 8,
    }
    base_url = "http://127.0.0.1:8765"
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "role-source.sqlite"))
    monkeypatch.delenv("INTERVIEWCHECK_PUBLIC_ORIGIN", raising=False)
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_MODE", raising=False)
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_URL", raising=False)
    with TestClient(app, base_url=base_url, headers=HEADERS) as source:
        role = source.post("/api/roles", json=payload).raise_for_status().json()
        export = source.get("/api/roles/" + role["id"] + "/export").raise_for_status()
        assert export_bytes <= len(export.content) <= 4 * 1024 * 1024
        assert export.json() == {
            "format": "interviewcheck.role-kit", "version": 2, "role": {**payload, "id": role["id"], "rubric": []},
        }

    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "role-destination.sqlite"))
    with TestClient(app, base_url=base_url, headers=HEADERS) as destination:
        headers = {"Content-Type": "application/json"}
        destination.post("/api/roles/import/preview", content=export.content, headers=headers).raise_for_status()
        destination.post("/api/roles/import", content=export.content, headers=headers).raise_for_status()
        saved = destination.get("/api/roles/" + role["id"]).raise_for_status().json()
        assert saved == role


def test_larger_body_allowance_is_limited_to_role_paths(workspace_url):
    headers = {**HEADERS, "Content-Type": "application/json"}
    between_limits = b"{}" + b" " * (2 * 1024 * 1024 - 1)
    over_role_limit = b"{}" + b" " * (4 * 1024 * 1024 - 1)
    with httpx.Client(base_url=workspace_url, headers=headers, trust_env=False) as client:
        assert client.post("/api/sessions", content=between_limits).status_code == 413
        assert client.post("/api/roles", content=between_limits).status_code == 422
        assert client.post("/api/roles", content=over_role_limit).status_code == 413
        assert client.post("/api/roles/import/preview", content=over_role_limit).status_code == 413
