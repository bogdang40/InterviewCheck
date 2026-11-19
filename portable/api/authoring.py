"""Generate editable interview questions and comparison sources on explicit request."""
import asyncio
from contextvars import ContextVar
import json
import re
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import Field

from . import model_execution, model_resolver, prompt_framing, prompt_templates, rate_limit
from .access import require_entitlement
from .error_sanitizer import sanitize_error_text
from .models import Body, Input, Name, Question
from .provider_http import fetch_json

Provider = Name
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
STYLE_SLOTS = {
    "Spoken answer": "reference_spoken",
    "Talking points": "reference_talking_points",
    "Worked example": "reference_worked_example",
}
_capability: ContextVar[str] = ContextVar("authoring_capability", default="reference")
router = APIRouter(prefix="/api/authoring", dependencies=[Depends(require_entitlement)])


def _providers_for(cap: Literal["reference", "question_planning"]) -> list[str]:
    allow_ref = cap == "question_planning"
    names: list[str] = []
    for canonical in ("OpenAI", "Anthropic", "Azure OpenAI"):
        if model_resolver.resolve_capability(cap, provider=canonical, allow_reference_fallback=allow_ref, allow_slug_lookup=False) is not None:
            names.append(canonical)
    seen = set(names)
    rows = model_resolver.list_model_summaries(capability=cap)
    if allow_ref:
        seen_slugs = {row["slug"] for row in rows}
        rows = rows + [r for r in model_resolver.list_model_summaries(capability="reference") if r["slug"] not in seen_slugs]
    for row in rows:
        if not row["enabled"]:
            continue
        if row["provider"] == "openai_compatible" or not row["is_default"]:
            if row["slug"] not in seen:
                names.append(row["slug"])
                seen.add(row["slug"])
    return names


@router.get("/providers")
def providers(capability: Annotated[Literal["reference", "question_planning"] | None, Query()] = None):
    if capability is not None:
        return _providers_for(capability)
    return list(dict.fromkeys(_providers_for("reference") + _providers_for("question_planning")))


@router.get("/models")
def models(capability: Annotated[Literal["reference", "question_planning"] | None, Query()] = None):
    caps = (capability,) if capability is not None else ("reference", "question_planning")
    items: list[dict] = []
    seen_ids: set[str] = set()
    for cap in caps:
        for row in model_resolver.list_model_summaries(capability=cap):
            if row["enabled"] and row["id"] not in seen_ids:
                seen_ids.add(row["id"])
                items.append({
                    "id": row["id"],
                    "slug": row["slug"],
                    "display_name": row["display_name"],
                    "provider": row["provider"],
                    "capability": row["capability"],
                    "model_id": row["model_id"],
                    "is_default": row["is_default"],
                    "source": "registry",
                })
        for canonical in ("OpenAI", "Anthropic", "Azure OpenAI"):
            resolved = model_resolver.resolve_capability(
                cap, provider=canonical, allow_reference_fallback=(cap == "question_planning"), allow_slug_lookup=False
            )
            if resolved is not None and resolved.source == "env":
                items.append({
                    "id": None,
                    "slug": canonical,
                    "display_name": canonical,
                    "provider": resolved.provider,
                    "capability": cap,
                    "model_id": resolved.model_id,
                    "is_default": False,
                    "source": "env",
                })
    return {"models": items}


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
    cap = _capability.get()
    _, result = await model_execution.execute_completion_chain(
        cap,
        instructions,
        prompt,
        provider=provider,
        allow_reference_fallback=(cap == "question_planning"),
        fetch_fn=fetch_json,
    )
    return result


@router.post("/questions", dependencies=[Depends(rate_limit.limit(rate_limit.AI_REQUEST))])
async def questions(form: Draft):
    tpl = prompt_templates.resolve_slot("question_planning")
    instructions = prompt_framing.frame_instructions(tpl["system_prompt"], output_rule=tpl["output_rule"])
    prompt = prompt_framing.untrusted_json_prompt({"role": form.role, "description": form.description})
    token = _capability.set("question_planning")
    try:
        _, result = await complete(form.provider, instructions, prompt)
    finally:
        _capability.reset(token)
    try:
        items = json.loads(re.sub(r"^\s*```(?:json)?\s*|\s*```\s*$", "", result))
    except ValueError as error:
        raise HTTPException(502, "The provider returned unreadable questions.") from error
    if not isinstance(items, list) or not 1 <= len(items) <= 15:
        raise HTTPException(502, "The provider returned invalid questions.")
    cleaned: list[str] = []
    for item in items:
        if not isinstance(item, str):
            raise HTTPException(502, "The provider returned invalid questions.")
        text = prompt_framing.strip_control_chars(item, allow_newlines=True).strip()
        if not 1 <= len(text) <= 4000:
            raise HTTPException(502, "The provider returned invalid questions.")
        cleaned.append(text)
    return {"questions": list(dict.fromkeys(cleaned))}


@router.post("/reference", dependencies=[Depends(rate_limit.limit(rate_limit.AI_REQUEST))])
async def reference(form: Example):
    tpl = prompt_templates.resolve_slot(STYLE_SLOTS[form.style])
    instructions = prompt_framing.frame_instructions(tpl["system_prompt"], output_rule=tpl["output_rule"])
    prompt = prompt_framing.untrusted_json_prompt({"role": form.role, "question": form.question})
    model, text = await complete(form.provider, instructions, prompt)
    return {"label": f"{form.provider} · {model} · {form.style}"[:180], "text": prompt_framing.sanitize_model_text(text), "permitted": False}


class Recipient(Input):
    provider: Provider
    style: Literal["Spoken answer", "Talking points", "Worked example"]


class Lineup(Input):
    role: Name
    question: Question
    pairs: list[Recipient] = Field(min_length=1, max_length=3)
    existing_reference_count: int = Field(ge=0, le=12)


@router.post("/references", dependencies=[Depends(rate_limit.limit(rate_limit.AI_REQUEST))])
async def references(form: Lineup):
    pairs = {(item.provider, item.style) for item in form.pairs}
    if len(pairs) != len(form.pairs):
        raise HTTPException(422, "Choose each provider and format only once.")
    if form.existing_reference_count + len(pairs) > 12:
        raise HTTPException(422, "The selected requests exceed the twelve reference limit.")
    for provider in {item_provider for item_provider, _ in pairs}:
        if model_resolver.resolve_capability("reference", provider=provider) is None:
            raise HTTPException(503, "Configure all selected providers before starting the request.")

    async def generate(item):
        pair = item.model_dump()
        try:
            source = await reference(Example(**pair, role=form.role, question=form.question))
        except HTTPException as error:
            return {**pair, "error": sanitize_error_text(str(error.detail), "Reference generation failed.")}
        return {**pair, "source": source}

    return {"results": await asyncio.gather(*(generate(item) for item in form.pairs))}
