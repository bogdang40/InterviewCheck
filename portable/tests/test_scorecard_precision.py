import csv
from io import StringIO

import pytest

from backup_requests import client, create_session
from api.scorecard_math import weighted_score_pct


@pytest.mark.parametrize(("low_weight", "high_weight", "expected"), [
    (11, 5, 26.2),  # 26.25%, round to the even lower tenth.
    (13, 3, 23.8),  # 23.75%, round to the even upper tenth.
    (2, 1, 26.7),
])
def test_saved_score_uses_same_precision_across_reads_and_exports(client, low_weight, high_weight, expected):
    sid, other = create_session(client), create_session(client)
    route = f"/api/sessions/{sid}/scorecard"
    rows = [{"criterion_id": "first", "criterion_label": "First", "weight": low_weight, "rating": 1},
            {"criterion_id": "second", "criterion_label": "Second", "weight": high_weight, "rating": 2}]
    assert client.put(route, json={"items": rows}).raise_for_status().json()["weighted_score_pct"] == expected
    assert client.get(route).raise_for_status().json()["weighted_score_pct"] == expected
    assert f"Weighted score: {expected:.1f}%" in client.get(f"/api/sessions/{sid}/print").raise_for_status().text

    options = {"session_ids": [sid, other], "include_scorecards": True}
    compared = client.post("/api/interviews/compare", json=options).raise_for_status().json()["sessions"]
    assert [s["scorecard"]["weighted_score_pct"] for s in compared] == [expected, None]
    for fmt in ("markdown", "html"):
        text = client.post("/api/interviews/compare/dossier", json={**options, "format": fmt}).raise_for_status().text
        assert f"Weighted score {expected:.1f}%" in text

    cohort = client.get("/api/analytics/cohorts").raise_for_status().json()
    assert cohort["summary"]["avg_scorecard_pct"] == expected
    assert {r["session_id"]: r["weighted_score_pct"] for r in cohort["candidates"]} == {sid: expected, other: None}
    export = client.get("/api/analytics/cohorts/export", params={"format": "csv"}).raise_for_status()
    records = list(csv.DictReader(StringIO(export.content.decode("utf-8-sig"))))
    assert {r["Session ID"]: r["Weighted score %"] for r in records} == {sid: str(expected), other: ""}


def test_ungraded_criteria_do_not_change_the_denominator():
    unrated = {"rating": None, "weight": 100}
    assert weighted_score_pct([unrated]) is None
    assert weighted_score_pct([unrated, {"rating": 4, "weight": 1}]) == 80
