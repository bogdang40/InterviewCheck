"""An interview keeps its grading criteria and provenance across role changes and file recovery."""
from copy import deepcopy
from hashlib import sha256
import json
from uuid import uuid4

from api import store
from backup_requests import client, preview, restore


FIRST = {"id": "design", "criterion": "Design", "weight": 2,
         "expected_signals": ["Explains the rollback."], "red_flags": ["No verification step."]}
SECOND = {"id": "test", "criterion": "Testing", "weight": 4, "expected_signals": [], "red_flags": []}


def role_with(client, criteria):
    return client.post("/api/roles", json={"name": "Engineer", "policy": "Manual", "rubric": criteria}).raise_for_status().json()


def setup(client, template, **changes):
    body = {"id": str(uuid4()), "candidate": "Synthetic", "role": "Engineer", "policy": "Manual", "consent": True}
    if template:
        body.update(role_id=template["id"], role_version=template["version"])
    body.update(changes)
    client.post("/api/sessions", json=body).raise_for_status()
    return body


def card(client, sid):
    return client.get(f"/api/sessions/{sid}/scorecard").raise_for_status().json()


def test_role_change_and_replay_keep_original_criteria_and_grade(client):
    role = role_with(client, [FIRST])
    body = setup(client, role)
    sid = body["id"]
    initial = card(client, sid)
    assert initial["rubric_snapshot"] == {"role_id": role["id"], "version_number": 1,
                                          "role_content_sha256": role["version"], "criteria": [FIRST]}
    updated = client.put("/api/roles/" + role["id"], json={**role, "rubric": [SECOND]}).raise_for_status().json()
    next_sid = setup(client, updated)["id"]
    assert card(client, next_sid)["rubric_snapshot"]["criteria"] == [SECOND]
    assert card(client, next_sid)["rubric_snapshot"]["version_number"] == 2
    client.post("/api/sessions", json=body).raise_for_status()
    assert client.post("/api/sessions", json={**body, "role_version": updated["version"]}).status_code == 409
    assert card(client, sid) == initial
    # Manual role names can match existing templates only if the caller omitted role_id.
    assert card(client, setup(client, None, role_id=None)["id"])["rubric_snapshot"]["role_id"] is None
    assert card(client, setup(client, None)["id"])["rubric_snapshot"]["role_id"] == role["id"]
    grade = {"criterion_id": "design", "criterion_label": "Design", "weight": 2, "rating": 4, "rationale": "Independent example."}
    saved = client.put(f"/api/sessions/{sid}/scorecard", json={"items": [grade], "expected_version": initial["version"]})
    assert saved.raise_for_status().json()["weighted_score_pct"] == 80
    assert client.put(f"/api/sessions/{sid}/scorecard", json={"items": [], "expected_version": initial["version"]}).status_code == 409


def test_empty_rubric_remains_empty_and_detached_snapshot_survives_backup(client, tmp_path, monkeypatch):
    role = role_with(client, [])
    sid = setup(client, role)["id"]
    client.put("/api/roles/" + role["id"], json={**role, "rubric": [SECOND]}).raise_for_status()
    original = card(client, sid)
    assert original["items"] == [] and original["rubric_snapshot"]["criteria"] == []
    # The role foreign key is protected. Simulate a database with a detached template.
    with store.connection(write=True) as db:
        db.execute("UPDATE session_context SET role_id=NULL WHERE session_id=?", (sid,))
        db.execute("DELETE FROM roles WHERE id=?", (role["id"],))
    assert card(client, sid) == original
    client.post(f"/api/sessions/{sid}/trash").raise_for_status()
    raw = client.get("/api/backups/workspace", params={"session_id": sid}).raise_for_status().content
    workspace = client.get("/api/backups/workspace").raise_for_status().json()
    assert workspace == json.loads(raw)
    assert workspace["roles"] == [] and workspace["sessions"][0]["rubric_snapshot"] == original["rubric_snapshot"]
    target = tmp_path / "roundtrip.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
    restore(client, raw, preview(client, raw)).raise_for_status()
    assert client.get(f"/api/sessions/{sid}/scorecard").status_code == 404
    entry = next(row for row in client.get("/api/trash").json()["items"] if row["id"] == sid)
    client.post(f"/api/trash/{sid}/restore", json={"operation_version": entry["operation_version"]}).raise_for_status()
    assert card(client, sid) == original


def test_v5_replay_preserves_snapshot_and_new_legacy_import_has_unknown_origin(client, tmp_path, monkeypatch):
    role = role_with(client, [FIRST])
    sid = setup(client, role)["id"]
    doc = client.get("/api/backups/workspace").raise_for_status().json()
    del doc["sessions"][0]["deferred_questions"]
    del doc["sessions"][0]["privacy"]
    original = doc["sessions"][0].pop("rubric_snapshot")
    doc["version"] = 5
    old = json.dumps(doc).encode()
    plan = preview(client, old)
    assert plan["sessions"]["identical"] == 1
    restore(client, old, plan).raise_for_status()
    assert card(client, sid)["rubric_snapshot"] == original
    target = tmp_path / "legacy.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
    restore(client, old, preview(client, old)).raise_for_status()
    assert card(client, sid)["rubric_snapshot"] is None
    client.put("/api/roles/" + role["id"], json={**role, "rubric": [SECOND]}).raise_for_status()
    assert [row["criterion_id"] for row in card(client, sid)["items"]] == ["test"]
    latest = client.get("/api/backups/workspace").json()
    assert latest["version"] == 7 and latest["sessions"][0]["rubric_snapshot"] is None


def test_v6_conflicts_and_invalid_sources_never_replace_saved_rubric(client):
    role = role_with(client, [FIRST])
    sid = setup(client, role)["id"]
    original = client.get("/api/backups/workspace").raise_for_status().json()
    changed = deepcopy(original)
    changed["sessions"][0]["rubric_snapshot"] = None
    plan = client.post("/api/backups/preview?include_conflict_reasons=true", json=changed).raise_for_status().json()
    assert plan["conflicts"][0]["reasons"] == ["scorecard_items"]
    assert restore(client, json.dumps(changed).encode(), plan).status_code == 409
    assert card(client, sid)["rubric_snapshot"]["criteria"] == [FIRST]
    for malformed in ({"role_id": str(uuid4())}, {"version_number": 0}, {"criteria": [FIRST, FIRST]},
                      {"role_content_sha256": "invalid"}, {"criteria": [{"id": "private"}]}):
        invalid = deepcopy(original)
        invalid["sessions"][0]["rubric_snapshot"].update(malformed)
        result = client.post("/api/backups/preview", json=invalid)
        assert result.status_code == 422 and "private" not in result.text
    del changed["sessions"][0]["rubric_snapshot"]
    assert client.post("/api/backups/preview", json=changed).status_code == 422
    del original["sessions"][0]["deferred_questions"]
    original["version"] = 5
    assert client.post("/api/backups/preview", json=original).status_code == 422

def test_contradictory_archived_rubric_is_rejected_on_empty_workspace(client, tmp_path, monkeypatch):
    role = role_with(client, [FIRST])
    sid = setup(client, role)["id"]
    old = client.get("/api/backups/workspace").raise_for_status().json()
    client.put("/api/roles/" + role["id"], json={**role, "rubric": [SECOND]}).raise_for_status()
    newer = client.get("/api/backups/workspace").raise_for_status().json()
    assert newer["roles"][0]["version_number"] == 2
    assert newer["sessions"][0]["rubric_snapshot"]["version_number"] == 1
    target = tmp_path / "empty.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
    # Both the current role and older immutable versions can supply the original definition.
    for base in (old, newer):
        assert preview(client, json.dumps(base).encode())["sessions"]["new"] == 1
        for edit in ({"criteria": [SECOND]}, {"role_content_sha256": "9" * 64}):
            bad = deepcopy(base)
            bad["sessions"][0]["rubric_snapshot"].update(edit)
            raw = json.dumps(bad).encode()
            assert client.post("/api/backups/preview", content=raw).status_code == 422
            assert restore(client, raw, {"fingerprint": sha256(raw).hexdigest()}).status_code == 422
            assert client.get("/api/sessions").json() == [] and client.get("/api/roles").json() == []
    # A historical source cannot claim an unrelated digest even when the session repeats it.
    invalid = deepcopy(newer)
    first = next(v for v in invalid["roles"][0]["versions"] if v["version_number"] == 1)
    first["content_sha256"] = invalid["sessions"][0]["rubric_snapshot"]["role_content_sha256"] = "9" * 64
    assert client.post("/api/backups/preview", json=invalid).status_code == 422
    raw = json.dumps(newer).encode()
    restore(client, raw, preview(client, raw)).raise_for_status()
    assert card(client, sid)["rubric_snapshot"]["criteria"] == [FIRST]


def test_detached_restore_replays_only_the_original_explicit_role_and_digest(client, tmp_path, monkeypatch):
    role = role_with(client, [FIRST])
    request = setup(client, role)
    sid = request["id"]
    with store.connection(write=True) as db:
        db.execute("UPDATE session_context SET role_id=NULL WHERE session_id=?", (sid,))
        db.execute("DELETE FROM roles WHERE id=?", (role["id"],))
    raw = client.get("/api/backups/workspace").raise_for_status().content
    target = tmp_path / "detached.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
    restore(client, raw, preview(client, raw)).raise_for_status()
    original = card(client, sid)
    assert client.post("/api/sessions", json=request).raise_for_status().json()["id"] == sid
    for replacement in ({"role_id": str(uuid4())}, {"role_version": "0" * 64}, {"role_id": None, "role_version": None}):
        assert client.post("/api/sessions", json={**request, **replacement}).status_code == 409
    assert card(client, sid) == original
    assert client.get("/api/roles").json() == [] and len(client.get("/api/sessions").json()) == 1


def test_linked_future_rubric_is_invalid_but_detached_and_older_sources_remain_valid(client, tmp_path, monkeypatch):
    role = role_with(client, [FIRST])
    sid = setup(client, role)["id"]
    client.put("/api/roles/" + role["id"], json={**role, "rubric": [SECOND]}).raise_for_status()
    original = client.get("/api/backups/workspace").raise_for_status().json()
    role_record, = original["roles"]
    role_record["versions"] = [v for v in role_record["versions"] if v["version_number"] == 2]
    assert role_record["version_number"] == 2 and original["sessions"][0]["rubric_snapshot"]["version_number"] == 1

    def fresh(name):
        path = tmp_path / name
        store.initialize(path)
        monkeypatch.setenv("INTERVIEWCHECK_DB", str(path))

    fresh("linked.sqlite")
    future = deepcopy(original)
    future["sessions"][0]["rubric_snapshot"]["version_number"] = 3
    raw = json.dumps(future).encode()
    assert client.post("/api/backups/preview", content=raw).status_code == 422
    assert restore(client, raw, {"fingerprint": sha256(raw).hexdigest()}).status_code == 422
    assert client.get("/api/roles").json() == [] and client.get("/api/sessions").json() == []

    # The source revision may be older than the available journal.
    raw = json.dumps(original).encode()
    restore(client, raw, preview(client, raw)).raise_for_status()
    assert card(client, sid)["rubric_snapshot"] == original["sessions"][0]["rubric_snapshot"]

    # A detached interview has no live role authority, even if the file also carries a role of the same ID.
    fresh("detached-future.sqlite")
    future["sessions"][0]["role_id"] = None
    raw = json.dumps(future).encode()
    restore(client, raw, preview(client, raw)).raise_for_status()
    assert card(client, sid)["rubric_snapshot"] == future["sessions"][0]["rubric_snapshot"]
