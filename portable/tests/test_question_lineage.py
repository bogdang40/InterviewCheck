import csv
from io import StringIO
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import lineage, store
from api.main import app

Q = "Identical planned prompt about forklifts?"
BODY = {"question": Q, "answer": "Measured the selected part."}


@pytest.fixture
def scoped(monkeypatch, tmp_path):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "workspace.sqlite"))
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as c:
        rid = c.post("/api/roles", json={"name": "Fixture", "questions": [Q, Q]}).json()["id"]
        session = {
            "candidate": "Synthetic",
            "role": "Fixture",
            "role_id": rid,
            "consent": True,
            "policy": "Notes permitted",
        }
        one, two = (c.post("/api/sessions", json=session).json()["id"] for _ in range(2))
        yield c, "/api/sessions/" + one, "/api/sessions/" + two, rid


def add(c, path, **fields):
    result = c.post(path + "/answers", json={**BODY, **fields})
    result.raise_for_status()
    return result.json()


def test_snapshot_slots_drafts_and_reports(scoped):
    c, path, _, rid = scoped
    manual = add(c, path)
    assert manual["planned_slot"] is None and manual["parent_answer_id"] is None
    first = add(c, path, planned_slot=1)
    second = add(c, path, planned_slot=2)
    c.put("/api/roles/" + rid, json={"name": "Fixture", "questions": ["Changed role?"]}).raise_for_status()
    assert [a["planned_slot"] for a in c.get(path).json()["answers"]] == [None, 1, 2]
    assert c.get(path).json()["planned_questions"] == [Q, Q]
    d = {
        "id": str(uuid4()),
        "question": "Tell me more",
        "parent_answer_id": second["id"],
        "expected_revision": 0,
    }
    saved = c.put(path + "/draft", json=d).json()
    assert saved["parent_answer_id"] == second["id"] and saved["planned_slot"] is None
    update = {"id": d["id"], "question": "Updated prompt", "expected_revision": saved["revision"]}
    updated = c.put(path + "/draft", json=update).json()
    assert updated["parent_answer_id"] == second["id"]
    result = c.post(
        path + "/draft/publish", json={**update, "answer": "OK", "expected_revision": updated["revision"]}
    )
    result.raise_for_status()
    child = result.json()
    assert child["parent_answer_id"] == second["id"] and child["planned_slot"] is None
    assert (
        c.post(
            path + "/draft/publish", json={**update, "answer": "OK", "expected_revision": updated["revision"]}
        ).json()["id"]
        == child["id"]
    )
    for suffix in ("/report", "/print"):
        text = c.get(path + suffix).text
        assert "Planned question 1" in text and "Planned question 2" in text
        assert "Follow up to question 3" in text and second["id"] in text
    table = list(csv.DictReader(StringIO(c.get("/api/exports/interviews.csv").text.lstrip("\ufeff"))))
    assert next(r for r in table if r["Exchange ID"] == first["id"])["Planned slot"] == "1"
    assert next(r for r in table if r["Exchange ID"] == child["id"])["Parent exchange ID"] == second["id"]
    brief = c.get(path + "/brief").json()
    assert Q not in str(brief["blocks"]) and second["id"] not in str(brief["blocks"])


def test_invalid_origins_and_cycle_do_not_change_prior_records(scoped):
    c, path, other, _ = scoped
    root = add(c, path)
    child = add(c, path, parent_answer_id=root["id"])
    leaf = add(c, path, parent_answer_id=child["id"])
    stranger = add(c, other)
    route = path + "/answers/" + root["id"]
    for data in (
        {"parent_answer_id": root["id"]},
        {"parent_answer_id": leaf["id"]},
        {"parent_answer_id": stranger["id"]},
        {"planned_slot": 3},
        {"planned_slot": True},
        {"planned_slot": 0},
        {"planned_slot": 1, "parent_answer_id": leaf["id"]},
    ):
        assert c.put(route, json={**BODY, **data, "expected_revision": 1}).status_code == 422
    assert c.get(route).json() == root
    link = path + "/answers/" + child["id"]
    edit = c.put(link, json={**BODY, "question": "Edited prompt"}).json()
    assert edit["parent_answer_id"] == root["id"]
    clear = c.put(link, json={**BODY, "parent_answer_id": None, "expected_revision": edit["revision"]}).json()
    assert clear["parent_answer_id"] is None and clear["planned_slot"] is None
    reassign = c.put(route, json={**BODY, "parent_answer_id": leaf["id"]}).json()
    assert reassign["parent_answer_id"] == leaf["id"]


def test_pre_lineage_records_and_webvtt_remain_unlinked(scoped):
    c, path, _, _ = scoped
    old = add(c, path)
    imported = c.post(
        path + "/imports/webvtt",
        json={
            "request_id": str(uuid4()),
            "transcript_sha256": "5" * 64,
            "candidate_speaker": "Test",
            "interviewer_speakers": ["Host"],
            "exchanges": [{"ordinal": 1, "start_ms": 0, "end_ms": 1000, **BODY}],
        },
    )
    imported.raise_for_status()
    for key in (old["id"], imported.json()["answer_ids"][0]):
        answer = c.get(path + "/answers/" + key).json()
        assert answer["parent_answer_id"] is None and answer["planned_slot"] is None
    with store.connection(write=True) as db:
        for table in ("answers", "session_drafts"):
            db.execute(f"ALTER TABLE {table} DROP COLUMN planned_slot")
            db.execute(f"ALTER TABLE {table} DROP COLUMN parent_answer_id")
    store.initialize(store.db_path())
    assert c.get(path + "/answers/" + old["id"]).json() == old


@pytest.mark.parametrize(
    "answers,draft",
    [
        ([{"id": "a", "parent_answer_id": "b"}, {"id": "b", "parent_answer_id": "a"}], None),
        ([{"id": "a", "parent_answer_id": "a"}], None),
        ([{"id": "a", "parent_answer_id": "missing"}], None),
        ([{"id": "a", "planned_slot": 2}], None),
        ([{"id": "a"}], {"id": "draft", "planned_slot": 1, "parent_answer_id": "a"}),
    ],
)
def test_restore_validator_rejects_corrupt_lineage(answers, draft):
    with pytest.raises(ValueError):
        lineage.validate_graph(["Slot"], answers, draft)


def test_restore_validator_supports_forward_order_and_long_chains():
    rows = [{"id": str(i), "parent_answer_id": str(i + 1)} for i in range(2200)]
    rows.append({"id": "2200", "planned_slot": 1})
    lineage.validate_graph(["Slot"], rows, {"id": "draft", "parent_answer_id": "0"})
