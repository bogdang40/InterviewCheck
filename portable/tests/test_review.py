from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api.main import app
from api.evidence import compare
from api.models import Reference

PASSAGE = "The oldest active snapshot pins tombstones across every replica until compaction completes"
QUESTION = "Explain your approach to data retention."
SESSION = {"candidate": "Sample", "role": "Engineer", "policy": "The handbook is permitted.", "consent": True}


def source(text=PASSAGE, label="Reference", permitted=False):
    return Reference(label=label, text=text, permitted=permitted)


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "reviews.sqlite"))
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_URL", raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def test_passage_attribution_retains_punctuation():
    answer = "Yes. " + PASSAGE.replace("tombstones", "TOMBSTONES,")
    finding = compare(QUESTION, answer, [source()])
    assert finding["status"] == "match"
    match, = finding["passages"]
    assert match["label"] == "Reference"
    assert match["source_excerpt"] == PASSAGE
    assert match["answer_excerpt"] == answer[5:]
    assert match["words"] == len(PASSAGE.split())
    assert "TOMBSTONES" in finding["follow_up"]


@pytest.mark.parametrize(("question", "answer", "sources", "status"), [
    (QUESTION, PASSAGE, [], "insufficient"),
    (QUESTION, "I would use Redis", [source()], "insufficient"),
    (QUESTION, PASSAGE, [source("trivial")], "insufficient"),
    (QUESTION, PASSAGE, [source(permitted=True)], "insufficient"),
    (PASSAGE, PASSAGE, [source()], "no_match"),
    (QUESTION, PASSAGE, [source(), source(label="Handbook", permitted=True)], "no_match"),
    (QUESTION, PASSAGE, [source(), source(label="Reference B")], "no_match"),
    (QUESTION, "I served files from a local cache while we recovered the rest", [source()], "no_match"),
    (QUESTION, "The bulk of my time is spent replaying delayed work items", [source()], "no_match"),
    (QUESTION, "if it is in the way then I would do it", [source("if it is in the way then I would do it")], "no_match"),
    (PASSAGE, PASSAGE + " in production today", [source(PASSAGE + " in production today")], "no_match"),
])
def test_coverage(question, answer, sources, status):
    result = compare(question, answer, sources)
    assert result["status"] == status
    assert result["passages"] == []


def test_distinct_matches_survive_common_prefix():
    second = "A replica issues leases from its own logical clock during partitions."
    snippet = "A consistent read is hard to guarantee during maintenance."
    result = compare(QUESTION, f"{snippet} {PASSAGE}. {second}", [
        source(snippet + " " + PASSAGE), source(snippet + " " + second, "Second"),
    ])
    assert {p["label"] for p in result["passages"]} == {"Reference", "Second"}
    assert all(snippet not in p["answer_excerpt"] for p in result["passages"])


def test_preview_does_not_create_an_interview(client):
    payload = {"question": QUESTION, "answer": PASSAGE, "references": [source().model_dump()]}
    assert client.post("/api/preview", json=payload).json()["status"] == "match"
    assert client.get("/api/sessions").json() == []


def test_session_lifecycle_retries_and_corrections(client):
    session = dict(SESSION, id=str(uuid4()))
    created = client.post("/api/sessions", json=session)
    assert created.status_code == 201
    key = created.json()["id"]
    assert client.post("/api/sessions", json=session).json()["id"] == key
    assert client.post("/api/sessions", json=dict(session, role="Different")).status_code == 409
    path = "/api/sessions/" + key
    data = {"id": str(uuid4()), "question": QUESTION, "answer": PASSAGE, "references": [source().model_dump()]}
    answer = client.post(path + "/answers", json=data)
    assert answer.status_code == 201
    assert answer.json()["result"]["status"] == "match"
    aid = answer.json()["id"]
    item = path + "/answers/" + aid
    assert client.post(path + "/answers", json=data).json()["id"] == aid
    assert client.post(path + "/answers", json=dict(data, question="New?")).status_code == 409
    assert client.get(path).json()["review_count"] == 1
    review = {"note": "Candidate explained the retention rule.", "disposition": "explained"}
    assert client.patch(item, json=review).json()["note"] == review["note"]
    assert client.get(path).json()["review_count"] == 0
    assert client.put(item, json=data).json()["disposition"] == "explained"
    data["references"][0]["permitted"] = True
    saved = client.put(item, json=data).json()
    assert saved["disposition"] == "pending"
    assert saved["result"]["status"] == "insufficient"
    assert "earlier answer version" in saved["note"]
    report = client.get(path + "/report")
    assert report.status_code == 200
    assert "attachment" in report.headers["content-disposition"]
    assert review["note"] in report.text
    assert SESSION["policy"] in report.text
    assert client.get("/api/sessions").json()[0]["answer_count"] == 1


def test_cross_session_id_isolation(client):
    one, two = [client.post("/api/sessions", json=SESSION).json()["id"] for _ in range(2)]
    data = {"id": str(uuid4()), "question": QUESTION, "answer": PASSAGE}
    client.post(f"/api/sessions/{one}/answers", json=data).raise_for_status()
    assert client.post(f"/api/sessions/{two}/answers", json=data).status_code == 409
    path = f"/api/sessions/{two}/answers/{data['id']}"
    assert client.put(path, json=data).status_code == 404
    assert client.patch(path, json={"disposition": "explained", "note": ""}).status_code == 404


def test_roles_and_notice_required(client):
    assert client.post("/api/sessions", json=dict(SESSION, consent=False)).status_code == 422
    assert client.post("/api/sessions", json=dict(SESSION, consent="true")).status_code == 422
    assert client.post("/api/sessions", json=dict(SESSION, candidate="   ")).status_code == 422
    role = {"id": str(uuid4()), "name": "Engineer", "description": "", "questions": ["Why here?"]}
    saved = client.post("/api/roles", json=role).json()
    assert len(saved["version"]) == 64
    result = {
        **role,
        "policy": "",
        "permitted_sources": [],
        "version": saved["version"],
        "rubric": [],
        "version_number": 1,
    }
    assert client.post("/api/roles", json=role).json() == result
    assert client.post("/api/roles", json=saved).json() == result
    assert client.get("/api/roles").json() == [result]


def test_boundary(client):
    assert client.post("/api/sessions", json=SESSION, headers={"X-InterviewCheck": "0"}).status_code == 403
    assert client.post("/api/sessions", json=SESSION, headers={"Origin": "http://127.0.0.1:8123"}).status_code == 403
    assert client.get("/api/sessions", headers={"Host": "example.com"}).status_code == 400
    assert client.post("/api/preview", content=b"x" * (2 * 1024 ** 2 + 1)).status_code == 413
    assert client.get("/api/health").headers["cache-control"] == "no-store"


def test_validation_response_does_not_echo_private_inputs(client):
    secret = "private transcript text"
    response = client.post("/api/preview", json={"question": "?", "answer": {}, "other": secret})
    assert response.status_code == 422
    assert secret not in response.text


def test_membership_check_applies_to_the_workspace(client, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "http://127.0.0.1:8787")
    assert client.get("/api/sessions").status_code == 401
    assert client.get("/api/roles").status_code == 401
    assert client.get(f"/api/sessions/{uuid4()}/report").status_code == 401
    assert client.post("/api/preview", json={"question": "?", "answer": PASSAGE}).status_code == 401


def test_archive_csv_and_print_export(client):
    import csv
    from io import StringIO

    first = client.post("/api/sessions", json=dict(SESSION, candidate="=SUM(1,2)")).json()
    client.post("/api/sessions", json=dict(SESSION, candidate="Empty")).raise_for_status()
    path = f"/api/sessions/{first['id']}"
    data = {"question": "<script>test</script>", "answer": PASSAGE, "references": [source().model_dump()]}
    aid = client.post(path + "/answers", json=data).json()["id"]
    client.patch(path + "/answers/" + aid, json={"disposition": "pending", "note": '@DATA("a","b")\nNext'}).raise_for_status()
    raw = client.get("/api/exports/interviews.csv")
    raw.raise_for_status()
    rows = list(csv.DictReader(StringIO(raw.content.decode("utf-8-sig"))))
    assert len(rows) == 2
    assert rows[0]["Candidate"] == "Empty"
    assert rows[1]["Candidate"] == "'=SUM(1,2)"
    assert rows[1]["Interviewer note"] == '\'@DATA("a","b")\nNext'
    assert rows[1]["Answer"] == PASSAGE
    printed = client.get(path + "/print")
    printed.raise_for_status()
    assert "Print or save PDF" in printed.text
    assert "<script>test</script>" not in printed.text
    assert "&lt;script&gt;test&lt;/script&gt;" in printed.text
    assert PASSAGE in printed.text


def test_native_role_preview_is_read_only(client):
    doc = {"format": "interviewcheck.role", "version": 1, "role": {
        "workspaceID": "test-role", "name": "SRE", "plannedQuestions": [{"text": "How?"}],
    }}
    first = client.post("/api/roles/import/preview", json=doc).json()
    assert first["question_count"] == 1 and not first["duplicate"]
    assert not client.get("/api/roles").json()
    assert client.post("/api/roles/import", json=doc).json()["id"] == first["id"]
    assert client.post("/api/roles/import/preview", json=doc).json()["duplicate"]
    assert client.post("/api/roles/import", json=doc).json()["id"] == first["id"]
    assert len(client.get("/api/roles").json()) == 1


def test_follow_up_anchors_to_own_answer_with_no_source():
    answer = "That is a good question. An expired lease leaves a stale writer behind."
    result = compare(QUESTION, answer, [])
    assert result["status"] == "insufficient"
    assert "An expired lease leaves a stale writer behind" in result["follow_up"]
    assert compare(QUESTION, "I am not quite sure", [])["follow_up"].startswith("Which assumption")


def test_follow_up_filters_question_echo_when_other_claim_available():
    prompt = "How would you isolate disk writes during replication?"
    answer = prompt + " I used separate spool files to isolate failing replicas."
    result = compare(prompt, answer, [source()])
    assert "spool files" in result["follow_up"]
    assert prompt not in result["follow_up"]


def test_candidate_disclosure_requires_a_note_but_does_not_change_the_comparison(client):
    sid = client.post("/api/sessions", json=SESSION).json()["id"]
    item = client.post(f"/api/sessions/{sid}/answers", json={"question": QUESTION, "answer": PASSAGE}).json()
    path = f"/api/sessions/{sid}/answers/{item['id']}"
    assert client.patch(path, json={"disposition": "disclosed", "note": "   "}).status_code == 422
    saved = client.patch(path, json={"disposition": "disclosed", "note": "Candidate described use of notes."}).json()
    assert saved["result"] == item["result"] and saved["disposition"] == "disclosed"
