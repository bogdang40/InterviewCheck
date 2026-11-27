"""Calibration counts follow the question that an interview actually planned."""
import json

from api import access, store
from api.retention_anonymizer import SessionAnonymizer
from backup_requests import client


def create_interview(client, role, name):
    return client.post("/api/sessions", json={"candidate": name, "role": role["name"], "role_id": role["id"],
                       "consent": True, "policy": "Manual permitted."}).raise_for_status().json()["id"]


def add_answer(client, sid, wording, slot=None):
    return client.post(f"/api/sessions/{sid}/answers", json={
        "question": wording, "answer": "Synthetic example.", "planned_slot": slot,
    }).raise_for_status().json()["id"]


def test_calibration_separates_prompt_revisions_and_keeps_slot_edits_together(client, monkeypatch):
    name = "Engineer"
    first_prompt, second_prompt = "Check the initial reading.", "Compare the second reading."
    role = client.post("/api/roles", json={"name": name, "questions": [first_prompt, first_prompt]}).raise_for_status().json()
    first = create_interview(client, role, "First")
    a1 = add_answer(client, first, "First interviewer wording", 1)
    add_answer(client, first, "A follow-up in that slot", 1)
    add_answer(client, first, "Different slot with the same words", 2)
    add_answer(client, first, first_prompt)
    revision = {"name": name, "questions": [second_prompt, first_prompt]}
    client.put(f"/api/roles/{role['id']}", json=revision).raise_for_status()
    second = create_interview(client, role, "Second")
    add_answer(client, second, "Second interviewer wording", 1)
    add_answer(client, second, first_prompt, 2)
    actor = "first@example.test"

    async def current_actor(request):
        return actor, actor

    monkeypatch.setattr(access, "optional_actor", current_actor)
    route = f"/api/sessions/{first}/answers/{a1}"
    client.patch(route, json={"disposition": "explained", "note": "Baseline verified."}).raise_for_status()
    actor = "second@example.test"
    client.patch(route, json={"disposition": "unresolved", "note": "Needs clarification."}).raise_for_status()
    url = f"/api/roles/{role['id']}/calibration"
    data = client.get(url).raise_for_status().json()
    assert data["summary"]["answer_count"] == 6
    assert data["summary"]["multi_reviewer_disagreements"] == 1
    grouped = {(g["planned_slot"], g["question_source"], g["question"]): g for g in data["question_breakdown"]}
    assert {key: row["answer_count"] for key, row in grouped.items()} == {
        (1, "planned", first_prompt): 2, (1, "planned", second_prompt): 1,
        (2, "planned", first_prompt): 2, (None, "recorded", first_prompt): 1,
    }
    assert grouped[1, "planned", first_prompt]["disagreement_count"] == 1
    assert grouped[1, "planned", first_prompt]["reviewed_count"] == 1
    assert data["disagreements"][0]["question"] == "First interviewer wording"
    client.post(f"/api/sessions/{second}/trash").raise_for_status()
    after = client.get(url).raise_for_status().json()
    assert sum(row["answer_count"] for row in after["question_breakdown"]) == 4
    assert second_prompt not in [row["question"] for row in after["question_breakdown"]]


def test_missing_or_retained_plan_uses_only_recorded_wording(client):
    private_plan = "Historical planned wording"
    recorded = "Actual interview question"
    role = client.post("/api/roles", json={"name": "Technician", "questions": [private_plan]}).raise_for_status().json()
    legacy = create_interview(client, role, "Legacy")
    retained = create_interview(client, role, "Retained")
    for sid in (legacy, retained):
        add_answer(client, sid, recorded, 1)
    with store.connection(write=True) as db:
        db.execute("UPDATE session_context SET questions=? WHERE session_id=?", ("invalid historical JSON", legacy))
        SessionAnonymizer(db, retained).run(preserve_scorecard_aggregates=True, actor_email="local-operator", now_iso=store.timestamp())
    result = client.get(f"/api/roles/{role['id']}/calibration").raise_for_status()
    assert private_plan not in result.text
    row, = result.json()["question_breakdown"]
    assert (row["question_source"], row["question"], row["planned_slot"], row["answer_count"]) == ("recorded", recorded, 1, 2)


def test_restored_redacted_label_limits_display_without_recreating_a_retention_receipt(client, tmp_path, monkeypatch):
    original = "Original private prompt from the saved plan"
    role = client.post("/api/roles", json={"name": "Technician", "questions": [original]}).raise_for_status().json()
    sid = create_interview(client, role, "Example")
    add_answer(client, sid, "Recorded question", 1)
    with store.connection(write=True) as db:
        SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=True, actor_email="local-operator", now_iso=store.timestamp())
    url = f"/api/roles/{role['id']}/calibration"
    before = client.get(url).raise_for_status()
    assert original not in before.text
    document = client.get("/api/backups/workspace", params={"session_id": sid}).raise_for_status().json()
    document["version"] = 5
    for record in document["sessions"]:
        del record["deferred_questions"]
        del record["privacy"]
        del record["rubric_snapshot"]
    backup = json.dumps(document).encode()
    target = tmp_path / "recovered.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
    preview = client.post("/api/backups/preview", content=backup).raise_for_status().json()
    client.post("/api/backups/restore", content=backup, headers={"X-Backup-Preview": preview["fingerprint"]}).raise_for_status()
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM session_anonymizations").fetchone()[0] == 0
    assert client.get(url).raise_for_status().json()["question_breakdown"] == before.json()["question_breakdown"]

    other = create_interview(client, role, f"Candidate [Anonymized {sid[:8]}]")
    add_answer(client, other, "Another question", 1)
    rows = client.get(url).raise_for_status().json()["question_breakdown"]
    assert any(r["question"] == original and r["question_source"] == "planned" for r in rows)
