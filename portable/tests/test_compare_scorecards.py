from contextlib import contextmanager
from html import escape
import sqlite3
from unittest.mock import AsyncMock

import pytest
from fastapi.testclient import TestClient

from api import access, report, store
from api.main import app


PATH = "/api/interviews/compare"
LABEL = "Méthode | <panel>"
RATIONALE = "Retained Δ.\n# [marker](https://example.test) <private>"
AUTHOR = "private-author@example.test"


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "accounts.sqlite"))
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(access, "optional_actor", AsyncMock(return_value=("fixture-id", AUTHOR)))
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def session(client, candidate, role=None):
    payload = {"role": "Ad hoc", "candidate": candidate, "policy": "Manual permitted", "consent": True}
    if role:
        payload.update(role=role["name"], role_id=role["id"])
    return client.post("/api/sessions", json=payload).raise_for_status().json()["id"]


def item(key="c", label=LABEL, rating=2, weight=3, rationale=RATIONALE):
    return {"criterion_id": key, "criterion_label": label, "weight": weight, "rating": rating, "rationale": rationale}


def write_scores(client, sid, items):
    return client.put(f"/api/sessions/{sid}/scorecard", json={"items": items}).raise_for_status().json()


def exported(client, ids, flags):
    base = {"session_ids": ids, **flags}
    md = client.post(PATH + "/dossier", json={**base, "format": "markdown"}).raise_for_status().text
    html = client.post(PATH + "/dossier", json={**base, "format": "html"}).raise_for_status().text
    printed = client.get(PATH + "/print", params={"ids": ",".join(ids), **flags}).raise_for_status()
    assert printed.text == html and printed.headers["cache-control"] == "no-store"
    return md, html


def test_recorded_scores_stay_with_interview_and_follow_stored_order(client):
    current = {"id": "c", "criterion": "Original role criterion", "weight": 3}
    role = client.post("/api/roles", json={"name": "Engineer", "rubric": [current]}).raise_for_status().json()
    first = session(client, "First reviewer case", role)
    adhoc = item("custom", "First recorded item", 4, 1, "")
    write_scores(client, first, [adhoc, item()])
    current.update(criterion="Current role guidance", weight=8)
    changed = client.put("/api/roles/" + role["id"], json={**role, "rubric": [current]}).raise_for_status().json()
    second = session(client, "Second reviewer case", changed)
    newer = item(label="Second recorded criterion", rating=5, weight=8, rationale="")
    write_scores(client, second, [newer])
    foreign = client.post("/api/roles", json={"name": "Other role", "rubric": [current]}).raise_for_status().json()
    third = session(client, "Third reviewer case", foreign)
    third_grade = item(label="Different scale", rating=1, weight=1, rationale="")
    write_scores(client, third, [third_grade])
    ungraded = session(client, "Ungraded case", role)
    ids = [third, second, first, ungraded]
    flags = {"include_scorecards": True, "include_rationales": True}
    result = client.post(PATH, json={"session_ids": ids, **flags}).raise_for_status().json()
    assert [s["id"] for s in result["sessions"]] == ids
    assert [s["scorecard"] for s in result["sessions"]] == [
        {"rated_count": 1, "weighted_score_pct": 20.0, "items": [third_grade]},
        {"rated_count": 1, "weighted_score_pct": 100.0, "items": [newer]},
        {"rated_count": 2, "weighted_score_pct": 50.0, "items": [adhoc, item()]},
        {"rated_count": 0, "weighted_score_pct": None, "items": []},
    ]
    assert result["rubric_criteria"] == []
    md, html = exported(client, [second, first, ungraded], flags)
    for content in (md, html):
        assert "Guidance from the current role template." in content and "Current role guidance" in content
        grades = content.split("Saved interview scorecards", 1)[1].split("Question slot comparison", 1)[0]
        assert grades.index("Second reviewer case") < grades.index("First reviewer case") < grades.index("Ungraded case")
        assert grades.index("First recorded item") < grades.index("Méthode")
        assert "50.0%" in grades and "No saved ratings." in grades and AUTHOR not in content
    assert report.literal(RATIONALE) in md and report.heading(LABEL) in md
    assert escape(RATIONALE) in html and escape(LABEL) in html and "<private>" not in html


def test_private_columns_are_only_read_on_explicit_opt_in(client, monkeypatch):
    first, second = session(client, "One"), session(client, "Two")
    write_scores(client, first, [item()])
    ids = [first, second]
    reads = set()
    connection = store.connection

    @contextmanager
    def captured(*args, **kwargs):
        def observe(action, table, column, *_):
            if action == sqlite3.SQLITE_READ and table == "session_scorecards":
                reads.add(column.lower())
            return sqlite3.SQLITE_OK

        with connection(*args, **kwargs) as db:
            db.set_authorizer(observe)
            yield db

    monkeypatch.setattr(store, "connection", captured)
    for flags, expect_scores, expect_reasons in [
        ({}, False, False), ({"include_notes": True, "include_excerpts": True}, False, False),
        ({"include_scorecards": True}, True, False), ({"include_scorecards": True, "include_rationales": True}, True, True),
    ]:
        reads.clear()
        doc = client.post(PATH, json={"session_ids": ids, **flags}).raise_for_status().json()
        card = doc["sessions"][0].get("scorecard")
        assert (card is not None) == expect_scores
        if card:
            assert ("rationale" in card["items"][0]) == expect_reasons
        for content in exported(client, ids, flags):
            assert ("Saved interview scorecards" in content) == expect_scores
            assert ("Retained Δ." in content) == expect_reasons
            assert AUTHOR not in content
        assert bool(reads) == expect_scores
        assert ("rationale" in reads) == expect_reasons
        assert reads.isdisjoint({"updated_by", "updated_at"})


def test_old_scorecard_schema_and_invalid_options(client):
    ids = [session(client, "One"), session(client, "Two")]
    with store.connection(write=True) as db:
        db.execute("DROP TABLE session_scorecards")
    flags = {"include_scorecards": True, "include_rationales": True}
    result = client.post(PATH, json={"session_ids": ids, **flags}).raise_for_status().json()
    assert all(s["scorecard"] == {"rated_count": 0, "weighted_score_pct": None, "items": []} for s in result["sessions"])
    assert all("No saved ratings." in content for content in exported(client, ids, flags))
    with store.connection() as db:
        assert db.execute("SELECT 1 FROM sqlite_master WHERE name='session_scorecards'").fetchone() is None
    bad = {"session_ids": ids, "include_rationales": True}
    assert client.post(PATH, json=bad).status_code == 422
    assert client.post(PATH + "/dossier", json={**bad, "format": "markdown"}).status_code == 422
    assert client.get(PATH + "/print", params={"ids": ",".join(ids), "include_rationales": "true"}).status_code == 422
    assert client.post(PATH, json={"session_ids": ids, "include_scorecards": "true"}).status_code == 422


def test_invalid_stored_weight_blocks_opted_in_comparisons_without_disclosure(client):
    ids = [session(client, "One"), session(client, "Two")]
    write_scores(client, ids[0], [item()])
    with store.connection(write=True) as db:
        db.execute("UPDATE session_scorecards SET weight=101 WHERE session_id=?", (ids[0],))
    assert client.post(PATH, json={"session_ids": ids}).status_code == 200
    flags = {"include_scorecards": True, "include_rationales": True}
    for response in (client.post(PATH, json={"session_ids": ids, **flags}),
                     client.post(PATH + "/dossier", json={"session_ids": ids, "format": "markdown", **flags}),
                     client.get(PATH + "/print", params={"ids": ",".join(ids), **flags})):
        assert response.status_code == 409
        assert response.json() == {"detail": "A saved criterion has invalid scorecard data."}
