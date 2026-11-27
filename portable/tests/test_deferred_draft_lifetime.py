"""A reused draft UUID and revision cannot authorize operations on its replacement."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import sqlite3
from threading import Barrier
from uuid import uuid4

from api import store
from backup_requests import client, preview, restore
from test_deferred_questions import PARENT, child, get_item, prepare, select


def mutations(draft):
    return {"id": draft["id"], "expected_revision": draft["revision"], "deferred_question": draft["deferred_question"],
            "deferred_draft_token": draft["deferred_draft_token"]}


def test_recreated_draft_rejects_predecessor_even_in_a_race_with_a_current_save(client):
    base, (aid, _) = prepare(client)
    q, _ = select(client, base, aid)
    proposed = child(q)
    put = {**proposed, "expected_revision": 0}
    old = client.put(base + "/draft", json=put).raise_for_status().json()
    client.post(base + "/draft/discard", json=mutations(old)).raise_for_status()
    fresh = client.put(base + "/draft", json=put).raise_for_status().json()
    assert old["deferred_question"] == fresh["deferred_question"] and old["id"] == fresh["id"]
    assert old["revision"] == fresh["revision"] and old["deferred_draft_token"] != fresh["deferred_draft_token"]
    assert client.get(base).json()["draft"]["deferred_draft_token"] == fresh["deferred_draft_token"]
    assert client.put(base + "/draft", json={**proposed, **mutations(old)}).status_code == 409
    assert client.post(base + "/draft/publish", json={**proposed, **mutations(old)}).status_code == 409
    barrier = Barrier(2)
    def discard_old():
        barrier.wait()
        return client.post(base + "/draft/discard", json=mutations(old))
    def save_new():
        barrier.wait()
        return client.put(base + "/draft", json={**proposed, **mutations(fresh), "answer": "Second draft lifetime."})
    with ThreadPoolExecutor(2) as pool:
        stale, saved = pool.submit(discard_old), pool.submit(save_new)
        assert stale.result().status_code == 409
        new = saved.result().raise_for_status().json()
    assert new["revision"] == 2 and new["deferred_draft_token"] == fresh["deferred_draft_token"]
    assert client.get(base + "/draft").json() == new
    client.post(base + "/draft/discard", json=mutations(new)).raise_for_status()
    assert get_item(client, base, q)["status"] == "pending" and client.get(base + "/draft").json() is None


def test_full_sqlite_preserves_linked_draft_authority_and_json_replaces_it(client, tmp_path, monkeypatch):
    base, (aid, _) = prepare(client)
    q, _ = select(client, base, aid)
    parked = client.put(base + "/draft", json={**child(q), "expected_revision": 0}).raise_for_status().json()
    raw = client.get("/api/backups/workspace").raise_for_status().content
    assert parked["deferred_draft_token"].encode() not in raw and b"deferred_draft_token" not in raw
    full = tmp_path / "full.sqlite"
    with closing(sqlite3.connect(store.db_path())) as source, closing(sqlite3.connect(full)) as dest:
        source.backup(dest)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(full))
    store.initialize(full)
    assert client.get(base + "/draft").json()["deferred_draft_token"] == parked["deferred_draft_token"]
    client.post(base + "/draft/discard", json=mutations(parked)).raise_for_status()
    empty = tmp_path / "json.sqlite"
    store.initialize(empty)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(empty))
    restore(client, raw, preview(client, raw)).raise_for_status()
    restored = client.get(base + "/draft").json()
    assert client.post(base + "/draft/discard", json={**mutations(restored), "deferred_draft_token": parked["deferred_draft_token"]}).status_code == 409
    assert client.get(base + "/draft").json() == restored
    client.post(base + "/draft/discard", json=mutations(restored)).raise_for_status()


def test_unbound_plain_posts_never_acknowledge_a_deferred_child_or_delete_an_unrelated_draft(client):
    base, (aid, _) = prepare(client)
    q, _ = select(client, base, aid)
    proposed = child(q)
    saved = client.post(base + "/answers", json=proposed).raise_for_status().json()
    published_id = saved["id"]
    ordinary = {k: v for k, v in proposed.items() if k != "deferred_question"}
    parked = client.put(base + "/draft", json={"id": str(uuid4()), "expected_revision": 0,
                                               "question": "A separate ordinary draft", "answer": "Keep this."}).raise_for_status().json()
    for endpoint, extra in (("/answers", {}), ("/draft/publish", {"expected_revision": 1})):
        denied = client.post(base + endpoint, json={**ordinary, **extra})
        assert denied.status_code == 409 and denied.headers["X-InterviewCheck-Conflict"] == "deferred-question"
        assert client.get(base + "/draft").json() == parked
    assert client.post(base + "/answers", json=proposed).raise_for_status().json()["deferred_replay"]
    assert client.get(base + "/draft").json() == parked
    assert client.get(base + "/answers/" + published_id).json()["revision"] == saved["revision"]
    # This ordinary saved draft still uses its original contract.
    client.post(base + "/draft/discard", json={"id": parked["id"], "expected_revision": parked["revision"]}).raise_for_status()


def test_creation_check_distinguishes_current_original_missing_and_restored_rows(client, tmp_path, monkeypatch):
    base, (aid, other) = prepare(client)
    item, original = select(client, base, aid)
    path = base + "/deferred-questions/" + item["id"] + "/creation-check"
    source = {k: v for k, v in original.items() if k != "id"}
    assert client.post(path, json=source).json() == {"outcome": "confirmed", "item": item}
    assert client.post(path.replace(item["id"], str(uuid4())), json=source).json() == {"outcome": "missing", "item": None}
    for wrong in ({"question": "Another text?"}, {"parent_answer_id": other}, {"expected_material": "a"*64}):
        assert client.post(path, json={**source, **wrong}).json() == {"outcome": "mismatch", "item": None}
    client.put(base + "/answers/" + aid, json={**PARENT, "answer": "Different material"}).raise_for_status()
    confirmed = client.post(path, json=source).raise_for_status().json()
    assert confirmed["outcome"] == "confirmed" and confirmed["item"]["needs_reconfirmation"]
    raw = client.get("/api/backups/workspace").content
    target = tmp_path / "restored.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
    restore(client, raw, preview(client, raw)).raise_for_status()
    assert client.post(path, json=source).json() == {"outcome": "matching_unconfirmed", "item": None}
    assert client.post(base + "/deferred-questions", json=original).status_code == 409
    assert client.get(base + "/deferred-questions").json()["total"] == 1


def test_corrected_child_replay_requires_the_lifetime_that_actually_published_it(client):
    base, (aid, _) = prepare(client)
    q, _ = select(client, base, aid)
    proposed = child(q)
    old = client.put(base + "/draft", json={**proposed, "expected_revision": 0}).raise_for_status().json()
    client.post(base + "/draft/discard", json=mutations(old)).raise_for_status()
    fresh = client.put(base + "/draft", json={**proposed, "expected_revision": 0}).raise_for_status().json()
    current_request = {**proposed, **mutations(fresh)}
    first = client.post(base + "/draft/publish", json=current_request).raise_for_status().json()
    client.put(base + "/answers/" + first["id"], json={"question": q["question"], "answer": "Corrected once."}).raise_for_status()
    ordinary = client.put(base + "/draft", json={"id": str(uuid4()), "expected_revision": 0,
                                                  "question": "An unrelated next exchange."}).raise_for_status().json()
    for rejected in ({**proposed, **mutations(old)}, {**proposed, "expected_revision": fresh["revision"]}):
        assert client.post(base + "/draft/publish", json=rejected).status_code == 409
    true_replay = client.post(base + "/draft/publish", json=current_request).raise_for_status().json()
    assert true_replay["deferred_replay"] and true_replay["answer"] == "Corrected once."
    assert true_replay["deferred_receipt"] == first["deferred_receipt"]
    assert client.get(base + "/draft").json() == ordinary
