"""Verify portable graph recovery and keep in-flight edit authority local to each installation."""
from copy import deepcopy
import json
from uuid import uuid4

import pytest

from api import store
from backup_requests import client, preview, restore
from test_deferred_questions import PARENT, action, child, get_item, prepare, receipt, select


def recover_to(tmp_path, monkeypatch, name):
    path = tmp_path / name
    store.initialize(path)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(path))


def build_graph(client):
    base, (one, two) = prepare(client)
    pending, _ = select(client, base, one, "Which check belongs in a draft?")
    fulfilled, _ = select(client, base, one, "Which check was done?")
    published = child(fulfilled)
    client.post(base + "/answers", json=published).raise_for_status()
    dismissed, _ = select(client, base, two, "What was deferred and dismissed?")
    action(client, base, dismissed, "dismiss").raise_for_status()
    stale, _ = select(client, base, two, "What must be reconfirmed?")
    client.put(f"{base}/answers/{two}", json={**PARENT, "answer": "Changed evidence."}).raise_for_status()
    proposed = child(pending)
    draft = client.put(base + "/draft", json={**proposed, "expected_revision": 0}).raise_for_status().json()
    grade = {"criterion_id": "reason", "criterion_label": "Reasoning", "weight": 2, "rating": 4, "rationale": "Saved assessment."}
    scored = client.put(base + "/scorecard", json={"items": [grade]}).raise_for_status().json()
    return base, {"pending": pending, "fulfilled": fulfilled, "dismissed": dismissed, "stale": stale}, proposed, draft, published, scored


@pytest.mark.parametrize("in_trash", [False, True])
def test_v7_keeps_graph_and_draft_but_rebinds_local_tokens(client, tmp_path, monkeypatch, in_trash):
    base, items, proposed, draft, published, grade = build_graph(client)
    sid = base.rsplit("/", 1)[1]
    if in_trash:
        client.post(base + "/trash").raise_for_status()
    raw = client.get("/api/backups/workspace", params={"session_id": sid}).raise_for_status().content
    assert raw == client.get("/api/backups/workspace").raise_for_status().content
    doc = json.loads(raw)
    record, = doc["sessions"]
    assert doc["version"] == 7 and len(record["deferred_questions"]) == 4
    assert record["draft"]["deferred_question_id"] == items["pending"]["id"]
    assert all(q["version"].encode() not in raw for q in items.values())
    assert b"fulfillment_digest" not in raw and b"previous_revision_id" not in raw
    assert draft["deferred_draft_token"].encode() not in raw
    recover_to(tmp_path, monkeypatch, "v7.sqlite")
    plan = preview(client, raw)
    assert plan["deferred_questions"] == 4
    restore(client, raw, plan).raise_for_status()
    assert preview(client, raw)["sessions"]["identical"] == 1
    assert client.get("/api/backups/workspace").content == raw
    if in_trash:
        assert client.get(base + "/deferred-questions").status_code == 404
        entry, = client.get("/api/trash").json()["items"]
        client.post(f"/api/trash/{sid}/restore", json={"operation_version": entry["operation_version"]}).raise_for_status()
    assert client.get(base + "/scorecard").json()["items"] == grade["items"]
    recovered = {key: get_item(client, base, item) for key, item in items.items()}
    assert recovered["fulfilled"]["child_answer_id"] == published["id"]
    assert recovered["dismissed"]["status"] == "dismissed" and recovered["stale"]["needs_reconfirmation"]
    assert not recovered["pending"]["needs_reconfirmation"]
    linked = client.get(base + "/draft").raise_for_status().json()
    assert linked["deferred_question"]["id"] == draft["deferred_question"]["id"]
    assert linked["deferred_question"]["version"] != draft["deferred_question"]["version"]
    assert client.post(base + "/draft/publish", json={**proposed, "expected_revision": draft["revision"]}).status_code == 409
    assert client.get(base + "/draft").json() == linked
    client.post(base + "/draft/publish", json={**proposed, "deferred_question": linked["deferred_question"],
                                               "deferred_draft_token": linked["deferred_draft_token"], "expected_revision": linked["revision"]}).raise_for_status()
    assert get_item(client, base, items["pending"])["child_answer_id"] == proposed["id"]


def test_v6_replay_preserves_newer_queue_and_draft_link(client, tmp_path, monkeypatch):
    base, items, _, draft, _, grade = build_graph(client)
    v6 = client.get("/api/backups/workspace").raise_for_status().json()
    v6["version"] = 6
    record, = v6["sessions"]
    del record["deferred_questions"]
    for answer in record["answers"]:
        answer.pop("deferred_origin", None)
    del record["draft"]["deferred_question_id"], record["draft"]["deferred_revision_id"]
    raw = json.dumps(v6).encode()
    plan = preview(client, raw)
    assert plan["sessions"]["identical"] == 1
    restore(client, raw, plan).raise_for_status()
    assert get_item(client, base, items["pending"]) == items["pending"] and client.get(base + "/draft").json() == draft
    recover_to(tmp_path, monkeypatch, "v6.sqlite")
    restore(client, raw, preview(client, raw)).raise_for_status()
    assert client.get(base + "/deferred-questions").json()["total"] == 0
    assert "deferred_question" not in client.get(base + "/draft").json()
    assert client.get(base + "/scorecard").json()["items"] == grade["items"]


def test_v7_invalid_graph_conflicts_and_private_values(client, tmp_path, monkeypatch):
    base, items, _, _, published, _ = build_graph(client)
    doc = client.get("/api/backups/workspace").raise_for_status().json()
    queued = doc["sessions"][0]["deferred_questions"]
    index = {q["id"]: i for i, q in enumerate(queued)}
    p, f = index[items["pending"]["id"]], index[items["fulfilled"]["id"]]
    corruptions = [
        (p, {"parent_answer_id": str(uuid4())}), (p, {"material_sha256": "a"*64}),
        (p, {"status": "fulfilled"}), (p, {"child_answer_id": published["id"]}),
        (p, {"status": "fulfilled", "child_answer_id": published["id"]}),
        (p, {"id": items["fulfilled"]["id"]}), (f, {"child_answer_id": items["pending"]["parent_answer_id"]}),
        (f, {"needs_reconfirmation": True}),
    ]
    for n, fields in corruptions:
        invalid = deepcopy(doc)
        invalid["sessions"][0]["deferred_questions"][n].update(fields)
        response = client.post("/api/backups/preview", json=invalid)
        assert response.status_code == 422 and items["pending"]["question"] not in response.text
    bad_draft = deepcopy(doc)
    bad_draft["sessions"][0]["draft"]["deferred_question_id"] = items["fulfilled"]["id"]
    assert client.post("/api/backups/preview", json=bad_draft).status_code == 422
    incompatible = deepcopy(doc)
    incompatible["version"] = 6
    assert client.post("/api/backups/preview", json=incompatible).status_code == 422
    # The incoming question ID is already owned by a different interview, with entirely different exchange IDs.
    recover_to(tmp_path, monkeypatch, "collision.sqlite")
    local, (aid, _) = prepare(client)
    client.post(local + "/deferred-questions", json={"id": items["pending"]["id"], "parent_answer_id": aid,
                "question": "Other private question", "expected_material": receipt(client, local, aid)}).raise_for_status()
    response = client.post("/api/backups/preview?include_conflict_reasons=true", json=doc).raise_for_status()
    assert response.json()["conflicts"][0]["reasons"] == ["linked_id_in_use"]
    assert "Other private question" not in response.text
    assert restore(client, json.dumps(doc).encode(), preview(client, json.dumps(doc).encode())).status_code == 409
    assert client.get(base).status_code == 404
