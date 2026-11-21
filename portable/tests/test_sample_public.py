"""The sample review works before sign-in, and only on its own fictional cases."""
import json

from fastapi.testclient import TestClient

from api import main, rate_limit, store
from api.models import Reference
from api.evidence import compare
from api.sample import CASES

HEADERS = {"X-InterviewCheck": "1"}


def _embedded(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    rate_limit.reset_all()
    store.initialize(store.db_path())


def test_signed_out_visitor_can_run_every_sample_case(tmp_path, monkeypatch):
    _embedded(tmp_path, monkeypatch)
    cases = json.loads(CASES.read_text(encoding="utf-8"))["cases"]
    with TestClient(main.app, base_url="http://127.0.0.1") as client:
        assert client.post("/api/preview", json={"question": "Q?", "answer": "A."}, headers=HEADERS).status_code == 401
        for case in cases:
            response = client.post("/api/sample/preview", json={"case_id": case["id"]}, headers=HEADERS)
            assert response.status_code == 200, response.text
            expected = compare(case["question"], case["answer"], [Reference(**s) for s in case["sources"]])
            assert response.json() == json.loads(json.dumps(expected))


def test_permitting_the_source_removes_the_passage_match(tmp_path, monkeypatch):
    _embedded(tmp_path, monkeypatch)
    with TestClient(main.app, base_url="http://127.0.0.1") as client:
        flagged = client.post("/api/sample/preview", json={"case_id": "checkout", "permitted": [False]}, headers=HEADERS).json()
        permitted = client.post("/api/sample/preview", json={"case_id": "checkout", "permitted": [True]}, headers=HEADERS).json()
    assert flagged["status"] == "match" and flagged["passages"]
    assert permitted["status"] != "match" and not permitted["passages"]


def test_sample_endpoint_never_accepts_text(tmp_path, monkeypatch):
    _embedded(tmp_path, monkeypatch)
    with TestClient(main.app, base_url="http://127.0.0.1") as client:
        extra = client.post("/api/sample/preview", json={"case_id": "checkout", "answer": "anything"}, headers=HEADERS)
        unknown = client.post("/api/sample/preview", json={"case_id": "not-a-case"}, headers=HEADERS)
        wrong_flags = client.post("/api/sample/preview", json={"case_id": "manual", "permitted": [True]}, headers=HEADERS)
    assert extra.status_code == 422
    assert unknown.status_code == 404
    assert wrong_flags.status_code == 422
