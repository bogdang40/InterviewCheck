"""Guarded reviewers cannot replace newer assignments or partly update a selection."""
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier

import pytest

from api import store
from backup_requests import client, create_session


def path(sid):
    return f"/api/sessions/{sid}/assignment"


def read(client, sid):
    return client.get(path(sid), params={"include_version": "true"}).raise_for_status().json()


def assign(client, sid, email, version=None):
    payload = {"assignee_email": email, "priority": "high", "due_at": "2030-03-10T09:15:00.123456Z"}
    if version is not None:
        payload["expected_version"] = version
    return client.put(path(sid), json=payload)


def test_queue_and_editor_share_scoped_assignment_versions(client):
    first, second = create_session(client), create_session(client)
    empty = read(client, first)
    assert empty["assignment"] is None and empty["version"] != read(client, second)["version"]
    saved = assign(client, first, "one@example.test", empty["version"]).raise_for_status().json()
    assert saved["version"] != empty["version"]
    assert read(client, first)["version"] == saved["version"]
    page = client.get("/api/interviews/assignments", params={"include_versions": "true"}).raise_for_status().json()
    for row in page["items"]:
        assert row["assignment_version"] == read(client, row["session_id"])["version"]
    other = assign(client, first, "two@example.test", saved["version"]).raise_for_status().json()
    rejected = client.delete(path(first), params={"expected_version": saved["version"]})
    assert rejected.status_code == 409
    assert rejected.headers["X-InterviewCheck-Conflict"] == "assignment-version"
    assert rejected.json()["detail"]["session_ids"] == [first]
    assert "example.test" not in rejected.text
    assert assign(client, first, "stale@example.test", saved["version"]).status_code == 409
    assert read(client, first)["assignment"] == other["assignment"]
    cleared = client.delete(path(first), params={"expected_version": other["version"]}).raise_for_status().json()
    assert cleared["version"] == empty["version"]
    assert client.delete(path(first), params={"expected_version": "invalid"}).status_code == 422
    assert client.delete(path(first)).json() == {"cleared": True, "session_id": first}


@pytest.mark.parametrize("action", ["assign", "clear"])
def test_stale_bulk_selection_has_no_partial_effect(client, action):
    ids = [create_session(client) for _ in range(3)]
    versions = {sid: read(client, sid)["version"] for sid in ids}
    changed = assign(client, ids[1], "updated@example.test", versions[ids[1]]).raise_for_status().json()
    body = {"action": action, "session_ids": ids, "expected_versions": versions}
    if action == "assign":
        body["assignee_email"] = "bulk@example.test"
    url = "/api/interviews/assignments/bulk"
    result = client.post(url, json=body)
    assert result.status_code == 409 and result.json()["detail"]["session_ids"] == [ids[1]]
    assert read(client, ids[1])["assignment"] == changed["assignment"]
    assert all(read(client, sid)["assignment"] is None for sid in [ids[0], ids[2]])
    for invalid in ({}, {ids[0]: versions[ids[0]]},
                    {**versions, ids[1].replace("-", ""): versions[ids[1]]},
                    {**versions, " " + ids[1] + " ": versions[ids[1]]}):
        assert client.post(url, json={**body, "expected_versions": invalid}).status_code == 422
    versions[ids[1]] = changed["version"]
    client.post(url, json=body).raise_for_status()
    assert all((read(client, sid)["assignment"] is None) == (action == "clear") for sid in ids)
    client.post(f"/api/sessions/{ids[1]}/trash").raise_for_status()
    assert client.post(url, json=body).status_code == 404


def test_unassigned_versions_work_before_assignment_storage_exists(client):
    sid = create_session(client)
    with store.connection(write=True) as db:
        db.execute("DROP TABLE session_assignments")
    empty = read(client, sid)["version"]
    page = client.get("/api/interviews/assignments", params={"include_versions": "true"}).raise_for_status().json()
    assert page["items"][0]["assignment_version"] == empty
    client.delete(path(sid), params={"expected_version": empty}).raise_for_status()
    saved = assign(client, sid, "first@example.test", empty).raise_for_status().json()
    assert read(client, sid)["version"] == saved["version"]


def test_one_of_two_reviewers_can_claim_an_unassigned_interview(client):
    sid = create_session(client)
    token = read(client, sid)["version"]
    barrier = Barrier(2)

    def claim(email):
        barrier.wait(timeout=5)
        return assign(client, sid, email, token).status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(claim, ["first@example.test", "second@example.test"]))
    assert sorted(results) == [200, 409]
    assert read(client, sid)["assignment"]["assignee_email"] in ("first@example.test", "second@example.test")
