"""Two saved revisions must be compared as recorded, including repeated values and ordering."""
from contextlib import closing
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
                                 "occurrences": [{"text": "A", "before": 2, "after": 1}], "reordered": False}
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
