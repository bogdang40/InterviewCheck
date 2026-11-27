"""Compare the offline rehearsal with real saved exchanges and a scripted HTTP transport."""
import hashlib
import json
from unittest.mock import AsyncMock

from fastapi.testclient import TestClient
import pytest

from api import model_execution, provider_http, rate_limit, sample, saved_judge, saved_review_rehearsal, scoring_hooks, store
from api.main import app

CATALOGUE = "/api/admin/models/playground/saved-review-rehearsal"
JUDGE = "/api/scoring/judge/saved"
ALLOWANCE = "/api/admin/usage/ai-allowance"
COSTS = "/api/admin/usage/ai-costs"
OWNER = "chair@rehearsal.test"
SECRET = "rehearsal-fixture-bootstrap"
SCRIPTS = {"anchored", "score_only", "outside_excerpt"}


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    for name in ("INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN", "INTERVIEWCHECK_OPERATOR_EMAIL",
                 "INTERVIEWCHECK_OPERATOR_ID", "INTERVIEWCHECK_SIGNUP_SECRET", "OPENAI_API_KEY", "ANTHROPIC_API_KEY",
                 "AZURE_OPENAI_API_KEY", "DEEPGRAM_API_KEY"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("ADMIN_EMAILS", OWNER)
    monkeypatch.setenv("ADMIN_BOOTSTRAP_SECRET", SECRET)
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "saved-review-rehearsal-fixture-key")
    monkeypatch.setenv("TRIAL_DAYS", "7")
    rate_limit.reset_all()
    model_execution.reset_quotas()
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def signup(client, admin=False):
    credentials = {"email": OWNER if admin else "member@rehearsal.test", "password": "synthetic-password-456"}
    if admin:
        credentials["adminSecret"] = SECRET
    return client.post("/api/integrations/access/signup", json=credentials).raise_for_status().json()


def domain_state():
    # Include content, not only row counts. Workbench evidence, review attribution and spend
    # must survive browsing the catalogue even when paid features are configured.
    tables = ("roles", "sessions", "answers", "answer_review_events", "answer_history", "session_scorecards",
              "connected_models", "model_health_checks", "ai_cost_log", "model_usage_daily", "ai_attempt_policy",
              "ai_attempt_months")
    value = hashlib.sha256()
    with store.connection() as db:
        for table in tables:
            order = "answer_id, revision" if table == "answer_history" else "rowid"
            for row in db.execute(f"SELECT * FROM {table} ORDER BY {order}"):
                value.update(repr(tuple(row)).encode())
    return value.hexdigest()


def register_judge(client):
    client.post("/api/admin/models", json={"slug": "rehearsal-judge", "display_name": "Synthetic judge",
                "provider": "openai", "capability": "judge", "model_id": "synthetic-judge-model",
                "apiKey": "fixture-judge-key-1111", "is_default": True,
                "parameters": {"max_retries": 0, "input_cost_per_1m_usd": 8, "output_cost_per_1m_usd": 12}}).raise_for_status()


def save(client, question, answer, sources, notice):
    session = client.post("/api/sessions", json={"role": "Private rehearsal role", "candidate": "Private workshop candidate",
                          "policy": "Manuals allowed", "consent": True}).raise_for_status().json()
    sid = session["id"]
    exchange = client.post(f"/api/sessions/{sid}/answers", json={"question": question, "answer": answer,
                           "references": sources}).raise_for_status().json()
    if not notice:
        # Current capture requires notice. Retained historical records can lack it.
        with store.connection(write=True) as db:
            db.execute("UPDATE sessions SET consent=0 WHERE id=?", (sid,))
    return exchange, {"session_id": sid, "answer_id": exchange["id"], "expected_revision": exchange["revision"],
                      "evidence_sha256": saved_judge.evidence_digest(question, exchange["result"]["passages"])}


def test_catalogue_is_fixed_admin_only_and_reads_no_private_exchange_into_the_response(client, monkeypatch):
    assert client.get(CATALOGUE).status_code == 401
    signup(client)
    assert client.get(CATALOGUE).status_code == 403
    client.cookies.clear()
    signup(client, admin=True)
    register_judge(client)
    save(client, "Private rehearsal question", "Private rehearsal answer", [], True)
    live = AsyncMock(side_effect=AssertionError("Catalogue attempted to run a provider"))
    monkeypatch.setattr(model_execution, "execute_completion_chain", live)
    monkeypatch.setattr(provider_http, "fetch_json", live)
    before = domain_state()
    before_usage = client.get(ALLOWANCE).raise_for_status().json()
    before_cost = client.get(COSTS).raise_for_status().json()["totals"]
    response = client.get(CATALOGUE)
    rows = response.raise_for_status().json()["cases"]
    assert {r["id"] for r in rows} == {"brief", "match", "permitted", "no_source", "no_notice"} and len(rows) == 5
    for private in ("Private workshop candidate", "Private rehearsal question", "Private rehearsal answer", "fixture-judge-key-1111"):
        assert private not in response.text
    assert client.get(CATALOGUE).json()["cases"] == rows
    assert client.get(ALLOWANCE).json() == before_usage
    assert client.get(COSTS).json()["totals"] == before_cost
    assert domain_state() == before
    live.assert_not_awaited()


def test_each_rehearsal_case_matches_production_gating_transfer_and_result(client, monkeypatch):
    signup(client, admin=True)
    register_judge(client)
    catalogue = {r["id"]: r for r in client.get(CATALOGUE).raise_for_status().json()["cases"]}
    fixtures = sample.cases()
    scenarios = {"brief": ("checkout", "no_eligible_passage", "insufficient"),
                 "match": ("checkout", "matched_passage", "match"),
                 "permitted": ("manual", "no_eligible_passage", "no_match"),
                 "no_source": ("migration", "no_eligible_passage", "insufficient"),
                 "no_notice": ("checkout", "notice_required", "match")}
    attempts = []
    scripted = None

    async def transport(_provider, method, _url, **options):
        assert method == "POST" and scripted is not None
        attempts.append(json.loads(options["json"]["messages"][-1]["content"]))
        return {"choices": [{"finish_reason": "stop", "message": {"content": json.dumps(scripted)}}],
                "usage": {"prompt_tokens": 100, "completion_tokens": 10}}

    monkeypatch.setattr(scoring_hooks, "fetch_json", transport)
    for case_id, (fixture_name, gate, comparison) in scenarios.items():
        row, fixture = catalogue[case_id], fixtures[fixture_name]
        answer = "PostgreSQL with a unique constraint." if case_id == "brief" else fixture["answer"]
        assert (row["question"], row["answer"], row["notice"]) == (fixture["question"], answer, case_id != "no_notice")
        item, request = save(client, fixture["question"], answer, fixture["sources"], row["notice"])
        assert (row["gate"], row["comparison"], row["explanation"], row["local_question"]) == (
            gate, comparison, item["result"]["explanation"], item["result"]["follow_up"])
        before = len(attempts)
        if gate != "matched_passage":
            assert row["payload"] is None and row["scripts"] == []
            assert client.post(JUDGE, json=request).raise_for_status().json() == {
                "status": "insufficient_evidence", "follow_up_questions": [row["local_question"]]}
            assert len(attempts) == before
            continue
        assert {s["id"] for s in row["scripts"]} == SCRIPTS and len(row["scripts"]) == len(SCRIPTS)
        assert set(row["payload"]) == {"question", "matched_passages"}
        assert row["payload"]["question"] == fixture["question"]
        assert row["payload"]["matched_passages"] == [
            {key: passage[key][:1000] for key in ("answer_excerpt", "source_excerpt")}
            for passage in item["result"]["passages"][:3]
        ]
        assert fixture["answer"] not in json.dumps(row["payload"])
        assert all(source["text"] not in json.dumps(row["payload"]) for source in fixture["sources"])
        assert 1 <= len(row["payload"]["matched_passages"]) <= 3
        for passage in row["payload"]["matched_passages"]:
            assert set(passage) == {"answer_excerpt", "source_excerpt"}
            assert all(0 < len(text) <= 1000 for text in passage.values())
        for result in row["scripts"]:
            scripted = result["reply"]
            count = len(attempts)
            output = client.post(JUDGE, json=request)
            assert len(attempts) == count + 1 and attempts[-1] == row["payload"]
            if result["id"] == "anchored":
                assert scripted["likelihood"] == 92 and len(result["questions"]) == 1
                assert "separate pool of workers" in result["questions"][0]
                assert output.raise_for_status().json() == {"status": "reviewed", "model": "synthetic-judge-model",
                       "provider": "openai", "follow_up_questions": result["questions"]}
                assert "92" not in output.text
            else:
                assert result["questions"] == [] and output.status_code == 502
                assert "no usable follow up question" in output.json()["detail"]
        detail = client.get(f"/api/sessions/{request['session_id']}/answers/{item['id']}").raise_for_status().json()
        assert detail == item
    assert len(attempts) == 3
    assert client.get(ALLOWANCE).json()["used"] == len(attempts)
    assert client.get(COSTS).json()["totals"]["requests"] == len(attempts)


def test_rehearsal_bounds_long_matches_to_the_same_three_excerpts_as_saved_review(client, monkeypatch):
    signup(client, admin=True)
    register_judge(client)
    # Four different contiguous matches exceed both the passage count and per-excerpt length limits.
    chunks = [" ".join(f"{letter}{'z' * 75}{n}" for n in range(23)) for letter in "abcd"]
    sources = [{"label": "Private label " + str(i), "text": "Private introduction. " + segment + " End of manual.",
                "permitted": False} for i, segment in enumerate(chunks)]
    case = {"question": "Which choice would you check?", "answer": " other independent boundary ".join(chunks), "sources": sources}
    row = saved_review_rehearsal.example("bounded", "Fictional limit test", case)
    item, request = save(client, case["question"], case["answer"], sources, True)
    assert row["gate"] == "matched_passage" and len(item["result"]["passages"]) == 3
    assert all(len(p["answer_excerpt"]) > 1000 and len(p["source_excerpt"]) > 1000 for p in item["result"]["passages"])
    assert len(row["payload"]["matched_passages"]) == 3
    assert all(len(part) == 1000 for p in row["payload"]["matched_passages"] for part in p.values())
    assert "Private introduction" not in json.dumps(row["payload"]) and "Private label" not in json.dumps(row["payload"])
    wire = AsyncMock(return_value={"choices": [{"finish_reason": "stop", "message": {"content": "{}"}}]})
    monkeypatch.setattr(scoring_hooks, "fetch_json", wire)
    assert client.post(JUDGE, json=request).status_code == 502
    wire.assert_awaited_once()
    assert json.loads(wire.await_args.kwargs["json"]["messages"][-1]["content"]) == row["payload"]
