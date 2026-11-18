"""Exercise comparison and export through the shipped HTTP service."""
from uuid import uuid4

import httpx


QUESTION = "How would you diagnose a dropped packet in the storage network?"
SOURCE = "Calibrate the amber receiver against three cold baselines before comparing its packet counts."
ALLOWED = "Label every adapter with the host name before you disconnect any equipment."


def test_comparison_review_and_export(workspace_url):
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        assert client.get("/api/health").json()["ok"]
        form = {"candidate": "Test candidate", "role": "Network engineer",
                "policy": "The published checklist is allowed.", "consent": True, "id": str(uuid4())}
        saved = client.post("/api/sessions", json=form)
        saved.raise_for_status()
        base = f'/api/sessions/{saved.json()["id"]}'
        assert client.post("/api/sessions", json=form).json()["id"] == saved.json()["id"]
        assert len(client.get("/api/sessions").json()) == 1

        cases = [
            ("match", SOURCE, [{"label": "Comparison A", "text": SOURCE}]),
            ("no_match", QUESTION, [{"label": "Prompt copy", "text": QUESTION}]),
            ("no_match", ALLOWED, [{"label": "Guide", "text": ALLOWED},
                                    {"label": "Published checklist", "text": ALLOWED, "permitted": True}]),
            ("no_match", SOURCE, [{"label": "Guide", "text": SOURCE}, {"label": "Handbook", "text": SOURCE}]),
            ("insufficient", "Check the cable.", [{"label": "Guide", "text": SOURCE}]),
            ("insufficient", SOURCE, []),
            ("no_match", "First I look for a dead port and take a trace on another host.",
             [{"label": "Guide", "text": SOURCE}]),
        ]
        for status, answer, references in cases:
            response = client.post(base + "/answers", json={
                "question": QUESTION, "answer": answer, "references": references,
            })
            response.raise_for_status()
            record = response.json()
            assert record["result"]["status"] == status
            if status == "match":
                passage = record["result"]["passages"][0]
                assert passage["answer_excerpt"] in answer
                assert passage["source_excerpt"] in SOURCE
                assert passage["label"] == "Comparison A"
                assert record["result"]["follow_up"]
                review = client.patch(base + f'/answers/{record["id"]}', json={
                    "disposition": "explained", "note": "Candidate reproduced the measurement.",
                })
                review.raise_for_status()
            else:
                assert record["result"]["passages"] == []

        session = client.get(base).json()
        assert session["answer_count"] == len(cases)
        assert session["review_count"] == 0
        assert session["answers"][0]["disposition"] == "explained"
        exported = client.get(base + "/report")
        exported.raise_for_status()
        assert "attachment" in exported.headers["content-disposition"]
        assert "Candidate reproduced the measurement." in exported.text
        assert "Comparison A" in exported.text
        assert SOURCE.strip(".") in exported.text
