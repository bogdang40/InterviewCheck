"""The Azure OpenAI connection test must work for reasoning deployments (gpt-5 family, o-series)."""
import asyncio
import json

import httpx

from api import model_probe


def _reasoning_deployment(request: httpx.Request) -> httpx.Response:
    # Azure answers 400 when max_completion_tokens leaves no room to finish reasoning.
    body = json.loads(request.content)
    if body.get("max_completion_tokens", 0) < 16:
        return httpx.Response(400, json={"error": {"message": "Could not finish the message because max_tokens or model output limit was reached."}})
    return httpx.Response(200, json={"choices": [{"finish_reason": "stop", "message": {"content": "ok"}}]})


def test_azure_chat_probe_leaves_room_for_reasoning():
    seen = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return _reasoning_deployment(request)

    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            return await model_probe._run_provider_probe(
                client, provider="azure_openai", capability="judge", model_id="team-gpt-5-mini",
                endpoint="https://example.cognitiveservices.azure.com", api_version="2025-04-01-preview", api_key="k",
            )

    status, _ = asyncio.run(run())
    assert status == 200
    assert seen[0].url.path == "/openai/deployments/team-gpt-5-mini/chat/completions"
    assert json.loads(seen[0].content)["max_completion_tokens"] == model_probe.PROBE_COMPLETION_TOKENS
