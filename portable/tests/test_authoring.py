import asyncio
import pytest
from fastapi import HTTPException
from api import authoring, store
from api.authoring import Draft, Example


@pytest.mark.parametrize("provider", authoring.MODEL_KEYS)
def test_reference_names_provider_and_excludes_candidate_data(tmp_path, monkeypatch, provider):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    store.initialize(store.db_path())
    for key in authoring.MODEL_KEYS[provider]:
        value = "https://workspace.openai.azure.com" if key.endswith("ENDPOINT") else "fixture"
        monkeypatch.setenv(key, value)
    sent = {}

    async def fake(name, method, url, **options):
        sent.update(options["json"])
        if name == "Anthropic":
            return {"stop_reason": "end_turn", "content": [{"type": "text", "text": "Example passage"}]}
        return {"choices": [{"finish_reason": "stop", "message": {"content": "Example passage"}}]}

    monkeypatch.setattr(authoring, "fetch_json", fake)
    result = asyncio.run(authoring.reference(Example(provider=provider, style="Talking points",
                                                     role="Engineer", question="How would you test recovery?")))
    assert provider in result["label"] and "Talking points" in result["label"]
    assert result["text"] == "Example passage" and result["permitted"] is False
    assert '"role": "Engineer"' in sent["messages"][-1]["content"]
    assert provider in authoring.providers()


@pytest.mark.parametrize("reply", ['{}', '[""]', '[1]', 'not questions'])
def test_invalid_question_draft_is_rejected(monkeypatch, reply):
    async def fake(*args):
        return "model", reply
    monkeypatch.setattr(authoring, "complete", fake)
    with pytest.raises(HTTPException, match="502"):
        asyncio.run(authoring.questions(Draft(provider="OpenAI", role="Operator", description="Repair pumps.")))


def test_question_draft_can_be_reviewed_before_storage(monkeypatch):
    async def fake(*args):
        return "model", '```json\n["What would you inspect first?", "What would you inspect first?"]\n```'
    monkeypatch.setattr(authoring, "complete", fake)
    result = asyncio.run(authoring.questions(Draft(provider="OpenAI", role="Operator", description="Repair pumps.")))
    assert result["questions"] == ["What would you inspect first?"]
