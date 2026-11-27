"""Bind draft destruction, creation retries and portable completion to their original operations."""
from copy import deepcopy
from hashlib import sha256
import json
from uuid import uuid4

import pytest

from api import store
from backup_requests import client, preview, restore
from test_deferred_questions import PARENT, action, child, get_item, prepare, receipt, select


def fresh_database(tmp_path, monkeypatch):
    target = tmp_path / "new.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))


def test_old_discard_cannot_remove_a_restored_draft_and_new_discard_leaves_question_pending(client, tmp_path, monkeypatch):
    base, (parent, _) = prepare(client)
    item, _ = select(client, base, parent)
    proposed = child(item)
    draft = client.put(base + "/draft", json={**proposed, "expected_revision": 0}).raise_for_status().json()
    discard = {"id": draft["id"], "expected_revision": draft["revision"], "deferred_question": draft["deferred_question"]}
    assert client.get(base).json()["draft"]["deferred_question"] == draft["deferred_question"]
    raw = client.get("/api/backups/workspace").raise_for_status().content
    fresh_database(tmp_path, monkeypatch)
    restore(client, raw, preview(client, raw)).raise_for_status()
    recovered = client.get(base + "/draft").raise_for_status().json()
    assert (recovered["id"], recovered["revision"]) == (draft["id"], draft["revision"])
    assert recovered["deferred_question"]["version"] != draft["deferred_question"]["version"]
    for supplied in (discard, {k: v for k, v in discard.items() if k != "deferred_question"}):
        denied = client.post(base + "/draft/discard", json=supplied)
        assert denied.status_code == 409 and denied.headers["X-InterviewCheck-Conflict"] == "deferred-question"
        assert client.get(base + "/draft").json() == recovered
    # Changing the parent stales the item. The current parked binding still authorizes discarding that draft.
    client.put(base + "/answers/" + parent, json={**PARENT, "answer": "A changed explanation."}).raise_for_status()
    current = client.get(base).json()["draft"]["deferred_question"]
    assert current == recovered["deferred_question"]
    client.post(base + "/draft/discard", json={**discard, "deferred_question": current}).raise_for_status()
    assert client.get(base + "/draft").json() is None
    queued = get_item(client, base, item)
    assert queued["status"] == "pending" and queued["needs_reconfirmation"] and queued["child_answer_id"] is None


@pytest.mark.parametrize("block", ["notice", "hold", "trash"])
def test_ordinary_draft_read_does_not_reveal_a_blocked_linked_draft(client, block):
    base, (parent, _) = prepare(client)
    item, _ = select(client, base, parent, "Private linked follow up?")
    request = child(item)
    draft = client.put(base + "/draft", json={**request, "expected_revision": 0}).raise_for_status().json()
    sid = base.rsplit("/", 1)[-1]
    if block == "trash":
        client.post(base + "/trash").raise_for_status()
    else:
        with store.connection(write=True) as db:
            if block == "notice":
                db.execute("UPDATE sessions SET consent=0 WHERE id=?", (sid,))
            else:
                db.execute("INSERT INTO legacy_privacy_holds(session_id) VALUES(?)", (sid,))
    response = client.get(base + "/draft")
    assert response.status_code == (404 if block == "trash" else 403)
    assert all(value not in response.text for value in (item["question"], request["answer"], draft["deferred_question"]["version"]))
    session = client.get(base)
    if block == "trash":
        assert session.status_code == 404
    else:
        assert session.raise_for_status().json()["draft"] is None and draft["deferred_question"]["version"] not in session.text


def test_keep_retry_recovers_the_original_item_after_parent_mutation(client):
    base, (parent, other) = prepare(client)
    queued, original = select(client, base, parent)
    client.put(base + "/answers/" + parent, json={**PARENT, "answer": "Changed while the create acknowledgement was lost."}).raise_for_status()
    recovered = client.post(base + "/deferred-questions", json=original).raise_for_status().json()
    assert recovered == get_item(client, base, queued)
    assert recovered["id"] == queued["id"] and recovered["needs_reconfirmation"]
    current_material = receipt(client, base, parent)
    for fields in ({"question": "A different prompt?"}, {"expected_material": current_material},
                   {"parent_answer_id": other, "expected_material": receipt(client, base, other)}):
        assert client.post(base + "/deferred-questions", json={**original, **fields}).status_code == 409
    confirmed = action(client, base, recovered, "reconfirm", expected_material=current_material).raise_for_status().json()
    assert client.post(base + "/deferred-questions", json=original).json() == confirmed
    assert client.get(base + "/deferred-questions").json()["total"] == 1


def test_awaiting_questions_share_exact_creation_and_import_text_boundaries(client):
    base, (parent, _) = prepare(client)
    queued, original = select(client, base, parent, "Which check?\nExplain it.")
    raw = client.get("/api/backups/workspace").json()
    for value in ("bad\x00question", "bad\x1fquestion", "bad\x85question", " padded ", "   ", "x"*4001):
        bad_create = client.post(base + "/deferred-questions", json={**original, "id": str(uuid4()), "question": value})
        assert bad_create.status_code == 422
        bad_file = deepcopy(raw)
        bad_file["sessions"][0]["deferred_questions"][0]["question"] = value
        assert client.post("/api/backups/preview", json=bad_file).status_code == 422
    assert get_item(client, base, queued)["question"] == "Which check?\nExplain it."
    assert client.get(base + "/deferred-questions").json()["total"] == 1


def test_child_publication_fact_rejects_sibling_swaps_and_restores_corrected_record(client, tmp_path, monkeypatch):
    base, (parent, _) = prepare(client)
    completed = []
    for i in range(2):
        q, _ = select(client, base, parent, f"Selected follow up {i}?")
        body = child(q)
        published = client.post(base + "/answers", json=body).raise_for_status().json()
        proof = published["deferred_receipt"]
        digest = sha256(json.dumps([body["id"], parent, None, body["question"], body["answer"], []],
                                   ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()
        assert proof == {"question_id": q["id"], "parent_answer_id": parent, "child_answer_id": body["id"], "submission_sha256": digest}
        client.patch(base + "/answers/" + body["id"], json={"disposition": "explained", "note": "Reviewed."}).raise_for_status()
        completed.append((q, body, proof))
    q, corrected, original_proof = completed[0]
    update = {k: v for k, v in corrected.items() if k not in ("deferred_question", "id")}
    client.put(base + "/answers/" + corrected["id"], json={**update, "question": "Corrected transcript?", "answer": "New detail."}).raise_for_status()
    retry = client.post(base + "/answers", json=corrected).raise_for_status().json()
    assert retry["deferred_replay"] and retry["deferred_receipt"] == original_proof and retry["question"] == "Corrected transcript?"
    response = client.get("/api/backups/workspace").raise_for_status()
    assert response.headers["X-Backup-Deferred-Questions"] == "2"
    doc = response.json()
    assert original_proof["submission_sha256"] not in response.text  # The original submission digest stays private.
    assert all(request["deferred_question"]["version"] not in response.text for _, request, _ in completed)

    swapped = deepcopy(doc)
    left, right = swapped["sessions"][0]["deferred_questions"]
    left["child_answer_id"], right["child_answer_id"] = right["child_answer_id"], left["child_answer_id"]
    assert client.post("/api/backups/preview", json=swapped).status_code == 422
    altered = deepcopy(doc)
    origins = [a for a in altered["sessions"][0]["answers"] if "deferred_origin" in a]
    origins[0]["deferred_origin"], origins[1]["deferred_origin"] = origins[1]["deferred_origin"], origins[0]["deferred_origin"]
    assert client.post("/api/backups/preview", json=altered).status_code == 422
    missing = deepcopy(doc)
    del next(a for a in missing["sessions"][0]["answers"] if a["id"] == corrected["id"])["deferred_origin"]
    assert client.post("/api/backups/preview", json=missing).status_code == 422
    fresh_database(tmp_path, monkeypatch)
    restore(client, response.content, preview(client, response.content)).raise_for_status()
    assert client.get("/api/backups/workspace").content == response.content
    assert get_item(client, base, q)["child_answer_id"] == corrected["id"]
    assert client.get(base + "/answers/" + corrected["id"]).json()["question"] == "Corrected transcript?"


def test_existing_sqlite_receipt_recovers_original_fact_after_an_answer_correction(client):
    base, (parent, _) = prepare(client)
    q, _ = select(client, base, parent, "Which original check?")
    data = child(q)
    data["references"] = [{"label": "Manual Δ", "text": "An independent boundary check.", "permitted": False}]
    initial = client.post(base + "/answers", json=data).raise_for_status().json()
    aid = data["id"]
    changed = {k: v for k, v in data.items() if k not in ("id", "deferred_question")}
    client.put(base + "/answers/" + aid, json={**changed, "question": "A later correction?"}).raise_for_status()
    # Earlier builds stored the private submission hash, but no separate child-side publication row.
    original = sha256(json.dumps([aid, parent, None, data["question"], data["answer"], data["references"]],
                                 ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    with store.connection(write=True) as db:
        db.execute("DROP TABLE deferred_publications")
        db.execute("UPDATE deferred_questions SET fulfillment_digest=? WHERE id=?", (original, q["id"]))
    store.initialize(store.db_path())
    file = client.get("/api/backups/workspace").raise_for_status().json()
    fact = next(a["deferred_origin"] for a in file["sessions"][0]["answers"] if a["id"] == aid)
    assert (fact["child_answer_id"], fact["question_id"]) == (aid, q["id"])
    replay = client.post(base + "/answers", json=data).raise_for_status().json()
    assert replay["deferred_receipt"] == initial["deferred_receipt"] and replay["question"] == "A later correction?"
