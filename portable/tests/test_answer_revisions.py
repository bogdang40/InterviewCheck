import sqlite3
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier

from fastapi.testclient import TestClient
import pytest

from api import store
from api.main import app


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite"))
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_URL", raising=False)
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_MODE", raising=False)
    monkeypatch.delenv("INTERVIEWCHECK_PUBLIC_ORIGIN", raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        yield client


def prepare(client):
    session = client.post(
        "/api/sessions",
        json={"candidate": "Fixture", "role": "SRE", "policy": "Notes allowed.", "consent": True},
    )
    session.raise_for_status()
    base = "/api/sessions/" + session.json()["id"] + "/answers"
    answer = client.post(base, json={"question": "How?", "answer": "The old answer."})
    answer.raise_for_status()
    assert answer.json()["revision"] == 1
    return base + "/" + answer.json()["id"]


def test_review_and_exchange_share_a_revision(client):
    path = prepare(client)
    review = {"note": "Saved evidence.", "disposition": "unresolved", "expected_revision": 1}
    assert client.patch(path, json=review).json()["revision"] == 2
    edit = {"question": "Why?", "answer": "New content.", "expected_revision": 1}
    stale = client.put(path, json=edit)
    assert stale.status_code == 409 and stale.headers["x-interviewcheck-conflict"] == "answer-revision"
    assert client.get(path).json()["note"] == "Saved evidence."
    assert client.get(path).json()["question"] == "How?"
    edit["expected_revision"] = 2
    assert client.put(path, json=edit).json()["revision"] == 3
    assert client.patch(path, json={**review, "expected_revision": 2}).status_code == 409
    current = client.get(path).json()
    assert current["disposition"] == "pending" and current["note"].endswith("Saved evidence.")
    assert client.put(path, json={**edit, "expected_revision": 3}).json()["revision"] == 3
    # Older clients can still make edits. Current clients then see the new revision.
    assert (
        client.patch(path, json={"note": "Legacy client", "disposition": "explained"}).json()["revision"] == 4
    )
    assert client.patch(path, json={**review, "expected_revision": True}).status_code == 422
    assert client.patch(path, json={**review, "expected_revision": 0}).status_code == 422


def test_competing_within_same_revision_has_one_winner(client):
    path = prepare(client)
    barrier = Barrier(2)

    def change(note):
        barrier.wait()
        return client.patch(path, json={"expected_revision": 1, "note": note, "disposition": "explained"})

    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(change, ("Reviewer one", "Reviewer two")))
    assert sorted(result.status_code for result in responses) == [200, 409]
    assert client.get(path).json()["revision"] == 2
    assert client.get(path).json()["note"] == next(
        result.json()["note"] for result in responses if result.is_success
    )


def test_existing_answer_gains_revision_without_losing_review(client):
    path = prepare(client)
    client.patch(path, json={"note": "Keep this", "disposition": "explained"}).raise_for_status()
    with sqlite3.connect(store.db_path()) as db:
        db.execute("ALTER TABLE answers DROP COLUMN revision")
    store.initialize(store.db_path())
    store.initialize(store.db_path())
    current = client.get(path).json()
    assert (current["revision"], current["note"], current["disposition"]) == (1, "Keep this", "explained")
