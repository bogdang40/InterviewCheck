from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from api.main import app


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "queue.sqlite"))
    for key in ("INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def test_queue_points_to_first_pending_match_in_capture_order_even_after_finish(client):
    session = {"candidate": "Waiting", "role": "Engineer", "consent": True, "policy": "Manual permitted."}
    sid = client.post("/api/sessions", json=session).json()["id"]
    other_sid = client.post("/api/sessions", json={**session, "candidate": "Other"}).json()["id"]
    answer = {"question": "Which part failed?", "answer": "The rear cylinder warped when the fan stopped."}
    path = "/api/sessions/" + sid
    client.post(path + "/answers", json=answer).raise_for_status()
    # Reverse lexical UUID order. Review uses question order, even with an earlier nonmatch.
    ids = sorted([str(uuid4()), str(uuid4())], reverse=True)
    refs = [{"label": "Service report", "text": answer["answer"]}]
    for aid in ids:
        client.post(path + "/answers", json={**answer, "references": refs, "id": aid}).raise_for_status()
    client.post(path + "/finish").raise_for_status()
    for i, expected in enumerate([*ids, None]):
        summary = {row["id"]: row for row in client.get("/api/sessions").json()}
        assert summary[other_sid]["first_pending_answer_id"] is None
        assert summary[sid]["first_pending_answer_id"] == expected
        assert summary[sid]["review_count"] == 2 - i
        assert summary[sid]["ended_at"]
        if expected:
            current = client.get(path).json()["answers"][i + 1]
            review = {"note": "Candidate explained the cause.", "disposition": "explained"}
            review["expected_revision"] = current["revision"]
            client.patch(path + "/answers/" + expected, json=review).raise_for_status()
