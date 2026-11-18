"""Generate editable interview questions and comparison sources on explicit request."""
import asyncio
import json
import re
from typing import Literal
from urllib.parse import quote, urlsplit

from fastapi import APIRouter, Depends, HTTPException
from pydantic import Field

from .access import require_entitlement
from .models import Input, Name, Question, Body
from .provider_http import configured, fetch_json, setting

Provider = Literal["OpenAI", "Anthropic", "Azure OpenAI"]
MODEL_KEYS = {
    "OpenAI": ("OPENAI_API_KEY", "INTERVIEWCHECK_REFERENCE_MODEL"),
    "Anthropic": ("ANTHROPIC_API_KEY", "INTERVIEWCHECK_ANTHROPIC_MODEL"),
    "Azure OpenAI": ("AZURE_OPENAI_API_KEY", "AZURE_OPENAI_DEPLOYMENT", "AZURE_OPENAI_ENDPOINT", "AZURE_OPENAI_API_VERSION"),
}
STYLES = {
    "Spoken answer": "Give a short conversational answer to this interview question.",
    "Talking points": "Give three concise points in the order someone might explain this answer aloud.",
    "Worked example": "Answer the question with a concrete worked example and one limitation.",
}
router = APIRouter(prefix="/api/authoring", dependencies=[Depends(require_entitlement)])


@router.get("/providers")
def providers():
    return [name for name, keys in MODEL_KEYS.items() if all(configured(key) for key in keys)]


class Draft(Input):
    provider: Provider
    role: Name
    description: Body


class Example(Input):
    provider: Provider
    style: Literal["Spoken answer", "Talking points", "Worked example"]
    question: Question
    role: Name


async def complete(provider, instructions, prompt):
    key_name, model_name, *_ = MODEL_KEYS[provider]
    model = setting(model_name)
    key = setting(key_name)
    if provider == "Anthropic":
        data = await fetch_json(provider, "POST", "https://api.anthropic.com/v1/messages",
                                headers={"x-api-key": key, "anthropic-version": "2023-06-01"},
                                json={"model": model, "max_tokens": 1600, "system": instructions,
                                      "messages": [{"role": "user", "content": prompt}]}, timeout=75)
        if not isinstance(data, dict) or data.get("stop_reason") not in {"end_turn", "stop_sequence"}:
            raise HTTPException(502, "Anthropic did not complete its response.")
        blocks = data.get("content")
        text = "\n".join(b["text"] for b in blocks if isinstance(b, dict)
                         and b.get("type") == "text" and isinstance(b.get("text"), str)) if isinstance(blocks, list) else ""
    else:
        messages = [{"role": "system", "content": instructions}, {"role": "user", "content": prompt}]
        body = {"messages": messages, "max_completion_tokens": 2000}
        if provider == "Azure OpenAI":
            try:
                root = urlsplit(setting("AZURE_OPENAI_ENDPOINT"))
            except ValueError as error:
                raise HTTPException(503, "Configure a valid Azure OpenAI HTTPS endpoint.") from error
            if root.scheme != "https" or not root.hostname or not root.hostname.endswith(".openai.azure.com") or root.netloc != root.hostname:
                raise HTTPException(503, "Configure a valid Azure OpenAI HTTPS endpoint.")
            url = f"https://{root.hostname}/openai/deployments/{quote(model, safe='')}/chat/completions"
            headers, params = {"api-key": key}, {"api-version": setting("AZURE_OPENAI_API_VERSION")}
        else:
            url = "https://api.openai.com/v1/chat/completions"
            headers, params = {"Authorization": "Bearer " + key}, {}
            body["model"] = model
            body["store"] = False
        data = await fetch_json(provider, "POST", url, json=body, headers=headers, params=params, timeout=75)
        try:
            choice = data["choices"][0]
            if choice.get("finish_reason") != "stop":
                raise HTTPException(502, f"{provider} did not complete its response.")
            text = choice["message"]["content"]
        except (KeyError, TypeError, IndexError, AttributeError) as error:
            raise HTTPException(502, f"{provider} returned an invalid response.") from error
    if not isinstance(text, str) or not 0 < len(text.strip()) <= 24000:
        raise HTTPException(502, f"{provider} returned no usable text.")
    return model, text.strip()


@router.post("/questions")
async def questions(form: Draft):
    _, result = await complete(form.provider, "Write six interview questions specific to the role. Include a worked example, "
                               "a change of constraints and a question about the candidate's own experience. "
                               "Return a JSON array of question strings.", json.dumps({"role": form.role, "description": form.description}))
    try:
        items = json.loads(re.sub(r"^\s*```(?:json)?\s*|\s*```\s*$", "", result))
    except ValueError as error:
        raise HTTPException(502, "The provider returned unreadable questions.") from error
    if not isinstance(items, list) or not 1 <= len(items) <= 15 or not all(
        isinstance(q, str) and 1 <= len(q.strip()) <= 4000 for q in items
    ):
        raise HTTPException(502, "The provider returned invalid questions.")
    return {"questions": list(dict.fromkeys(q.strip() for q in items))}


@router.post("/reference")
async def reference(form: Example):
    model, text = await complete(form.provider, STYLES[form.style], json.dumps({"role": form.role, "question": form.question}))
    return {"label": f"{form.provider} · {model} · {form.style}"[:180], "text": text, "permitted": False}


class Recipient(Input):
    provider: Provider
    style: Literal["Spoken answer", "Talking points", "Worked example"]


class Lineup(Input):
    role: Name
    question: Question
    pairs: list[Recipient] = Field(min_length=1, max_length=3)
    existing_reference_count: int = Field(ge=0, le=12)


@router.post("/references")
async def references(form: Lineup):
    pairs = {(item.provider, item.style) for item in form.pairs}
    if len(pairs) != len(form.pairs):
        raise HTTPException(422, "Choose each provider and format only once.")
    if form.existing_reference_count + len(pairs) > 12:
        raise HTTPException(422, "The selected requests exceed the twelve reference limit.")
    available = set(providers())
    if any(provider not in available for provider, _ in pairs):
        raise HTTPException(503, "Configure all selected providers before starting the request.")

    async def generate(item):
        pair = item.model_dump()
        try:
            source = await reference(Example(**pair, role=form.role, question=form.question))
        except HTTPException as error:
            return {**pair, "error": str(error.detail)}
        return {**pair, "source": source}

    return {"results": await asyncio.gather(*(generate(item) for item in form.pairs))}
