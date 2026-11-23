from collections import Counter
from contextlib import contextmanager
import json
from uuid import UUID, uuid4

import pytest

from api import store
from backup_requests import client, create_session, preview, restore


def add_child(client, sid, kind, child_id):
    payload = {"id": child_id, "question": "Which example?", "answer": "Synthetic response."}
    if kind == "draft":
        client.put(f"/api/sessions/{sid}/draft", json={**payload, "expected_revision": 0}).raise_for_status()
    else:
        client.post(f"/api/sessions/{sid}/answers", json=payload).raise_for_status()


def fresh_destination(tmp_path, monkeypatch):
    target = tmp_path / "destination.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))


@pytest.mark.parametrize(("incoming", "existing", "trashed"), [
    ("answer", "answer", False), ("answer", "draft", True), ("draft", "answer", True), ("draft", "draft", False),
])
def test_late_exchange_collision_preserves_owner_and_blocks_all_imports(client, tmp_path, monkeypatch, incoming, existing, trashed):
    sid = create_session(client)
    shared = str(uuid4())
    role = client.post("/api/roles", json={"name": "Independent kit"}).raise_for_status().json()
    add_child(client, sid, "answer", str(uuid4()))
    add_child(client, sid, incoming, shared)
    raw = client.get("/api/backups/workspace").raise_for_status().content
    fresh_destination(tmp_path, monkeypatch)
    first = preview(client, raw)
    assert first["sessions"]["new"] == first["roles"]["new"] == 1

    owner = create_session(client)
    add_child(client, owner, existing, shared)
    if trashed:
        client.post(f"/api/sessions/{owner}/trash").raise_for_status()
    conflict = client.post("/api/backups/preview?include_conflict_reasons=true", content=raw).raise_for_status()
    assert conflict.json()["conflicts"] == [{
        "kind": "sessions", "id": sid, "label": "Sample", "reasons": ["linked_id_in_use"],
    }]
    assert shared not in conflict.text and owner not in conflict.text
    assert restore(client, raw, first).status_code == 409
    assert client.get(f"/api/sessions/{sid}").status_code == client.get(f"/api/roles/{role['id']}").status_code == 404
    with store.connection() as db:
        table = "session_drafts" if existing == "draft" else "answers"
        assert db.execute(f"SELECT session_id FROM {table} WHERE id=?", (shared,)).fetchone()[0] == owner


def test_versions_collide_only_with_existing_version_ids(client, tmp_path, monkeypatch):
    sid = create_session(client)
    add_child(client, sid, "answer", str(uuid4()))
    role = client.post("/api/roles", json={"name": "Role kit"}).raise_for_status().json()
    client.put(f"/api/roles/{role['id']}", json={**role, "questions": ["New question?"]}).raise_for_status()
    doc = client.get("/api/backups/workspace").raise_for_status().json()
    fresh_destination(tmp_path, monkeypatch)
    foreign = create_session(client)
    note = client.post(f"/api/sessions/{foreign}/handoff-notes", json={"category": "observation", "body": "Local"}).raise_for_status().json()
    versions = doc["roles"][0]["versions"]
    assert len(versions) == 2
    # The same string in handoff notes, exchanges and role version history is valid.
    versions[0]["id"] = doc["sessions"][0]["answers"][0]["id"] = note["id"]
    raw = json.dumps(doc).encode()
    first = preview(client, raw)
    assert first["roles"]["new"] == first["sessions"]["new"] == 1 and first["conflicts"] == []
    owner = client.post("/api/roles", json={"name": "Different kit"}).raise_for_status().json()
    with store.connection(write=True) as db:
        db.execute("UPDATE role_versions SET id=? WHERE role_id=?", (versions[-1]["id"], owner["id"]))
    assert preview(client, raw)["roles"]["conflict"] == 1
    assert restore(client, raw, first).status_code == 409
    assert client.get(f"/api/sessions/{sid}").status_code == 404
    with store.connection() as db:
        assert db.execute("SELECT id FROM role_versions WHERE role_id=?", (owner["id"],)).fetchone()[0] == versions[-1]["id"]


def test_large_new_parents_use_one_collision_probe_each_and_empty_parents_use_none(client, tmp_path, monkeypatch):
    sid = create_session(client)
    add_child(client, sid, "answer", str(uuid4()))
    role = client.post("/api/roles", json={"name": "Synthetic kit"}).raise_for_status().json()
    client.put(f"/api/roles/{role['id']}", json={**role, "questions": ["Changed?"]}).raise_for_status()
    doc = client.get("/api/backups/workspace").raise_for_status().json()
    session = doc["sessions"][0]
    sample = session["answers"][0]
    session["answers"] = [{**sample, "id": str(UUID(int=i))} for i in range(1, 1102)]
    doc["sessions"].append({**session, "id": str(uuid4()), "answers": []})
    doc["roles"].append({**doc["roles"][0], "id": str(uuid4()), "version_number": 1, "versions": []})
    raw = json.dumps(doc).encode()
    fresh_destination(tmp_path, monkeypatch)
    probes = Counter()
    connection = store.connection

    @contextmanager
    def observed(*args, **kwargs):
        def count_probes(statement):
            sql = statement.lower()
            if "from answers where id=" in sql or "from session_drafts where id=" in sql:
                probes["exchanges"] += 1
            if "from role_versions where id=" in sql:
                probes["versions"] += 1

        with connection(*args, **kwargs) as db:
            db.set_trace_callback(count_probes)
            yield db

    monkeypatch.setattr(store, "connection", observed)
    for url in ("/api/backups/preview", "/api/backups/preview?include_conflict_reasons=true"):
        plan = client.post(url, content=raw).raise_for_status().json()
        assert plan["roles"]["new"] == plan["sessions"]["new"] == 2 and plan["conflicts"] == []
        assert probes == {"exchanges": 1, "versions": 1}
        probes.clear()
    # Pre-version stores skip that lookup and are left untouched during preview.
    with connection(write=True) as db:
        db.execute("DROP TABLE role_versions")
    assert preview(client, raw)["roles"]["new"] == 2 and probes == {"exchanges": 1}
    with connection() as db:
        assert db.execute("SELECT 1 FROM sqlite_master WHERE name='role_versions'").fetchone() is None
