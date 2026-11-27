"""Two saved revisions must be compared as recorded, including repeated values and ordering."""
from contextlib import closing
from copy import deepcopy
import json
import sqlite3
from uuid import uuid4

import pytest

from api import role_kits, role_versions, store
from api.models import RoleInput
from backup_requests import client


def create(client, fields):
    return client.post("/api/roles", json=fields).raise_for_status().json()


def update(client, role, fields):
    return client.put("/api/roles/" + role["id"], json={**fields, "version": role["version"]}).raise_for_status().json()


def detail(client, role, source, target=None):
    params = {} if target is None else {"compare_to": target}
    return client.get(f"/api/roles/{role['id']}/versions/{source}", params=params)


def test_historical_pair_in_both_directions_and_default_live(client):
    first = {"name": "Original title", "description": "Original scope", "policy": "Handbook",
             "questions": ["A", "B", "A"], "permitted_sources": [{"label": "Sheet", "text": "First text"}],
             "rubric": [{"id": "quality", "criterion": "Quality", "weight": 2, "expected_signals": ["First signal"],
                         "red_flags": ["First flag"]}, {"id": "testing", "criterion": "Testing", "weight": 1}]}
    one = create(client, first)
    second = {"name": "New title", "description": "Revised scope", "policy": "Manual", "questions": ["B", "A"],
              "permitted_sources": [{"label": "Sheet", "text": "Second text"}],
              "rubric": [one["rubric"][1], {"id": "quality", "criterion": "Evidence quality", "weight": 5,
                                           "expected_signals": ["Second signal", "Last signal"], "red_flags": []}]}
    two = update(client, one, second)
    three = update(client, two, {**second, "questions": ["Only in live"], "name": "Latest title"})
    pair = detail(client, three, 1, 2).raise_for_status().json()
    diff = pair["diff"]
    assert (pair["version"]["version_number"], pair["version"]["version"]) == (1, one["version"])
    assert (pair["current_version_number"], pair["current_version"]) == (3, three["version"])
    assert (diff["against_version_number"], diff["against_version"]) == (2, two["version"])
    assert diff["changed_fields"] == ["name", "description", "policy", "questions", "permitted_sources", "rubric"]
    for field in diff["changed_fields"]:
        assert diff["changes"][field] == {"version": one[field], "live": two[field]}
    assert diff["questions"] == {"added": [], "removed": ["A"],
                                 "occurrences": [{"text": "A", "before": 2, "after": 1}], "reordered": False, "reordered_common": None}
    assert diff["rubric"]["reordered"] and diff["rubric"]["added"] == diff["rubric"]["removed"] == []
    assert diff["rubric"]["modified"] == [{"id": "quality", "version": one["rubric"][0], "live": two["rubric"][1]}]
    assert diff["permitted_sources"]["added"] == diff["permitted_sources"]["removed"] == []
    assert diff["permitted_sources"]["added_entries"] == two["permitted_sources"]
    assert diff["permitted_sources"]["removed_entries"] == one["permitted_sources"]
    reverse = detail(client, three, 2, 1).raise_for_status().json()["diff"]
    assert reverse["against_version"] == one["version"]
    assert reverse["questions"]["added"] == ["A"] and reverse["questions"]["removed"] == []
    live = detail(client, three, 1).raise_for_status().json()["diff"]
    assert live["against_version"] == three["version"] and live["against_version_number"] == 3
    assert live["changes"]["questions"]["live"] == ["Only in live"]
    same = detail(client, three, 2, 2).raise_for_status().json()["diff"]
    assert same["against_version"] == two["version"] and not same["has_changes"] and same["changes"] == {}
    assert same["questions"]["occurrences"] == [] and not same["rubric"]["reordered"]


def test_reorders_and_duplicate_material_labels_preserve_full_order(client):
    entries = [{"label": "Guide", "text": text} for text in ("First", "Second", "Second")]
    first = create(client, {"name": "Ops", "questions": ["A", "B", "A"], "permitted_sources": entries})
    second = update(client, first, {"name": "Ops", "questions": ["A", "A", "B"],
                                    "permitted_sources": [entries[1], entries[0], entries[2]]})
    permutation = detail(client, second, 1, 2).raise_for_status().json()["diff"]
    for field in ("questions", "permitted_sources"):
        assert permutation[field]["reordered"] and permutation[field]["added"] == permutation[field]["removed"] == []
        assert permutation["changes"][field] == {"version": first[field], "live": second[field]}
    assert permutation["permitted_sources"]["added_entries"] == permutation["permitted_sources"]["removed_entries"] == []
    third = update(client, second, {"name": "Ops", "questions": ["A"] * 5,
                                    "permitted_sources": [entries[0], {"label": "Guide", "text": "Third"}]})
    edited = detail(client, third, 1, 3).raise_for_status().json()["diff"]
    assert edited["questions"]["added"] == ["A"] * 3 and edited["questions"]["removed"] == ["B"]
    assert edited["permitted_sources"]["removed_entries"] == [entries[1], entries[2]]
    assert edited["permitted_sources"]["added_entries"] == [{"label": "Guide", "text": "Third"}]
    assert edited["permitted_sources"]["removed"] == ["Guide"]


def test_missing_saved_revisions_never_substitute_another_role_or_live_content(client):
    role = create(client, {"name": "First"})
    other = create(client, {"name": "Other"})
    update(client, other, {"name": "Private other title"})
    for source, target in ((1, 2), (2, 1), (8, 8)):
        missing = detail(client, role, source, target)
        assert missing.status_code == 404 and "Private other title" not in missing.text
    current = update(client, role, {"name": "First revision 2"})
    with store.connection(write=True) as db:
        db.execute("DELETE FROM role_versions WHERE role_id=? AND version_number=2", (role["id"],))
    assert detail(client, current, 1, 2).status_code == 404
    assert detail(client, current, 2, 1).status_code == 404
    assert detail(client, current, 1).json()["diff"]["against_version"] == current["version"]
    with store.connection(write=True) as db:
        db.execute("DELETE FROM role_versions WHERE role_id=?", (role["id"],))
    fallback = detail(client, current, 2, 2).raise_for_status().json()
    assert fallback["version"]["version"] == fallback["diff"]["against_version"] == current["version"]
    assert detail(client, current, 2, 1).status_code == 404
    # Even a damaged history database with an orphan snapshot cannot expose a deleted role.
    with closing(sqlite3.connect(store.db_path())) as db, db:
        db.execute("PRAGMA foreign_keys=OFF")
        db.execute("DELETE FROM roles WHERE id=?", (other["id"],))
    assert detail(client, other, 1, 2).status_code == 404
    assert detail(client, {"id": str(uuid4())}, 1, 1).status_code == 404


@pytest.mark.parametrize("value", [-1, 0, 2**63, "invalid"])
def test_compare_to_query_bounds(client, value):
    role = create(client, {"name": "Bounds"})
    assert detail(client, role, 1, value).status_code == 422


def test_pair_uses_one_sqlite_snapshot_during_a_concurrent_role_update(client, monkeypatch):
    role = create(client, {"name": "Concurrent"})
    lookup = role_versions._saved_version
    seen = False

    def interleave(db, live, number):
        nonlocal seen
        if not seen:
            seen = True
            # The request already read the live role. Append a revision from a separate connection.
            with store.connection(write=True) as writer:
                role_kits.update_role(writer, role["id"], RoleInput(name="Later", version=role["version"]))
        return lookup(db, live, number)

    monkeypatch.setattr(role_versions, "_saved_version", interleave)
    assert detail(client, role, 1, 2).status_code == 404
    after = detail(client, role, 1, 2).raise_for_status().json()
    assert after["current_version_number"] == after["diff"]["against_version_number"] == 2
    assert after["diff"]["changes"]["name"] == {"version": "Concurrent", "live": "Later"}


def test_unique_relative_order_survives_mixed_edits_without_identifying_duplicates(client):
    first = create(client, {"name": "Order", "questions": ["A", "X", "B", "X", "C", "Removed"]})
    second = update(client, first, {"name": "Order", "questions": ["B", "X", "New", "A", "C"]})
    questions = detail(client, second, 1, 2).raise_for_status().json()["diff"]["questions"]
    assert not questions["reordered"]
    assert questions["reordered_common"] == {"before": ["A", "B", "C"], "after": ["B", "A", "C"]}
    assert questions["removed"] == ["X", "Removed"] and questions["added"] == ["New"]
    third = update(client, second, {"name": "Order", "questions": ["New 2", "A", "X", "X", "C"]})
    still = detail(client, third, 1, 3).json()["diff"]["questions"]
    assert not still["reordered"] and still["reordered_common"] is None


def test_targeted_reads_and_rollback_refuse_corrupt_history_without_revealing_its_fields(client):
    one = create(client, {"name": "History", "questions": ["A"]})
    two = update(client, one, {"name": "History", "questions": ["B"]})
    three = update(client, two, {"name": "History", "questions": ["C"]})
    rid = one["id"]
    with store.connection(write=True) as db:
        db.execute("UPDATE role_versions SET policy='private corrupt policy' WHERE role_id=? AND version_number=2", (rid,))
    for source, target in ((1, 2), (2, 1), (2, 2)):
        response = detail(client, three, source, target)
        assert response.status_code == 409 and "private corrupt policy" not in response.text
    assert detail(client, three, 1, 3).status_code == 200
    before = client.get("/api/roles/" + rid).json()
    assert client.post(f"/api/roles/{rid}/versions/2/restore", json={"expected_version": three["version"]}).status_code == 409
    assert client.get("/api/roles/" + rid).json() == before
    # The row is internally self consistent but contradicts the live meaning of the same revision.
    fake_hash = role_kits.content_version({**three, "name": "inconsistent"})
    with store.connection(write=True) as db:
        db.execute("UPDATE role_versions SET name=?,content_sha256=? WHERE role_id=? AND version_number=3",
                   ("inconsistent", fake_hash, rid))
    assert detail(client, three, 1, 3).status_code == 409
    assert detail(client, three, 1).json()["diff"]["against_version"] == three["version"]


def import_role_file(client, doc, tmp_path, monkeypatch):
    dest = tmp_path / "recovery.sqlite"
    store.initialize(dest)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(dest))
    raw = json.dumps(doc).encode()
    preview = client.post("/api/backups/preview", content=raw).raise_for_status().json()
    assert preview["roles"]["new"] == 1
    client.post("/api/backups/restore", content=raw,
                headers={"X-Backup-Preview": preview["fingerprint"]}).raise_for_status()


def test_imported_adjacent_wide_revision_numbers_and_a_gap_keep_exact_identifiers(client, tmp_path, monkeypatch):
    first = create(client, {"name": "Wide", "questions": ["1"]})
    second = update(client, first, {"name": "Wide", "questions": ["2"]})
    third = update(client, second, {"name": "Wide", "questions": ["3"]})
    rid = first["id"]
    doc = client.get("/api/backups/workspace").raise_for_status().json()
    role, = doc["roles"]
    numbers = [2**53, 2**53 + 1, 2**53 + 3]
    role["version_number"] = numbers[-1]
    for row, version_number in zip(role["versions"], numbers, strict=True):
        row["version_number"] = version_number
    import_role_file(client, doc, tmp_path, monkeypatch)

    listing = client.get(f"/api/roles/{rid}/versions").json()
    assert [(v["version_number"], v["version_number_text"]) for v in listing["versions"]] == [
        (n, str(n)) for n in reversed(numbers)]
    assert listing["current_version_number_text"] == str(numbers[-1])
    pair = detail(client, third, numbers[0], numbers[1]).raise_for_status().json()
    assert pair["version"]["version_number_text"] == str(numbers[0]) and pair["version"]["version"] == first["version"]
    assert pair["current_version_number_text"] == str(numbers[-1])
    assert pair["diff"]["against_version_number_text"] == str(numbers[1])
    assert pair["diff"]["against_version"] == second["version"]
    assert detail(client, third, numbers[0], 2**53 + 2).status_code == 404
    assert "version_number_text" not in client.get("/api/backups/workspace").text
    live = client.get("/api/roles/" + rid).json()
    assert live["version_number_text"] == str(numbers[-1])
    # Browser round trip: JSON.parse/JSON.stringify rounds this numeric field to 9007199254740996.
    rounded = int(float(numbers[-1]))
    edit = client.put("/api/roles/" + rid, json={**live, "version_number": rounded, "name": "Exact edit"})
    assert edit.raise_for_status().json()["version_number_text"] == str(numbers[-1] + 1)
    rolled = client.post(f"/api/roles/{rid}/versions/{numbers[1]}/restore",
                         json={"expected_version": edit.json()["version"]}).raise_for_status().json()
    assert rolled["restored_from_version_text"] == str(numbers[1])
    assert rolled["questions"] == second["questions"]


def test_maximum_revision_returns_conflict_without_creating_a_history_entry(client, tmp_path, monkeypatch):
    initial = create(client, {"name": "Last revision"})
    doc = client.get("/api/backups/workspace").raise_for_status().json()
    role, = doc["roles"]
    role["version_number"] = 2**63 - 1
    role["versions"] = []  # A valid older file can have no journal.
    import_role_file(client, doc, tmp_path, monkeypatch)
    rid = initial["id"]
    live = client.get("/api/roles/" + rid).json()
    max_text = "9223372036854775807"
    assert live["version_number_text"] == max_text
    before = client.get("/api/backups/workspace").content
    edit = client.put("/api/roles/" + rid, json={**live, "name": "Unwritten", "version_number": 9223372036854776000})
    rollback = client.post(f"/api/roles/{rid}/versions/{max_text}/restore", json={"expected_version": live["version"]})
    for result in (edit, rollback):
        assert result.status_code == 409 and "maximum revision" in result.json()["detail"]
    assert client.get("/api/backups/workspace").content == before
    for bad in ("01", "1e2", "9223372036854775808", "٣", 2):
        assert client.put("/api/roles/" + rid, json={**live, "version_number_text": bad}).status_code == 422
    assert client.put("/api/roles/" + rid, json={**live, "version_number": 100}).status_code == 422


def test_import_rejects_contradictory_role_journal_without_blocking_valid_partial_history(client, tmp_path, monkeypatch):
    one = create(client, {"name": "Archive", "questions": ["Old"]})
    update(client, one, {"name": "Archive", "questions": ["Current"]})
    good = client.get("/api/backups/workspace").raise_for_status().json()
    broken = deepcopy(good)
    broken["roles"][0]["versions"][0]["description"] = "hidden changed field"
    altered_live = deepcopy(good)
    altered_live["roles"][0]["name"] = "contradicting live row"
    wrong_parent = deepcopy(good)
    wrong_parent["roles"][0]["id"] = str(uuid4())
    future = deepcopy(good)
    future["roles"][0]["versions"][0]["version_number"] = 9
    for bad in (broken, altered_live, wrong_parent, future):
        response = client.post("/api/backups/preview", json=bad)
        assert response.status_code == 422 and "hidden changed field" not in response.text
    good["roles"][0]["versions"].pop()
    import_role_file(client, good, tmp_path, monkeypatch)
    assert detail(client, one, 1).status_code == 200 and detail(client, one, 1, 2).status_code == 404
