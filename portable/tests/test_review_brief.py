from hashlib import sha256
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import store
from api.main import app


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "brief.sqlite"))
    for name in ("INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(name, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def start(web):
    session = web.post(
        "/api/sessions",
        json={
            "candidate": "PrivateCandidateMarker",
            "role": "PrivateRoleMarker",
            "policy": "PrivatePolicyMarker",
            "consent": True,
            "permitted_sources": [{"label": "PrivateHandbook", "text": "PrivateMaterialContent"}],
        },
    )
    session.raise_for_status()
    return "/api/sessions/" + session.json()["id"]


def fixture(web):
    base = start(web)
    ids = []
    for i, state in enumerate(("pending", "unresolved", "explained", "disclosed", "pending"), 1):
        answer = f"PrivateAnswerMarker{i} indicates the ceramic sleeve was scratched while the rotating spindle expanded."
        question = f"PrivateQuestionMarker{i}?"
        refs = [{"label": f"PrivateLabel{i}", "text": answer + " PrivateReferenceSuffix"}] if i < 3 else []
        if i == 3:
            refs = [
                {
                    "label": "PrivateLabel3",
                    "text": "Use a completely different tool to repair these ventilation ducts.",
                }
            ]
        data = web.post(
            base + "/answers", json={"question": question, "answer": answer, "references": refs}
        ).json()
        if state != "pending":
            web.patch(
                base + "/answers/" + data["id"],
                json={
                    "disposition": state,
                    "note": f"PrivateNoteMarker{i}\n# Injected heading",
                    "expected_revision": data["revision"],
                },
            ).raise_for_status()
        ids.append(data["id"])
    with store.connection(write=True) as db:
        db.execute(
            "UPDATE answers SET legacy=? WHERE id=?", ('{"history":"PrivateHistoricalMarker"}', ids[-1])
        )
    return base, ids


def test_default_brief_omits_user_content_and_partitions_each_exchange(client):
    base, ids = fixture(client)
    response = client.get(base + "/brief")
    response.raise_for_status()
    assert "Private" not in response.text
    brief = response.json()
    assert brief["outcomes"] == {
        "pending": 1,
        "unresolved": 1,
        "explained": 1,
        "disclosed": 1,
        "no_pending_match": 1,
    }
    assert "Matched: 2. No passage match: 1. Limited evidence: 2." in brief["markdown"]
    assert sum(brief["outcomes"].values()) == len(ids)
    assert "exchange 2" in brief["markdown"] and ids[0] not in brief["markdown"]
    assert brief == client.post(base + "/brief", json={}).json()
    file = client.post(base + "/brief/download", json={"preview_sha256": brief["preview_sha256"]})
    assert (
        file.content == brief["markdown"].encode()
        and sha256(file.content).hexdigest() == brief["preview_sha256"]
    )
    assert "attachment" in file.headers["content-disposition"] and "Private" not in file.text


def test_explicit_selection_is_local_to_the_exchange_and_digest(client):
    base, ids = fixture(client)
    options = {"excerpt_ids": [ids[0]], "note_ids": [ids[2]]}
    brief = client.post(base + "/brief", json=options).json()
    text = brief["markdown"]
    assert (
        "PrivateAnswerMarker1" in text and "    # Injected heading" in text and "PrivateNoteMarker3" in text
    )
    for forbidden in (
        "PrivateQuestion",
        "PrivateAnswerMarker2",
        "PrivateNoteMarker2",
        "PrivateLabel",
        "PrivateHistorical",
        "PrivateCandidate",
        "PrivateRole",
        "PrivatePolicy",
        "PrivateHandbook",
    ):
        assert forbidden not in text
    req = {**options, "preview_sha256": brief["preview_sha256"]}
    assert client.post(base + "/brief/download", json=req).text == text
    client.patch(
        base + "/answers/" + ids[2], json={"note": "A later note.", "disposition": "explained"}
    ).raise_for_status()
    assert client.post(base + "/brief/download", json=req).status_code == 409
    assert client.post(base + "/brief", json={"note_ids": [str(uuid4())]}).status_code == 422
    other = start(client)
    assert client.post(other + "/brief", json={"excerpt_ids": [ids[0]]}).status_code == 422


def test_empty_brief_auth_and_excerpt_bounds(client, monkeypatch):
    base = start(client)
    assert "No exchanges were recorded." in client.get(base + "/brief").json()["markdown"]
    raw = "猫" * 240 + "PrivateHiddenAt241"
    item = client.post(base + "/answers", json={"question": "Describe the test.", "answer": raw}).json()
    result = client.post(base + "/brief", json={"excerpt_ids": [item["id"]]}).json()
    assert "猫" * 240 + "…" in result["markdown"] and "PrivateHiddenAt241" not in result["markdown"]
    assert "All saved exchanges have limited comparison evidence." in result["markdown"]
    assert (
        client.post(base + "/brief", json={"note_ids": [str(uuid4()) for _ in range(101)]}).status_code == 422
    )
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "http://127.0.0.1:8787")
    assert client.get(base + "/brief").status_code == 401
    assert client.post(base + "/brief", json={}).status_code == 401
    assert client.post(base + "/brief/download", json={"preview_sha256": "0" * 64}).status_code == 401
