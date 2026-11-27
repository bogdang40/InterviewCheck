"""Selected follow ups remain separate from drafts until a linked exchange commits."""
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from uuid import uuid4

from fastapi import HTTPException
from api import deferred_items, store
from api.retention_anonymizer import SessionAnonymizer
from backup_requests import client

QUESTION = "Which verification step would you repeat?"
PARENT = {"question": "What happened?", "answer": "I compared the two independent observations."}


def prepare(client):
    sid = client.post("/api/sessions", json={"candidate": "Fixture", "role": "Engineer", "policy": "Manual", "consent": True}).raise_for_status().json()["id"]
    parents = [client.post(f"/api/sessions/{sid}/answers", json=PARENT).raise_for_status().json()["id"] for _ in range(2)]
    return f"/api/sessions/{sid}", parents


def receipt(client, base, aid):
    return client.get(f"{base}/answers/{aid}/worksheet").raise_for_status().json()["material"]


def select(client, base, aid, text=QUESTION):
    payload = {"id": str(uuid4()), "parent_answer_id": aid, "question": text, "expected_material": receipt(client, base, aid)}
    item = client.post(base + "/deferred-questions", json=payload).raise_for_status().json()
    return item, payload


def child(item, *, aid=None):
    return {"id": aid or str(uuid4()), "question": item["question"], "answer": "I checked the independent log.",
            "parent_answer_id": item["parent_answer_id"], "planned_slot": None, "references": [],
            "deferred_question": {"id": item["id"], "version": item["version"]}}


def get_item(client, base, item):
    return client.get(f"{base}/deferred-questions/{item['id']}").raise_for_status().json()


def action(client, base, item, key, **fields):
    return client.patch(f"{base}/deferred-questions/{item['id']}",
                        json={"action": key, "expected_version": item["version"], **fields})


def test_keep_alongside_an_unrelated_draft_and_preserve_it_through_capture_conflict(client):
    base, (aid, other) = prepare(client)
    draft = {"id": str(uuid4()), "question": "Existing work", "answer": "Keep my partial answer.", "expected_revision": 0}
    original = client.put(base + "/draft", json=draft).raise_for_status().json()
    item, request = select(client, base, aid)
    assert client.post(base + "/deferred-questions", json=request).raise_for_status().json() == item
    moved = {**request, "parent_answer_id": other, "expected_material": receipt(client, base, other)}
    assert client.post(base + "/deferred-questions", json=moved).status_code == 409
    sibling, _ = select(client, base, other)
    assert sibling["id"] != item["id"] and sibling["question"] == item["question"]
    page = client.get(base + "/deferred-questions", params={"page": 2, "page_size": 1}).json()
    assert page["pending_count"] == page["total"] == 2 and page["page"] == 2 and len(page["items"]) == 1
    blocked = client.put(base + "/draft", json={**child(item), "expected_revision": 0})
    assert blocked.status_code == 409 and blocked.headers["X-InterviewCheck-Conflict"] == "deferred-question"
    assert client.post(base + "/answers", json=child(item)).status_code == 409
    assert client.get(base + "/draft").json() == original
    client.post(base + "/draft/publish", json={**draft, "expected_revision": original["revision"]}).raise_for_status()
    assert get_item(client, base, item)["status"] == "pending"
    assert len(client.get(base).json()["answers"]) == 3
    assert action(client, base, sibling, "dismiss").raise_for_status().json()["status"] == "dismissed"


def test_reconfirm_material_after_edit_and_revert_even_with_parked_work(client):
    base, (aid, _) = prepare(client)
    item, _ = select(client, base, aid)
    payload = child(item)
    parked = client.put(base + "/draft", json={**payload, "expected_revision": 0}).raise_for_status().json()
    assert parked["deferred_question"] == payload["deferred_question"]
    payload["deferred_draft_token"] = parked["deferred_draft_token"]
    assert action(client, base, item, "dismiss").status_code == 409
    assert client.patch(f"{base}/answers/{aid}", json={"note": "Reviewed later.", "disposition": "explained"}).status_code == 200
    assert get_item(client, base, item) == item
    client.put(f"{base}/answers/{aid}", json={**PARENT, "answer": "Another explanation."}).raise_for_status()
    client.put(f"{base}/answers/{aid}", json=PARENT).raise_for_status()
    stale = get_item(client, base, item)
    assert stale["needs_reconfirmation"] and stale["version"] != item["version"]
    assert client.post(base + "/draft/publish", json={**payload, "expected_revision": parked["revision"]}).status_code == 409
    assert client.get(base + "/draft").json() == parked
    assert action(client, base, stale, "reconfirm", expected_material="a"*64).status_code == 409
    current = action(client, base, stale, "reconfirm", expected_material=receipt(client, base, aid)).raise_for_status().json()
    assert not current["needs_reconfirmation"]
    refreshed_payload = {**child(current, aid=payload["id"]), "deferred_draft_token": parked["deferred_draft_token"]}
    assert client.post(base + "/draft/publish", json={**refreshed_payload, "expected_revision": parked["revision"]}).status_code == 409
    rebound = client.put(base + "/draft", json={**refreshed_payload, "expected_revision": parked["revision"]}).raise_for_status().json()
    assert rebound["revision"] == parked["revision"] + 1 and rebound["answer"] == parked["answer"]
    ordinary = {k: v for k, v in refreshed_payload.items() if k != "deferred_question"}
    assert client.post(base + "/draft/publish", json={**ordinary, "expected_revision": rebound["revision"]}).status_code == 409
    assert client.get(base + "/draft").json() == rebound
    result = client.post(base + "/draft/publish", json={**refreshed_payload, "expected_revision": rebound["revision"]}).raise_for_status().json()
    assert result["id"] == payload["id"] and get_item(client, base, item)["child_answer_id"] == result["id"]


def test_lost_reply_race_and_explicit_child_binding(client):
    base, (aid, other) = prepare(client)
    item, _ = select(client, base, aid)
    payload = child(item)
    for wrong in ({"parent_answer_id": other}, {"question": "Different prompt"}, {"id": other}):
        assert client.post(base + "/answers", json={**payload, **wrong}).status_code == 409
    second = child(item)
    barrier = Barrier(2)
    def publish(body):
        barrier.wait()
        return client.post(base + "/answers", json=body)
    with ThreadPoolExecutor(2) as pool:
        replies = [f.result() for f in [pool.submit(publish, body) for body in (payload, second)]]
    assert sorted(r.status_code for r in replies) == [201, 409]
    winning = payload if replies[0].status_code == 201 else second
    linked = get_item(client, base, item)
    assert linked["status"] == "fulfilled" and linked["child_answer_id"] == winning["id"]
    edit = {k: v for k, v in winning.items() if k not in ("deferred_question", "id")}
    url = base + "/answers/" + winning["id"]
    assert client.put(url, json={**edit, "parent_answer_id": other}).status_code == 409
    client.put(url, json={**edit, "answer": "Updated detail."}).raise_for_status()
    client.post(base + "/finish").raise_for_status()
    replay = client.post(base + "/answers", json=winning).raise_for_status().json()
    assert replay["deferred_replay"] is True and replay["answer"] == "Updated detail."
    assert client.post(base + "/answers", json={**winning, "answer": "Different retry"}).status_code == 409
    assert len(client.get(base).raise_for_status().json()["answers"]) == 3


def test_failed_completion_rolls_back_child_removal_of_draft_and_usage(client, monkeypatch):
    base, (aid, _) = prepare(client)
    queued, _ = select(client, base, aid)
    data = child(queued)
    draft = client.put(base + "/draft", json={**data, "expected_revision": 0}).raise_for_status().json()
    data["deferred_draft_token"] = draft["deferred_draft_token"]
    def fail(*args):
        raise HTTPException(409, "Synthetic commit failure.")
    monkeypatch.setattr(deferred_items, "finish_publish", fail)
    assert client.post(base + "/draft/publish", json={**data, "expected_revision": draft["revision"]}).status_code == 409
    assert client.get(base + "/draft").json() == draft
    assert get_item(client, base, queued) == queued and len(client.get(base).json()["answers"]) == 2


def test_finished_trash_notice_retention_and_real_overdue_assignment(client):
    base, (aid, _) = prepare(client)
    sid = base.rsplit("/", 1)[1]
    client.put(base + "/assignment", json={"assignee_email": "reviewer@example.test", "priority": "high",
                                          "due_at": "2000-01-01T00:00:00Z"}).raise_for_status()
    queued, request = select(client, base, aid)
    client.post(base + "/finish").raise_for_status()
    assert get_item(client, base, queued)["status"] == "pending"
    assert client.post(base + "/deferred-questions", json={**request, "id": str(uuid4())}).status_code == 409
    assert client.post(base + "/answers", json=child(queued)).status_code == 409
    client.post(base + "/reopen").raise_for_status()
    marker = client.post(base + "/trash").raise_for_status().json()
    assert client.get(base + "/deferred-questions").status_code == 404
    client.post(f"/api/trash/{sid}/restore", json={"operation_version": marker["operation_version"]}).raise_for_status()
    assert get_item(client, base, queued)["status"] == "pending"
    with store.connection(write=True) as db:
        db.execute("UPDATE sessions SET consent=0 WHERE id=?", (sid,))
    assert client.get(base + "/deferred-questions").status_code == 403
    with store.connection(write=True) as db:
        db.execute("UPDATE sessions SET consent=1 WHERE id=?", (sid,))
        SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=True, actor_email="fixture", now_iso=store.timestamp())
        assert db.execute("SELECT count(*) FROM deferred_questions WHERE session_id=?", (sid,)).fetchone()[0] == 0
    assert client.get(base + "/deferred-questions").status_code == 403
    assert QUESTION not in client.get("/api/backups/workspace").text


def test_dismiss_reopen_and_material_receipt_mismatch_do_not_move_or_duplicate_question(client):
    base, (aid, other) = prepare(client)
    q, request = select(client, base, aid)
    assert client.post(base + "/deferred-questions", json={**request, "id": str(uuid4()),
                       "expected_material": receipt(client, base, other)}).status_code == 409
    dismissed = action(client, base, q, "dismiss").raise_for_status().json()
    assert client.get(base + "/deferred-questions", params={"status": "pending"}).json()["total"] == 0
    assert action(client, base, dismissed, "reopen").status_code == 422
    assert action(client, base, dismissed, "reopen", expected_material=receipt(client, base, other)).status_code == 409
    pending = action(client, base, dismissed, "reopen", expected_material=receipt(client, base, aid)).raise_for_status().json()
    assert pending["status"] == "pending" and pending["version"] != q["version"]
    assert pending["id"] == q["id"] and client.get(base + "/deferred-questions").json()["total"] == 1
