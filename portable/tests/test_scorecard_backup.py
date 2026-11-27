"""Workspace backup and restore coverage for per-session rubric scorecards."""
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import json
from uuid import uuid4

import pytest

from api import access, backup_schema, retention_policy, store
from backup_requests import client, create_session, preview, restore


def fresh_workspace(tmp_path, monkeypatch, name="destination.sqlite"):
    target = tmp_path / name
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))


def create_role_with_rubric(client):
    response = client.post("/api/roles", json={
        "name": "Staff Systems Engineer",
        "description": "Reliability and storage.",
        "questions": ["Explain WAL recovery."],
        "policy": "No external assistance.",
        "rubric": [
            {"id": "sys-design", "criterion": "System Design", "weight": 3},
            {"id": "testing", "criterion": "Testing Rigor", "weight": 2},
        ],
    })
    response.raise_for_status()
    return response.json()


def create_role_session(client, role, candidate="Ada Lovelace"):
    response = client.post("/api/sessions", json={
        "candidate": candidate,
        "role": role["name"],
        "role_id": role["id"],
        "policy": "No external assistance.",
        "consent": True,
    })
    response.raise_for_status()
    return response.json()["id"]


def save_scorecard(client, sid, items):
    response = client.put(f"/api/sessions/{sid}/scorecard", json={"items": items})
    response.raise_for_status()
    return response.json()


def get_scorecard(client, sid):
    response = client.get(f"/api/sessions/{sid}/scorecard")
    response.raise_for_status()
    return response.json()


def test_scorecard_roundtrip_order_trash_analytics_and_audit(client, tmp_path, monkeypatch):
    actor_id = "urn:partner:Rubric Reviewer 09/" + "x" * 350

    async def actor(request):
        return (actor_id, actor_id)

    async def admin_session(request):
        return ({"id": "admin-1", "email": "admin@example.test", "role": "admin"}, "admin-token")

    role = create_role_with_rubric(client)
    monkeypatch.setattr(access, "optional_actor", actor)
    monkeypatch.setattr(access, "require_admin_session", admin_session)
    monkeypatch.setattr(store, "timestamp", lambda: "2026-08-05T14:22:10.654321+00:00")
    active = create_role_session(client, role, candidate="Active Candidate")
    archived = create_role_session(client, role, candidate="Trashed Candidate")
    ungraded = create_role_session(client, role, candidate="Ungraded Candidate")

    # Non-alphabetical ad-hoc order tests exact rowid display preservation.
    save_scorecard(client, active, [
        {"criterion_id": "adhoc-z", "criterion_label": "Zeta Failover", "weight": 2, "rating": 4,
         "rationale": "Résumé:\n\tHandled split-brain recovery cleanly."},
        {"criterion_id": "sys-design", "criterion_label": "System Design", "weight": 3, "rating": 5,
         "rationale": "Clear WAL and checkpoint design."},
        {"criterion_id": "adhoc-a", "criterion_label": "Alpha Latency", "weight": 1, "rating": 3,
         "rationale": ""},
    ])
    save_scorecard(client, archived, [
        {"criterion_id": "testing", "criterion_label": "Testing Rigor", "weight": 2, "rating": 2,
         "rationale": "Missed fault injection coverage."},
    ])
    expected_scorecards = {sid: get_scorecard(client, sid) for sid in (active, archived, ungraded)}
    expected_print = client.get(f"/api/sessions/{active}/print").raise_for_status().text
    expected_report = client.get(f"/api/sessions/{active}/report").raise_for_status().text
    expected_audit = client.get(f"/api/admin/compliance/sessions/{active}/audit").raise_for_status().json()
    client.post(f"/api/sessions/{archived}/trash").raise_for_status()
    expected_cohort = client.get("/api/analytics/cohorts").raise_for_status().json()["summary"]

    single = client.get("/api/backups/workspace", params={"session_id": archived}).raise_for_status().content
    raw = client.get("/api/backups/workspace").raise_for_status().content
    doc = json.loads(raw)
    assert doc["version"] == json.loads(single)["version"] == 6
    by_id = {s["id"]: s for s in doc["sessions"]}
    assert [i["criterion_id"] for i in by_id[active]["scorecard_items"]] == ["adhoc-z", "sys-design", "adhoc-a"]
    assert all("session_id" not in i for s in doc["sessions"] for i in s["scorecard_items"])
    assert by_id[active]["scorecard_items"][0]["updated_by"] == actor_id
    assert by_id[ungraded]["scorecard_items"] == []

    fresh_workspace(tmp_path, monkeypatch)
    single_plan = preview(client, single)
    assert single_plan["scorecard_items"] == 1 and single_plan["trashed"] == 1
    assert "Missed fault injection" not in json.dumps(single_plan)
    restore(client, single, single_plan).raise_for_status()

    plan = preview(client, raw)
    assert plan["scorecard_items"] == 4
    assert plan["sessions"] == {"new": 2, "identical": 1, "conflict": 0}
    for secret in ("Résumé", "Zeta Failover", actor_id):
        assert secret not in json.dumps(plan)
    assert restore(client, raw, plan).json()["scorecard_items"] == 4
    assert json.loads(client.get("/api/backups/workspace").content) == doc
    assert preview(client, raw)["sessions"] == {"new": 0, "identical": 3, "conflict": 0}

    assert client.get("/api/analytics/cohorts").raise_for_status().json()["summary"]["avg_scorecard_pct"] == expected_cohort["avg_scorecard_pct"]
    restored_audit = client.get(f"/api/admin/compliance/sessions/{active}/audit").raise_for_status().json()
    assert restored_audit["counts"] == expected_audit["counts"]
    assert restored_audit["counts"]["scorecards"] == 3
    assert restored_audit["timeline"] == expected_audit["timeline"]

    marker, = client.get("/api/trash").json()["items"]
    client.post(f"/api/trash/{archived}/restore", json={"operation_version": marker["operation_version"]}).raise_for_status()
    assert {sid: get_scorecard(client, sid) for sid in expected_scorecards} == expected_scorecards
    assert [i["criterion_id"] for i in get_scorecard(client, active)["items"]] == [
        "sys-design", "testing", "adhoc-z", "adhoc-a",
    ]
    restored_print = client.get(f"/api/sessions/{active}/print").raise_for_status().text
    assert restored_print == expected_print
    assert restored_print.index("Zeta Failover") < restored_print.index("System Design") < restored_print.index("Alpha Latency")
    assert client.get(f"/api/sessions/{active}/report").raise_for_status().text == expected_report


@pytest.mark.parametrize("preserve_aggregates", [False, True])
def test_retention_anonymized_scorecards_roundtrip(client, tmp_path, monkeypatch, preserve_aggregates):
    sid = create_session(client)
    rationale = "Candidate explained lock contention clearly."
    save_scorecard(client, sid, [{
        "criterion_id": "concurrency", "criterion_label": "Concurrency", "weight": 3, "rating": 4, "rationale": rationale,
    }])
    client.post(f"/api/sessions/{sid}/finish").raise_for_status()
    old = (datetime.now(timezone.utc) - timedelta(days=200)).isoformat()
    with store.connection(write=True) as db:
        db.execute("UPDATE sessions SET created_at=? WHERE id=?", (old, sid))
        db.execute("UPDATE session_context SET ended_at=? WHERE session_id=?", (old, sid))
        db.execute(
            """INSERT INTO retention_policies(
                   id,anonymize_after_days,purge_trashed_after_days,preserve_scorecard_aggregates,enabled,updated_by,updated_at
               ) VALUES('default',90,0,?,1,'test',?)
               ON CONFLICT(id) DO UPDATE SET anonymize_after_days=90,preserve_scorecard_aggregates=excluded.preserve_scorecard_aggregates,enabled=1""",
            (1 if preserve_aggregates else 0, old),
        )
        result = retention_policy.execute_retention_job(db, dry_run=False, actor_email="job@example.test")
    assert result["anonymized_session_ids"] == [sid]

    expected = get_scorecard(client, sid)
    raw = client.get("/api/backups/workspace").raise_for_status().content
    exported_item, = json.loads(raw)["sessions"][0]["scorecard_items"]
    assert exported_item["rationale"] == (rationale if preserve_aggregates else "")
    assert (exported_item["weight"], exported_item["rating"]) == (3, 4)

    fresh_workspace(tmp_path, monkeypatch, name=f"ret-{preserve_aggregates}.sqlite")
    plan = preview(client, raw)
    assert plan["scorecard_items"] == 1
    restore(client, raw, plan).raise_for_status()
    assert get_scorecard(client, sid) == expected


def test_two_sessions_sharing_criterion_id_restore_without_collision(client, tmp_path, monkeypatch):
    role = create_role_with_rubric(client)
    first = create_role_session(client, role, candidate="First Candidate")
    second = create_role_session(client, role, candidate="Second Candidate")
    save_scorecard(client, first, [{
        "criterion_id": "sys-design", "criterion_label": "System Design", "weight": 3, "rating": 5, "rationale": "Strong.",
    }])
    save_scorecard(client, second, [{
        "criterion_id": "sys-design", "criterion_label": "System Design", "weight": 3, "rating": 2, "rationale": "Shallow.",
    }])
    expected = {sid: get_scorecard(client, sid) for sid in (first, second)}
    raw = client.get("/api/backups/workspace").raise_for_status().content

    fresh_workspace(tmp_path, monkeypatch)
    plan = preview(client, raw)
    assert plan["scorecard_items"] == 2 and plan["sessions"] == {"new": 2, "identical": 0, "conflict": 0}
    restore(client, raw, plan).raise_for_status()
    assert {sid: get_scorecard(client, sid) for sid in expected} == expected


@pytest.mark.parametrize("version", [1, 2, 3, 4])
def test_legacy_backups_preserve_local_scorecards_and_keep_older_checks(client, version):
    sid = create_session(client)
    doc = client.get("/api/backups/workspace").json()
    doc["version"] = version
    del doc["sessions"][0]["privacy"]
    del doc["sessions"][0]["rubric_snapshot"]
    record = doc["sessions"][0]
    if version < 4:
        del record["handoff_notes"]
    if version < 3:
        del record["assignment"]
    assert client.post("/api/backups/preview", json=doc).status_code == 422

    del record["scorecard_items"]
    new_id = str(uuid4())
    doc["sessions"].append({**record, "id": new_id})
    saved = save_scorecard(client, sid, [{
        "criterion_id": "coding", "criterion_label": "Coding", "weight": 2, "rating": 4, "rationale": "Clean tests.",
    }])
    raw = json.dumps(doc).encode()
    plan = preview(client, raw)
    assert plan["scorecard_items"] == 0 and plan["sessions"] == {"new": 1, "identical": 1, "conflict": 0}
    restore(client, raw, plan).raise_for_status()
    assert get_scorecard(client, sid) == saved
    assert get_scorecard(client, new_id)["items"] == [] and get_scorecard(client, new_id)["weighted_score_pct"] is None

    client.put(f"/api/sessions/{sid}/assignment", json={"assignee_email": "lead@example.test"}).raise_for_status()
    assert preview(client, raw)["sessions"]["conflict"] == (1 if version >= 3 else 0)
    client.delete(f"/api/sessions/{sid}/assignment").raise_for_status()
    client.post(f"/api/sessions/{sid}/handoff-notes", json={"category": "observation", "body": "Follow up."}).raise_for_status()
    assert preview(client, raw)["sessions"]["conflict"] == (1 if version == 4 else 0)


@pytest.mark.parametrize("starts_scored", [False, True])
def test_v5_scorecard_mutation_conflicts_and_rolls_back_atomically(client, starts_scored):
    sid = create_session(client)
    if starts_scored:
        save_scorecard(client, sid, [
            {"criterion_id": "first", "criterion_label": "First", "weight": 2, "rating": 4, "rationale": "Good."},
            {"criterion_id": "second", "criterion_label": "Second", "weight": 1, "rating": 3, "rationale": "Fair."},
        ])
    doc = client.get("/api/backups/workspace").json()
    if starts_scored:
        for field, value in (
            ("rating", 5), ("rationale", "Changed."), ("weight", 5), ("criterion_label", "Renamed"),
            ("criterion_id", "renamed-id"), ("updated_by", "other@example.test"), ("updated_at", "2026-10-10T08:00:00Z"),
        ):
            altered = deepcopy(doc)
            altered["sessions"][0]["scorecard_items"][0][field] = value
            assert preview(client, json.dumps(altered).encode())["sessions"]["conflict"] == 1
        reordered = deepcopy(doc)
        reordered["sessions"][0]["scorecard_items"].reverse()
        assert preview(client, json.dumps(reordered).encode())["sessions"]["conflict"] == 1

    other_id = str(uuid4())
    doc["sessions"].append({**doc["sessions"][0], "id": other_id, "scorecard_items": []})
    raw = json.dumps(doc).encode()
    plan = preview(client, raw)
    assert plan["sessions"] == {"new": 1, "identical": 1, "conflict": 0}
    if starts_scored:
        save_scorecard(client, sid, [])
    else:
        save_scorecard(client, sid, [
            {"criterion_id": "added", "criterion_label": "Added", "weight": 1, "rating": 5, "rationale": "New."},
        ])
    assert restore(client, raw, plan).status_code == 409
    assert preview(client, raw)["sessions"]["conflict"] == 1
    assert client.get(f"/api/sessions/{other_id}").status_code == 404


def test_scorecard_field_validation_blocks_invalid_input_without_leaking_text(client):
    sid = create_session(client)
    save_scorecard(client, sid, [{
        "criterion_id": "design", "criterion_label": "Design", "weight": 2, "rating": 4, "rationale": "Solid.",
    }])
    doc = client.get("/api/backups/workspace").json()
    cases = (
        ("rating", 0), ("rating", 6), ("rating", True), ("rating", 3.0), ("rating", "3"),
        ("weight", 0), ("weight", 101), ("weight", False), ("weight", 2.5), ("weight", "2"),
        ("criterion_id", "SecretId\x07"), ("criterion_id", " design "), ("criterion_id", ""),
        ("criterion_label", "SecretLabel\nline"), ("criterion_label", " SecretLabel "),
        ("rationale", "SecretRationale\x07"), ("rationale", " SecretRationale "),
        ("rationale", "SecretRationale" + "z" * 1990),
        ("updated_by", "  "), ("updated_by", "SecretActor\x85"),
        ("updated_at", "2026-01-01T00:00:00"), ("session_id", sid),
    )
    for field, value in cases:
        invalid = deepcopy(doc)
        invalid["sessions"][0]["scorecard_items"][0][field] = value
        reply = client.post("/api/backups/preview", json=invalid)
        assert reply.status_code == 422, (field, value)
        for secret in ("SecretId", "SecretLabel", "SecretRationale", "SecretActor"):
            assert secret not in reply.text

    duplicate = deepcopy(doc)
    duplicate["sessions"][0]["scorecard_items"] *= 2
    assert client.post("/api/backups/preview", json=duplicate).status_code == 422

    too_many = deepcopy(doc)
    base_item = too_many["sessions"][0]["scorecard_items"][0]
    too_many["sessions"][0]["scorecard_items"] = [{**base_item, "criterion_id": f"c-{i}"} for i in range(26)]
    assert client.post("/api/backups/preview", json=too_many).status_code == 422

    del doc["sessions"][0]["scorecard_items"]
    assert client.post("/api/backups/preview", json=doc).status_code == 422


@pytest.mark.parametrize("corruption", ["updated_by", "rationale", "too_many_rows"])
def test_unrepresentable_stored_scorecards_fail_closed_without_leakage(client, corruption):
    sid = create_session(client)
    save_scorecard(client, sid, [{
        "criterion_id": "design", "criterion_label": "PrivateCriterionLabel", "weight": 2, "rating": 4,
        "rationale": "Initial rationale.",
    }])
    doc = client.get("/api/backups/workspace").json()
    other_id = str(uuid4())
    doc["sessions"].append({**doc["sessions"][0], "id": other_id, "scorecard_items": []})
    raw = json.dumps(doc).encode()
    plan = preview(client, raw)

    with store.connection(write=True) as db:
        if corruption == "updated_by":
            db.execute("UPDATE session_scorecards SET updated_by=? WHERE session_id=?", ("SecretActor\x85suffix", sid))
        elif corruption == "rationale":
            db.execute("UPDATE session_scorecards SET rationale=? WHERE session_id=?", ("SecretRationale\x07tail", sid))
        else:
            now = store.timestamp()
            for idx in range(25):
                db.execute(
                    """INSERT INTO session_scorecards(
                           session_id,criterion_id,criterion_label,weight,rating,rationale,updated_by,updated_at
                       ) VALUES(?,?,?,?,?,?,?,?)""",
                    (sid, f"extra-{idx}", "PrivateCriterionLabel", 1, 3, "SecretRationale", "SecretActor", now),
                )

    for params in ({}, {"session_id": sid}):
        blocked = client.get("/api/backups/workspace", params=params)
        assert blocked.status_code == 409
        detail = blocked.json()["detail"]
        assert sid in detail and "SQLite" in detail
        for secret in ("SecretActor", "SecretRationale", "PrivateCriterionLabel"):
            assert secret not in detail

    assert preview(client, raw)["sessions"] == {"new": 1, "identical": 0, "conflict": 1}
    assert restore(client, raw, plan).status_code == 409
    assert client.get(f"/api/sessions/{other_id}").status_code == 404

    v4 = deepcopy(doc)
    v4["version"] = 4
    for record in v4["sessions"]:
        del record["privacy"]
        del record["rubric_snapshot"]
        del record["scorecard_items"]
    assert preview(client, json.dumps(v4).encode())["sessions"] == {"new": 1, "identical": 1, "conflict": 0}


def test_scorecard_export_enforces_size_limit(client, monkeypatch):
    sid = create_session(client)
    save_scorecard(client, sid, [{
        "criterion_id": "design", "criterion_label": "Design", "weight": 1, "rating": 4, "rationale": "x" * 200,
    }])
    monkeypatch.setattr(backup_schema, "LIMIT", 120)
    assert client.get("/api/backups/workspace", params={"session_id": sid}).status_code == 413


def test_absent_scorecard_table_blocks_scored_restore_and_allows_empty_v5(client, tmp_path, monkeypatch):
    scored = create_session(client)
    save_scorecard(client, scored, [{
        "criterion_id": "design", "criterion_label": "Design", "weight": 2, "rating": 5, "rationale": "Clear.",
    }])
    scored_raw = client.get("/api/backups/workspace", params={"session_id": scored}).raise_for_status().content
    empty = create_session(client)
    empty_raw = client.get("/api/backups/workspace", params={"session_id": empty}).raise_for_status().content

    fresh_workspace(tmp_path, monkeypatch)
    scored_plan = preview(client, scored_raw)
    empty_plan = preview(client, empty_raw)
    with store.connection(write=True) as db:
        db.execute("DROP TABLE session_scorecards")

    assert restore(client, scored_raw, scored_plan).status_code == 409
    assert client.get("/api/sessions").json() == []

    assert restore(client, empty_raw, empty_plan).status_code == 200
    assert [s["id"] for s in client.get("/api/sessions").json()] == [empty]

    fresh = create_session(client)
    exported = client.get("/api/backups/workspace", params={"session_id": fresh}).raise_for_status().json()
    assert exported["version"] == 6 and exported["sessions"][0]["scorecard_items"] == []
