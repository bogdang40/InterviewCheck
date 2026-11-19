from unittest.mock import AsyncMock

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest

from api import authoring
from api.main import app


PAIRS = [{"provider": "OpenAI", "style": "Spoken answer"}, {"provider": "Anthropic", "style": "Talking points"}]
DATA = {"role": "Test engineer", "question": "How would you identify a stuck latch?", "pairs": PAIRS, "existing_reference_count": 0}


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "synthetic.sqlite"))
    for name in ("INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(name, raising=False)
    for name in (key for keys in authoring.MODEL_KEYS.values() for key in keys):
        monkeypatch.setenv(name, "synthetic")
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


@pytest.mark.parametrize("update", [
    {"pairs": PAIRS + PAIRS}, {"pairs": PAIRS[:1]*2}, {"existing_reference_count": 11},
    {"pairs": []}, {"pairs": [{"provider": "OpenAI", "style": "Unknown"}]}, {"candidate": "Private"},
])
def test_invalid_lineup_never_dispatches(client, monkeypatch, update):
    send = AsyncMock()
    monkeypatch.setattr(authoring, "complete", send)
    assert client.post("/api/authoring/references", json={**DATA, **update}).status_code == 422
    send.assert_not_called()


def test_missing_credential_blocks_entire_batch_before_send(client, monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY")
    send = AsyncMock()
    monkeypatch.setattr(authoring, "complete", send)
    assert client.post("/api/authoring/references", json=DATA).status_code == 503
    send.assert_not_called()


def test_mixed_results_preserve_success_and_separate_recipient_errors(client, monkeypatch):
    requests = []
    async def fake(provider, instructions, prompt):
        import json
        requests.append((provider, instructions, json.loads(prompt)))
        if provider == "Anthropic":
            raise HTTPException(502, "Synthetic upstream failure.")
        return "fixture", "A valid reference."
    monkeypatch.setattr(authoring, "complete", fake)
    result = client.post("/api/authoring/references", json={**DATA, "existing_reference_count": 10})
    result.raise_for_status()
    valid, invalid = result.json()["results"]
    assert valid["provider"] == "OpenAI" and valid["source"]["text"] == "A valid reference."
    assert invalid == {**PAIRS[1], "error": "Synthetic upstream failure."}
    assert [call[0] for call in requests] == ["OpenAI", "Anthropic"]
    assert all(call[2] == {"role": DATA["role"], "question": DATA["question"]} for call in requests)
