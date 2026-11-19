from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import store
from api.main import app

ROOT = "/api/sessions"
SESSION = {
    "candidate": "Fixture",
    "role": "SRE",
    "policy": "Reference documents are allowed.",
    "consent": True,
}


@pytest.fixture
def setup(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "reviews.sqlite"))
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        session = client.post(ROOT, json=SESSION).json()
        yield client, f"{ROOT}/{session['id']}"


def row(i):
    return {
        "ordinal": i,
        "question": "What changed?",
        "answer": "Repeated words.",
        "start_ms": i * 1000,
        "end_ms": i * 1000 + 900,
    }


def batch(*ordinals):
    return {
        "request_id": str(uuid4()),
        "transcript_sha256": "a" * 64,
        "candidate_speaker": "Sam",
        "interviewer_speakers": ["Lee", "Jane"],
        "exchanges": [row(i) for i in ordinals],
    }


def test_import_preserves_order_attribution_and_manual_changes(setup):
    client, base = setup
    path = base + "/imports/webvtt"
    data = batch(3, 1)
    first = client.post(path, json=data)
    assert first.status_code == 200, first.text
    result = first.json()
    assert (result["saved"], result["skipped"], result["replayed"]) == (2, 0, False)
    a, b = result["answer_ids"]
    assert a != b
    records = client.get(base).json()["answers"]
    assert [r["import_origin"]["ordinal"] for r in records] == [3, 1]
    assert records[0]["import_origin"]["candidate_speaker"] == "Sam"
    assert records[0]["import_origin"]["interviewer_speakers"] == ["Jane", "Lee"]
    client.put(
        base + "/answers/" + a, json={"expected_revision": 1, "question": "Edited", "answer": "Changed"}
    ).raise_for_status()
    replay = client.post(path, json=data).json()
    assert replay == {"saved": 0, "skipped": 2, "answer_ids": [a, b], "replayed": True}
    new = client.post(path, json=batch(1, 2, 3)).json()
    assert (
        new["saved"] == 1 and new["skipped"] == 2 and new["answer_ids"][0] == b and new["answer_ids"][2] == a
    )
    record = client.get(base + "/answers/" + a).json()
    assert record["answer"] == "Changed" and record["revision"] == 2


def test_same_request_rejected_on_different_payload_order_or_session(setup):
    client, base = setup
    path = base + "/imports/webvtt"
    data = batch(1, 2)
    client.post(path, json=data).raise_for_status()
    for changes in ({"exchanges": [row(1)]}, {"exchanges": [row(2), row(1)]}, {"candidate_speaker": "Other"}):
        assert client.post(path, json={**data, **changes}).status_code == 409
    other = client.post(ROOT, json=SESSION).json()["id"]
    assert client.post(f"{ROOT}/{other}/imports/webvtt", json=data).status_code == 409
    assert client.get(f"{ROOT}/{other}").json()["answer_count"] == 0


def test_partial_conflict_rolls_back_rows_and_request_receipt(setup):
    client, base = setup
    path = base + "/imports/webvtt"
    client.post(path, json=batch(2)).raise_for_status()
    data = batch(1, 2)
    data["exchanges"][1]["question"] = "A conflicting edit"
    assert client.post(path, json=data).status_code == 409
    assert client.get(base).json()["answer_count"] == 1
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM transcript_imports").fetchone()[0] == 1
    data["exchanges"][1] = row(2)
    repaired = client.post(path, json=data).json()
    assert repaired["saved"] == 1 and repaired["skipped"] == 1


@pytest.mark.parametrize(
    "changes",
    [
        {"exchanges": []},
        {"exchanges": [row(i) for i in range(1, 102)]},
        {"exchanges": [row(1), row(1)]},
        {"exchanges": [{**row(1), "end_ms": 1}]},
        {"exchanges": [{**row(1), "answer": ""}]},
        {"exchanges": [{**row(i), "answer": "x" * 24000} for i in range(1, 22)]},
        {"transcript_sha256": "z" * 64},
        {"interviewer_speakers": ["Sam"]},
        {"interviewer_speakers": []},
        {"interviewer_speakers": ["Lee", "Lee"]},
    ],
)
def test_reject_invalid_selection_without_writes(setup, changes):
    client, base = setup
    assert client.post(base + "/imports/webvtt", json={**batch(1), **changes}).status_code == 422
    assert client.get(base).json()["answer_count"] == 0


def test_finish_and_candidate_notice(setup):
    client, base = setup
    path = base + "/imports/webvtt"
    data = batch(1)
    client.post(path, json=data).raise_for_status()
    client.post(base + "/finish").raise_for_status()
    assert client.post(path, json=data).json()["replayed"]
    assert client.post(path, json=batch(2)).status_code == 409
    with store.connection(write=True) as db:
        db.execute("UPDATE sessions SET consent=0 WHERE id=?", (base.rsplit("/", 1)[1],))
    assert client.post(path, json=data).status_code == 409


def test_concurrent_request_has_one_committed_batch(setup):
    client, base = setup
    data = batch(1, 2)
    barrier = Barrier(2)

    def submit(_):
        barrier.wait()
        response = client.post(base + "/imports/webvtt", json=data)
        response.raise_for_status()
        return response.json()

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(submit, range(2)))
    assert sorted(r["saved"] for r in results) == [0, 2]
    assert results[0]["answer_ids"] == results[1]["answer_ids"]
    assert client.get(base).json()["answer_count"] == 2


@pytest.mark.parametrize("indexed", [False, True])
def test_expanded_interviewer_mapping_preserves_existing_turn_identity(setup, indexed):
    client, base = setup
    path = base + "/imports/webvtt"
    first = batch(2)
    first["interviewer_speakers"] = ["First host"]
    if indexed:
        first["exchanges"][0].update(first_cue=4, last_cue=6)
    original = client.post(path, json=first).json()
    second = dict(
        first,
        request_id=str(uuid4()),
        interviewer_speakers=["First host", "Second host"],
        exchanges=[{**first["exchanges"][0], "ordinal": 3}],
    )
    added = client.post(path, json=second).json()
    assert (added["saved"], added["skipped"], added["answer_ids"]) == (0, 1, original["answer_ids"])
    (record,) = client.get(base).json()["answers"]
    assert record["import_origin"]["interviewer_speakers"] == ["First host"]


def test_coincident_timestamps_keep_two_turns_distinct_by_cue_index(setup):
    client, base = setup
    data = batch(1, 2)
    data["exchanges"] = [
        dict(row(1), ordinal=1, first_cue=1, last_cue=2),
        dict(row(1), ordinal=2, first_cue=3, last_cue=4),
    ]
    result = client.post(base + "/imports/webvtt", json=data).json()
    assert result["saved"] == 2 and len(set(result["answer_ids"])) == 2
