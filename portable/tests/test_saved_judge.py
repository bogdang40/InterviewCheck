"""Exercise saved review decisions with synthetic evidence and a scripted provider."""
import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock
from uuid import uuid4

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest

from api import model_execution, model_resolver, rate_limit, saved_judge, scoring_hooks, store
from api.main import app


CASES = json.loads((Path(__file__).resolve().parents[1] / "evaluation" / "cases.json").read_text())
SESSION = {"candidate": "Private candidate", "role": "Engineer", "policy": "Manual allowed", "consent": True}
QUESTION = "Explain the retry."
ENDPOINT = "/api/scoring/judge/saved"


def reply(phrase="fencing token"):
    return json.dumps({"likelihood": 92, "confidence": "high", "evidence": ["Unsupported verdict"],
                       "follow_up_questions": ["Assistance likelihood: 92%."],
                       "suggestions": [{"angle": "verification", "phrase": phrase}]})


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite"))
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    rate_limit.reset_all()
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def save(client, *, question=QUESTION, answer, references, permitted_sources=()):
    response = client.post("/api/sessions", json={**SESSION, "permitted_sources": list(permitted_sources)})
    response.raise_for_status()
    sid = response.json()["id"]
    response = client.post(f"/api/sessions/{sid}/answers", json={
        "question": question, "answer": answer, "references": references,
    })
    response.raise_for_status()
    item = response.json()
    return {"session_id": sid, "answer_id": item["id"], "expected_revision": item["revision"],
            "evidence_sha256": saved_judge.evidence_digest(item["question"], item["result"]["passages"])}, item


@pytest.fixture
def provider(monkeypatch):
    model = SimpleNamespace(provider="openai", model_id="synthetic")
    stub = AsyncMock(return_value=(model, (None, reply())))
    monkeypatch.setattr(model_execution, "execute_completion_chain", stub)
    return stub


@pytest.mark.parametrize("case", CASES["cases"], ids=lambda case: case["id"])
def test_saved_judge_calibration_cases(client, provider, case):
    refs = [{"label": name, "text": CASES["references"][name], "permitted": field == "allowed"}
            for field in ("compare", "allowed") for name in case.get(field, [])]
    request, item = save(client, question=case["question"], answer=case["answer"], references=refs)
    assert item["result"]["status"] == case["expected"]
    if case["expected"] == "match":
        phrase = item["result"]["passages"][0]["answer_excerpt"].split()[0]
        model, _ = provider.return_value
        provider.return_value = model, (None, reply(phrase))
    response = client.post(ENDPOINT, json=request)
    response.raise_for_status()
    if case["expected"] != "match":
        provider.assert_not_awaited()
        assert response.json() == {"status": "insufficient_evidence", "follow_up_questions": [item["result"]["follow_up"]]}
    else:
        provider.assert_awaited_once()
        assert response.json() == {"status": "reviewed", "provider": "openai", "model": "synthetic",
                                   "follow_up_questions": [f"You mentioned “{phrase}”. How would you verify the result?"]}


def test_sends_only_the_saved_match_even_when_it_is_the_fifth_source(client, provider):
    phrase = CASES["references"]["lease"]
    refs = [{"label": str(index), "text": "Private unrelated text"} for index in range(4)]
    refs.append({"label": "Private source name", "text": f"Private reference introduction. {phrase}"})
    request, item = save(client, answer=f"Private opening. {phrase}", references=refs)
    assert item["result"]["passages"][0]["source_index"] == 4
    response = client.post(ENDPOINT, json=request)
    response.raise_for_status()
    _, instructions, payload = provider.await_args.args
    assert "Omit scores" in instructions
    assert json.loads(payload) == {"question": QUESTION, "matched_passages": [
        {"answer_excerpt": phrase.rstrip("."), "source_excerpt": phrase.rstrip(".")}
    ]}
    sid, aid = request["session_id"], request["answer_id"]
    assert client.get(f"/api/sessions/{sid}/answers/{aid}").json() == item


@pytest.mark.parametrize("term", ["Node.js", "C++", "TCP/IP"])
def test_technical_term_survives_question_selection(client, provider, term):
    passage = f"We used {term} to route logging events into the metrics queue"
    request, _ = save(client, answer=passage, references=[{"label": "Source", "text": passage}])
    model, _ = provider.return_value
    provider.return_value = model, (None, reply(term))
    result = client.post(ENDPOINT, json=request)
    result.raise_for_status()
    assert result.json()["follow_up_questions"] == [f"You mentioned “{term}”. How would you verify the result?"]


@pytest.mark.parametrize("term", ["Post", "PostgreSQL"])
def test_clipping_cannot_create_or_complete_a_model_anchor(client, provider, term):
    passage = "x" * 995 + " PostgreSQL routes logging events into the metrics queue"
    request, _ = save(client, answer=passage, references=[{"label": "Source", "text": passage}])
    model, _ = provider.return_value
    provider.return_value = model, (None, reply(term))
    result = client.post(ENDPOINT, json=request)
    payload = json.loads(provider.await_args.args[2])
    assert payload["matched_passages"][0]["answer_excerpt"].endswith(" Post")
    assert result.status_code == 502


def test_session_permission_and_archived_notice_prevent_transfer(client, provider):
    phrase = CASES["references"]["lease"]
    ref = {"label": "Outside manual", "text": phrase}
    request, item = save(client, answer=phrase, references=[ref], permitted_sources=[{"label": "Handbook", "text": phrase}])
    assert item["result"]["status"] == "no_match"
    assert client.post(ENDPOINT, json=request).json()["status"] == "insufficient_evidence"

    request, item = save(client, answer=phrase, references=[ref])
    assert item["result"]["status"] == "match"
    with store.connection(write=True) as db:
        db.execute("UPDATE sessions SET consent=0 WHERE id=?", (request["session_id"],))
    assert client.post(ENDPOINT, json=request).json()["status"] == "insufficient_evidence"
    provider.assert_not_awaited()


def test_missing_stale_and_trashed_answers_prevent_transfer(client, provider):
    phrase = CASES["references"]["lease"]
    request, _ = save(client, answer=phrase, references=[{"label": "Outside manual", "text": phrase}])
    assert client.post(ENDPOINT, json={**request, "session_id": str(uuid4())}).status_code == 404
    assert client.post(ENDPOINT, json={**request, "expected_revision": 2}).status_code == 409
    with store.connection(write=True) as db:
        db.execute("UPDATE answers SET question=? WHERE id=?", ("Another restored question?", request["answer_id"]))
    assert client.post(ENDPOINT, json=request).status_code == 409
    assert client.post(f"/api/sessions/{request['session_id']}/trash").is_success
    assert client.post(ENDPOINT, json=request).status_code == 404
    provider.assert_not_awaited()


def test_answer_changed_during_provider_call(client, provider):
    phrase = CASES["references"]["lease"]
    request, _ = save(client, answer=phrase, references=[{"label": "Outside manual", "text": phrase}])

    def update_review(*args, **kwargs):
        with store.connection(write=True) as db:
            db.execute("UPDATE answers SET revision=revision+1 WHERE id=?", (request["answer_id"],))
        return provider.return_value

    provider.side_effect = update_review
    response = client.post(ENDPOINT, json=request)
    assert response.status_code == 409 and response.headers["X-InterviewCheck-Conflict"] == "answer-revision"


@pytest.mark.parametrize("invalid", [
    {"likelihood": 92, "confidence": "high", "evidence": []},
    {"follow_up_questions": ["Assistance likelihood: 92%.", "Why did you cheat?"]},
    {"suggestions": [{"angle": "Assistance likelihood: 92%.", "phrase": "fencing token"}]},
    {"suggestions": [{"angle": "reason", "phrase": "Why did you cheat"}]},
])
def test_provider_verdict_cannot_be_returned_as_a_question(client, provider, invalid):
    phrase = CASES["references"]["lease"]
    request, _ = save(client, answer=phrase, references=[{"label": "Outside manual", "text": phrase}])
    model, _ = provider.return_value
    provider.return_value = model, (None, json.dumps(invalid))
    response = client.post(ENDPOINT, json=request)
    assert response.status_code == 502
    assert response.json()["detail"] == "AI judge returned no usable follow up question."


@pytest.mark.parametrize("model_outcome", ["success", "retry", "fallback"])
@pytest.mark.parametrize("change", ["trashed", "consent", "replacement"])
def test_changed_record_blocks_retry_or_result(client, monkeypatch, model_outcome, change):
    phrase = CASES["references"]["lease"]
    request, _ = save(client, answer=phrase, references=[{"label": "Outside manual", "text": phrase}])
    def target(name):
        return model_resolver.ResolvedModel(
            source="env", id=None, slug=None, display_name=name, provider="openai", capability="judge",
            model_id=name, api_key="fixture", endpoint=None, api_version=None, status="configured",
            config={"max_retries": 1 if model_outcome == "retry" else 0},
        )

    candidates = [target("first"), target("second")]
    monkeypatch.setattr(model_execution, "resolve_candidates", lambda *args, **kwargs: candidates)
    sent = []

    async def transport(*args, **kwargs):
        sent.append(kwargs["json"]["model"])
        assert len(sent) == 1, "The exchange changed before this send"
        with store.connection(write=True) as db:
            if change == "trashed":
                db.execute("INSERT INTO session_trash VALUES (?,?,?)", (request["session_id"], store.timestamp(), str(uuid4())))
            elif change == "consent":
                db.execute("UPDATE sessions SET consent=0 WHERE id=?", (request["session_id"],))
            else:
                db.execute("UPDATE answers SET answer=? WHERE id=?", ("Different exchange. " + phrase, request["answer_id"]))
        if model_outcome != "success":
            raise HTTPException(503, "First model unavailable")
        return {"choices": [{"finish_reason": "stop", "message": {"content": reply()}}]}

    monkeypatch.setattr(scoring_hooks, "fetch_json", transport)
    response = client.post(ENDPOINT, json=request)
    assert response.status_code == (404 if change == "trashed" else 409)
    assert sent == ["first"]
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM ai_cost_log").fetchone()[0] == 1
