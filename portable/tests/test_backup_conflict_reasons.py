from contextlib import contextmanager
from copy import deepcopy
from uuid import uuid4

from api import backup_conflicts, backup_schema, store
from backup_requests import client, create_session


PREVIEW = "/api/backups/preview"
EXPLAIN = PREVIEW + "?include_conflict_reasons=true"


def snapshot(client):
    return client.get("/api/backups/workspace").raise_for_status().json()


def add_review_data(client, sid):
    path = f"/api/sessions/{sid}"
    client.put(path + "/assignment", json={"assignee_email": "private-assignee@example.test"}).raise_for_status()
    client.post(path + "/handoff-notes", json={"category": "concern", "body": "private handoff text"}).raise_for_status()
    client.put(path + "/scorecard", json={"items": [{"criterion_id": "x", "criterion_label": "Private criterion",
               "weight": 1, "rating": 3, "rationale": "private rationale"}]}).raise_for_status()


def test_opt_in_explains_multiple_session_sections_without_local_values(client):
    sid = create_session(client)
    doc = snapshot(client)
    doc["sessions"][0]["candidate"] = "Incoming label"
    add_review_data(client, sid)
    path = f"/api/sessions/{sid}"
    client.post(path + "/answers", json={"question": "Private question", "answer": "Private transcript",
                                         "references": []}).raise_for_status()
    client.put(path + "/draft", json={"id": str(uuid4()), "expected_revision": 0, "question": "Private draft"}).raise_for_status()

    legacy = client.post(PREVIEW, json=doc).raise_for_status()
    assert client.post(PREVIEW + "?include_conflict_reasons=false", json=doc).content == legacy.content
    sample = {"kind": "sessions", "id": sid, "label": "Incoming label"}
    assert legacy.json()["conflicts"] == [sample]
    response = client.post(EXPLAIN, json=doc).raise_for_status()
    categories = ["interview_details", "assignment", "handoff_notes", "scorecard_items", "exchanges", "draft"]
    assert response.json() == {**legacy.json(), "conflicts": [{**sample, "reasons": categories}]}
    assert "private" not in response.text.lower() and "local-operator" not in response.text


def test_role_reasons_cover_template_rubric_and_history(client):
    role = client.post("/api/roles", json={"name": "Kit", "questions": ["Initial?"]}).raise_for_status().json()
    doc = snapshot(client)
    client.put("/api/roles/" + role["id"], json={
        **role, "name": "Private local role", "change_note": "Private local history",
        "rubric": [{"id": "quality", "criterion": "Private rubric", "weight": 2}],
    }).raise_for_status()
    response = client.post(EXPLAIN, json=doc).raise_for_status()
    assert response.json()["conflicts"] == [{"kind": "roles", "id": role["id"], "label": "Kit",
                                              "reasons": ["role_template", "rubric", "role_history"]}]
    assert "private" not in response.text.lower()


def test_reasons_compare_only_data_the_file_version_recorded(client):
    sid = create_session(client)
    original = snapshot(client)
    add_review_data(client, sid)
    for version, expected in [(1, []), (2, []), (3, ["assignment"]), (4, ["assignment", "handoff_notes"]),
                              (5, ["assignment", "handoff_notes", "scorecard_items"])]:
        doc = deepcopy(original)
        doc["version"] = version
        for first, field in [(3, "assignment"), (4, "handoff_notes"), (5, "scorecard_items")]:
            if version < first:
                del doc["sessions"][0][field]
        plan = client.post(EXPLAIN, json=doc).raise_for_status().json()
        if expected:
            assert plan["sessions"]["conflict"] == 1 and plan["conflicts"][0]["reasons"] == expected
        else:
            assert plan["sessions"]["identical"] == 1 and plan["conflicts"] == []


def test_linked_id_conflicts_hide_existing_owners_and_colliding_ids(client):
    role = client.post("/api/roles", json={"name": "Local role"}).raise_for_status().json()
    sid = create_session(client)
    answer = client.post(f"/api/sessions/{sid}/answers", json={"question": "Which?", "answer": "Local text",
                                                                "references": []}).raise_for_status().json()
    doc = snapshot(client)
    new_role, new_session = str(uuid4()), str(uuid4())
    doc["roles"][0].update(id=new_role, name="Imported role")
    doc["sessions"][0].update(id=new_session, candidate="Imported interview")
    result = client.post(EXPLAIN, json=doc).raise_for_status()
    assert result.json()["conflicts"] == [
        {"kind": "roles", "id": new_role, "label": "Imported role", "reasons": ["linked_id_in_use"]},
        {"kind": "sessions", "id": new_session, "label": "Imported interview", "reasons": ["linked_id_in_use"]},
    ]
    for private in (role["id"], doc["roles"][0]["versions"][0]["id"], sid, answer["id"], "Local role", "Local text"):
        assert private not in result.text


def test_unrepresentable_stored_review_returns_neutral_reason_only(client):
    sid = create_session(client)
    doc = snapshot(client)
    add_review_data(client, sid)
    with store.connection(write=True) as db:
        db.execute("UPDATE session_assignments SET assigned_by=? WHERE session_id=?", ("private\nactor", sid))
    result = client.post(EXPLAIN, json=doc).raise_for_status()
    assert result.json()["conflicts"] == [{"kind": "sessions", "id": sid, "label": "Sample", "reasons": ["cannot_compare"]}]
    assert "private" not in result.text.lower()
    assert client.post(PREVIEW, json=doc).raise_for_status().json()["sessions"]["conflict"] == 1


def test_explanations_are_sampled_without_second_load_and_never_computed_on_restore(client, monkeypatch):
    for _ in range(23):
        create_session(client)
    doc = snapshot(client)
    # Keep one identical record to check it doesn't use the explanation path.
    for row in doc["sessions"][1:]:
        row["candidate"] = "Changed name"
    detailed, queries = [], []
    compare = backup_conflicts.changed_sections
    connection = store.connection

    @contextmanager
    def observed(*args, **kwargs):
        with connection(*args, **kwargs) as db:
            db.set_trace_callback(queries.append)
            yield db

    def compare_once(group, stored, incoming):
        detailed.append(incoming.id)
        return compare(group, stored, incoming)

    monkeypatch.setattr(store, "connection", observed)
    monkeypatch.setattr(backup_conflicts, "changed_sections", compare_once)
    bare = client.post(PREVIEW, json=doc).raise_for_status().json()
    normal_reads = [q for q in queries if q.lstrip().upper().startswith("SELECT")]
    assert len(bare["conflicts"]) == 20 and bare["sessions"] == {"identical": 1, "new": 0, "conflict": 22}
    assert not detailed
    queries.clear()
    rich = client.post(EXPLAIN, json=doc).raise_for_status().json()
    assert [q for q in queries if q.lstrip().upper().startswith("SELECT")] == normal_reads
    assert detailed == [row["id"] for row in rich["conflicts"]]
    assert rich["conflicts"] == [{**row, "reasons": ["interview_details"]} for row in bare["conflicts"]]
    detailed.clear()
    blocked = client.post("/api/backups/restore?include_conflict_reasons=true", json=doc,
                          headers={"X-Backup-Preview": bare["fingerprint"]})
    assert blocked.status_code == 409 and "reasons" not in blocked.text and not detailed


def test_future_top_level_field_never_exposes_its_name_or_value(client):
    class FutureSession(backup_schema.Session):
        new_private_field: str = ""

    create_session(client)
    original = FutureSession.model_validate(snapshot(client)["sessions"][0])
    altered = original.model_copy(update={"candidate": "Changed", "new_private_field": "Secret"})
    assert backup_conflicts.changed_sections("sessions", original, altered) == ["interview_details", "other_changes"]
