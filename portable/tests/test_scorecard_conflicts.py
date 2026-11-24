"""Scorecard revisions protect concurrent reviewers and retain criterion attribution."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import sqlite3
from threading import Barrier

from api import access, store
from backup_requests import client, create_session


def score(criterion, rating, rationale=""):
    return {"criterion_id": criterion, "criterion_label": criterion.title(), "rating": rating,
            "weight": 1, "rationale": rationale}


def test_stale_scorecard_rejected_and_handoff_notes_are_independent(client):
    sid = create_session(client)
    route = f"/api/sessions/{sid}/scorecard"
    first = client.get(route).raise_for_status().json()
    other = client.get(f"/api/sessions/{create_session(client)}/scorecard").raise_for_status().json()
    payload = {"items": [score("design", 4, "Private assessment")], "expected_version": first["version"]}
    assert other["version"] != first["version"]
    assert client.put(route, json={**payload, "expected_version": other["version"]}).status_code == 409
    saved = client.put(route, json=payload).raise_for_status().json()
    assert saved["version"] != first["version"]
    stale = client.put(route, json={"items": [], "expected_version": first["version"]})
    assert stale.status_code == 409 and stale.headers["X-InterviewCheck-Conflict"] == "scorecard-version"
    assert "Private assessment" not in stale.text
    assert client.get(route).raise_for_status().json() == saved
    note = client.post(f"/api/sessions/{sid}/handoff-notes", json={"category": "follow_up", "body": "Ask for detail."})
    note.raise_for_status()
    after_note = client.get(route).raise_for_status().json()
    assert after_note["version"] == saved["version"]
    cleared = client.put(route, json={"items": [], "expected_version": saved["version"]}).raise_for_status().json()
    assert cleared["items"] == [] and cleared["handoff_notes"] == [note.json()]
    assert client.put(route, json={"items": [], "expected_version": "invalid"}).status_code == 422


def test_scores_preserve_unchanged_reviewer_and_timestamp(client, monkeypatch):
    actor = "first@example.test"

    async def reviewer(request):
        return (actor, actor)

    monkeypatch.setattr(access, "optional_actor", reviewer)
    route = f"/api/sessions/{create_session(client)}/scorecard"
    design = score("design", 4, "Synthetic first review")
    first = client.put(route, json={"items": [design]}).raise_for_status().json()
    actor = "second@example.test"
    with closing(sqlite3.connect(store.db_path())) as observer:
        before = observer.execute("PRAGMA data_version").fetchone()[0]
        same = client.put(route, json={"items": [design], "expected_version": first["version"]}).raise_for_status().json()
        assert observer.execute("PRAGMA data_version").fetchone()[0] == before
    assert same == first
    second = client.put(route, json={"items": [score("testing", 3), design],
                                     "expected_version": same["version"]}).raise_for_status().json()
    assert second["items"][0]["updated_by"] == actor
    assert second["items"][1] == first["items"][0]
    assert second["version"] != first["version"]


def test_role_edit_invalidates_open_scorecard(client):
    rubric = [{"id": "design", "criterion": "Design", "weight": 2}]
    template = {"name": "Engineer", "policy": "Manual", "rubric": rubric}
    role = client.post("/api/roles", json=template).raise_for_status().json()
    session = client.post("/api/sessions", json={"candidate": "Fixture", "role_id": role["id"],
                          "role": role["name"], "policy": "Manual", "consent": True}).raise_for_status().json()
    route = f"/api/sessions/{session['id']}/scorecard"
    before = client.get(route).raise_for_status().json()
    rubric.append({"id": "testing", "criterion": "Testing", "weight": 3})
    client.put(f"/api/roles/{role['id']}", json=template).raise_for_status()
    assert client.put(route, json={"items": [score("design", 4)], "expected_version": before["version"]}).status_code == 409
    after = client.get(route).raise_for_status().json()
    assert after["version"] != before["version"] and all(item["rating"] is None for item in after["items"])


def test_only_one_concurrent_scorecard_using_same_revision_commits(client):
    route = f"/api/sessions/{create_session(client)}/scorecard"
    token = client.get(route).raise_for_status().json()["version"]
    barrier = Barrier(2)

    def save(criterion):
        barrier.wait(timeout=5)
        return client.put(route, json={"items": [score(criterion, 4)], "expected_version": token}).status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        statuses = list(pool.map(save, ("design", "testing")))
    assert sorted(statuses) == [200, 409]
    assert len(client.get(route).raise_for_status().json()["items"]) == 1
