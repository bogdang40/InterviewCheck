"""Tests for M20-W1: cohort analytics, exports, tag catalog, and role_id feed filtering."""
import csv
from datetime import datetime, timedelta, timezone
from io import StringIO
import json
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import cohort_analytics, main, store


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "m20_cohort.sqlite"))
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    with TestClient(main.app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def _create_role(client: TestClient, name: str) -> dict:
    res = client.post("/api/roles", json={"name": name, "description": "", "questions": ["Q1?"]})
    res.raise_for_status()
    return res.json()


def _create_session(client: TestClient, candidate: str, role: dict | None = None) -> str:
    payload = {"candidate": candidate, "role": role["name"] if role else "Generalist", "policy": "Manuals permitted.", "consent": True}
    if role is not None:
        payload["role_id"] = role["id"]
    res = client.post("/api/sessions", json=payload)
    res.raise_for_status()
    return res.json()["id"]


def _add_answer(client: TestClient, sid: str, *, matched: bool, disposition: str = "pending") -> str:
    phrase = "Measure winding insulation resistance before powering the stator test rig."
    answer = phrase if matched else "I checked the manual and reviewed the operating steps carefully."
    refs = [{"label": "Manual", "text": phrase}] if matched else []
    res = client.post(f"/api/sessions/{sid}/answers", json={"question": "Q1?", "answer": answer, "references": refs})
    res.raise_for_status()
    aid = res.json()["id"]
    if disposition != "pending":
        note = "Candidate disclosed source use." if disposition == "disclosed" else "Reviewed."
        client.patch(f"/api/sessions/{sid}/answers/{aid}", json={"disposition": disposition, "note": note}).raise_for_status()
    return aid


def _set_scorecard(client: TestClient, sid: str, items: list[tuple[str, int, int]]) -> None:
    payload = {
        "items": [
            {"criterion_id": cid, "criterion_label": cid, "weight": weight, "rating": rating, "rationale": ""}
            for cid, weight, rating in items
        ]
    }
    client.put(f"/api/sessions/{sid}/scorecard", json=payload).raise_for_status()


def test_filter_validation_rejects_naive_and_inverted_ranges(client):
    assert client.get("/api/analytics/cohorts", params={"since": "2026-11-01T00:00:00"}).status_code == 422
    assert client.get("/api/analytics/cohorts", params={"until": "2026-11-02T00:00:00"}).status_code == 422
    assert client.get(
        "/api/analytics/cohorts",
        params={"since": "2026-11-05T12:00:00Z", "until": "2026-11-05T11:59:59Z"},
    ).status_code == 422
    assert client.get(
        "/api/analytics/cohorts/export",
        params={"since": "2026-11-01T00:00:00", "format": "json"},
    ).status_code == 422


def test_defensive_when_tags_and_scorecards_tables_absent(client):
    with store.connection(write=True) as db:
        db.execute("DROP TABLE IF EXISTS session_tags")
        db.execute("DROP TABLE IF EXISTS session_scorecards")

    assert client.get("/api/interviews/tags").json() == {"tags": []}
    empty_res = client.get("/api/analytics/cohorts")
    assert empty_res.status_code == 200
    body = empty_res.json()
    assert body["summary"] == {
        "session_count": 0, "active_count": 0, "finished_count": 0, "archived_count": 0,
        "answer_count": 0, "reviewed_count": 0, "pass_rate_pct": 0.0, "concern_rate_pct": 0.0,
        "explained_count": 0, "concern_count": 0,
        "avg_scorecard_pct": None, "scored_session_count": 0,
    }
    assert [b["count"] for b in body["score_buckets"]] == [0, 0, 0, 0, 0]
    assert client.get("/api/analytics/cohorts", params={"tag": "urgent"}).json()["summary"]["session_count"] == 0


def test_cohort_analytics_metrics_buckets_timeline_and_filters(client):
    role_a = _create_role(client, "Power Engineer")
    role_b = _create_role(client, "Controls Engineer")

    s_fin = _create_session(client, "Alice", role_a)
    _add_answer(client, s_fin, matched=True, disposition="explained")
    _add_answer(client, s_fin, matched=True, disposition="unresolved")
    client.post(f"/api/sessions/{s_fin}/finish").raise_for_status()
    _set_scorecard(client, s_fin, [("c1", 2, 5), ("c2", 1, 2)])  # (10+2)/(3*5)=80.0% -> 80_100

    s_act = _create_session(client, "Bob", role_a)
    _add_answer(client, s_act, matched=True, disposition="disclosed")
    _add_answer(client, s_act, matched=True, disposition="pending")
    _set_scorecard(client, s_act, [("c1", 1, 3)])  # 60.0% -> 60_80

    s_arch = _create_session(client, "Cara", role_b)
    _add_answer(client, s_arch, matched=False, disposition="explained")
    _set_scorecard(client, s_arch, [("c1", 1, 1)])  # 20.0% -> 20_40

    s_trash = _create_session(client, "Trashed", role_a)
    _add_answer(client, s_trash, matched=True, disposition="explained")

    with store.connection(write=True) as db:
        db.execute("UPDATE sessions SET created_at=? WHERE id=?", ("2026-10-01T10:00:00+00:00", s_fin))
        db.execute("UPDATE sessions SET created_at=? WHERE id=?", ("2026-10-02T23:30:00+00:00", s_act))
        db.execute("UPDATE sessions SET created_at=?, consent=0 WHERE id=?", ("2026-10-03T08:00:00+00:00", s_arch))

    client.post("/api/interviews/bulk/tag", json={"session_ids": [s_fin, s_act], "add": ["priority", "power"]}).raise_for_status()
    client.post("/api/interviews/bulk/tag", json={"session_ids": [s_arch, s_trash], "add": ["power"]}).raise_for_status()
    client.post(f"/api/sessions/{s_trash}/trash").raise_for_status()

    full = client.get("/api/analytics/cohorts").json()
    assert full["summary"] == {
        "session_count": 3, "active_count": 1, "finished_count": 1, "archived_count": 1,
        "answer_count": 5, "reviewed_count": 4, "pass_rate_pct": 50.0, "concern_rate_pct": 50.0,
        "explained_count": 2, "concern_count": 2,
        "avg_scorecard_pct": 53.3, "scored_session_count": 3,
    }
    buckets = {item["range"]: item["count"] for item in full["score_buckets"]}
    assert buckets == {"0_20": 0, "20_40": 1, "40_60": 0, "60_80": 1, "80_100": 1}
    assert full["timeline"] == [
        {"date": "2026-10-01", "sessions": 1, "finished": 1, "explained": 1, "concerns": 1},
        {"date": "2026-10-02", "sessions": 1, "finished": 0, "explained": 0, "concerns": 1},
        {"date": "2026-10-03", "sessions": 1, "finished": 0, "explained": 1, "concerns": 0},
    ]
    assert full["tag_breakdown"] == [
        {"tag": "power", "session_count": 3, "pass_rate_pct": 50.0, "avg_scorecard_pct": 53.3,
         "reviewed_count": 4, "explained_count": 2},
        {"tag": "priority", "session_count": 2, "pass_rate_pct": 33.3, "avg_scorecard_pct": 70.0,
         "reviewed_count": 3, "explained_count": 1},
    ]
    by_sid = {row["session_id"]: row for row in full["candidates"]}
    assert set(by_sid.keys()) == {s_fin, s_act, s_arch}
    assert by_sid[s_act]["pending_count"] == 1 and by_sid[s_act]["concern_count"] == 1
    assert by_sid[s_fin]["weighted_score_pct"] == 80.0

    # Filter by role_id, lifecycle, tag, and timezone-offset since/until (+02:00).
    by_role = client.get("/api/analytics/cohorts", params={"role_id": role_a["id"], "lifecycle": "finished"}).json()
    assert [c["session_id"] for c in by_role["candidates"]] == [s_fin]
    by_tag = client.get("/api/analytics/cohorts", params={"tag": "priority"}).json()
    assert by_tag["summary"]["session_count"] == 2
    by_window = client.get(
        "/api/analytics/cohorts",
        params={"since": "2026-10-03T01:00:00+02:00", "until": "2026-10-03T02:00:00+02:00"},
    ).json()
    assert [c["session_id"] for c in by_window["candidates"]] == [s_act]


def test_timeline_caps_at_latest_30_dates_and_candidates_at_200(client):
    role = _create_role(client, "Scale Role")
    base = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)
    with store.connection(write=True) as db:
        for idx in range(205):
            sid = str(uuid4())
            created = (base + timedelta(days=idx % 32, minutes=idx)).isoformat()
            db.execute(
                "INSERT INTO sessions(id, candidate, role, policy, consent, created_at) VALUES (?,?,?,?,?,?)",
                (sid, f"Cand {idx:03d}", role["name"], "", 1, created),
            )
            db.execute("INSERT INTO session_context(session_id, role_id, questions, permitted_sources) VALUES (?,?,?,?)", (sid, role["id"], "[]", "[]"))
            tag = f"tag-{idx % 22:02d}"
            db.execute("INSERT INTO session_tags(session_id, tag, created_at) VALUES (?,?,?)", (sid, tag, created))

    data = client.get("/api/analytics/cohorts").json()
    assert data["summary"]["session_count"] == 205
    assert len(data["candidates"]) == 200
    assert len(data["timeline"]) == 30
    assert data["timeline"][0]["date"] == "2026-01-03"
    assert data["timeline"][-1]["date"] == "2026-02-01"
    assert len(data["tag_breakdown"]) == 20
    assert cohort_analytics._bucket_key(15.0) == "0_20"
    assert cohort_analytics._bucket_key(40.0) == "40_60"
    assert cohort_analytics._bucket_key(100.0) == "80_100"

    csv_rows = list(csv.reader(StringIO(client.get("/api/analytics/cohorts/export").content.decode("utf-8-sig"))))
    assert len(csv_rows) == 206


def test_csv_formula_escaping_and_json_export(client):
    role = _create_role(client, "+RoleFormula")
    sid = _create_session(client, "=1+1", role)
    client.post("/api/interviews/bulk/tag", json={"session_ids": [sid], "add": ["@tag"]}).raise_for_status()

    csv_res = client.get("/api/analytics/cohorts/export", params={"format": "csv"})
    assert csv_res.status_code == 200
    assert csv_res.headers["cache-control"] == "no-store"
    assert 'filename="cohort-analytics.csv"' in csv_res.headers["content-disposition"]
    text = csv_res.content.decode("utf-8-sig")
    rows = list(csv.reader(StringIO(text)))
    assert len(rows) == 2
    assert rows[1][1] == "'=1+1"
    assert rows[1][2] == "'+RoleFormula"
    assert rows[1][7] == "'@tag"

    json_res = client.get("/api/analytics/cohorts/export", params={"format": "json"})
    assert json_res.status_code == 200
    assert json_res.headers["cache-control"] == "no-store"
    assert 'filename="cohort-analytics.json"' in json_res.headers["content-disposition"]
    doc = json.loads(json_res.content.decode("utf-8"))
    assert doc["format"] == "interviewcheck.cohort_analytics"
    assert doc["summary"]["session_count"] == 1
    assert doc["candidates"][0]["candidate"] == "=1+1"


def test_interviews_tags_and_role_id_feed_filtering(client):
    role_1 = _create_role(client, "Electrical")
    role_2 = _create_role(client, "Mechanical")
    s1 = _create_session(client, "Zoe", role_1)
    s2 = _create_session(client, "Liam", role_1)
    s3 = _create_session(client, "Maya", role_2)
    s4 = _create_session(client, "Ghost", role_1)
    _add_answer(client, s1, matched=True, disposition="pending")
    _add_answer(client, s3, matched=True, disposition="pending")

    client.post("/api/interviews/bulk/tag", json={"session_ids": [s1, s2], "add": ["urgent"]}).raise_for_status()
    client.post("/api/interviews/bulk/tag", json={"session_ids": [s2, s3, s4], "add": ["panel"]}).raise_for_status()
    client.post(f"/api/sessions/{s4}/trash").raise_for_status()

    tags_res = client.get("/api/interviews/tags")
    assert tags_res.status_code == 200
    assert tags_res.json()["tags"] == [{"tag": "panel", "count": 2}, {"tag": "urgent", "count": 2}]

    # Fast SQL path (sort=newest, no q, no review).
    fast_feed = client.get("/api/interviews/feed", params={"role_id": role_1["id"]}).json()
    assert fast_feed["total"] == 3 and fast_feed["filtered"] == 2
    assert {item["id"] for item in fast_feed["items"]} == {s1, s2}

    # Catalog query path (with review=pending and search query q).
    pending_feed = client.get("/api/interviews/feed", params={"role_id": role_1["id"], "review": "pending"}).json()
    assert pending_feed["filtered"] == 1
    assert [item["id"] for item in pending_feed["items"]] == [s1]

    search_feed = client.get("/api/interviews/feed", params={"role_id": role_1["id"], "q": "Liam", "tag": "panel"}).json()
    assert search_feed["filtered"] == 1
    assert [item["id"] for item in search_feed["items"]] == [s2]

    missing_role = client.get("/api/interviews/feed", params={"role_id": str(uuid4())}).json()
    assert missing_role["filtered"] == 0 and missing_role["items"] == []


def test_workspace_entitlement_required_on_cohort_and_tags_routes(client, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "http://127.0.0.1:8787")
    assert client.get("/api/analytics/cohorts").status_code == 401
    assert client.get("/api/analytics/cohorts/export").status_code == 401
    assert client.get("/api/interviews/tags").status_code == 401
