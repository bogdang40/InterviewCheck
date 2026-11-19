import math
from typing import Any, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool

from . import access, access_admin, ats, audio, authoring, booking_sources, meeting_files, model_resolver, oauth_tokens
from .connection_catalog import router as catalog
from .mailbox import SETTINGS as MAIL_SETTINGS
from .calendar_sources import calendar_file, cloud_calendar
from .provider_http import configured, fetch_json

_ORIG_FETCH_JSON = fetch_json
router = APIRouter(prefix="/api/integrations")
router.include_router(access.router)
router.include_router(access_admin.router)
router.include_router(audio.router)
router.include_router(meeting_files.router)
workspace = APIRouter(dependencies=[Depends(access.require_entitlement)])


@router.get("/status")
def status():
    calendars = [name for name in ("google", "microsoft") if oauth_tokens.available(name)]
    if all(configured(key) for key in MAIL_SETTINGS):
        calendars.append("imap")
    return {"transcription": model_resolver.resolve_capability("transcription") is not None,
            "reference": bool(authoring.providers("reference")),
            "embedding": model_resolver.resolve_capability("embedding") is not None,
            "judge": model_resolver.resolve_capability("judge") is not None,
            "access": access.account_enabled(), "inviteRequired": configured("INTERVIEWCHECK_SIGNUP_SECRET") or configured("INTERVIEWCHECK_PUBLIC_ORIGIN"),
            "ats": ats.sources(), "calendars": calendars + [name for name, key in booking_sources.KEYS.items() if configured(key)],
            "meetings": [name for name in ("zoom", "webex") if configured(booking_sources.KEYS[name])]
            + [name for name in ("meet", "teams") if oauth_tokens.available(name)]}


class ReferenceRequest(BaseModel):
    question: str = Field(min_length=1, max_length=4000)
    role: str = Field(default="", max_length=180)


@workspace.post("/reference")
async def reference(body: ReferenceRequest):
    target = model_resolver.resolve_or_503("reference")
    limit_tokens = target.config.get("max_tokens") or 1200
    if target.provider != "openai":
        model_id, text = await model_resolver.dispatch_completion(
            target,
            "Provide a short sample interview answer to the supplied question for the stated role.",
            f"Role: {body.role}\nInterview question: {body.question}",
            fetch_fn=fetch_json,
            max_tokens=limit_tokens,
        )
        return {"label": f"{target.display_name} {model_id}"[:180], "text": text}

    extra_opts = {"ssrf_safe": True} if fetch_json is _ORIG_FETCH_JSON else {}
    raw_timeout = target.config.get("timeout_s")
    if isinstance(raw_timeout, (int, float)) and not isinstance(raw_timeout, bool) and math.isfinite(raw_timeout):
        timeout = min(max(float(raw_timeout), 1.0), 180.0)
    else:
        timeout = 75.0
    payload: dict[str, Any] = {
        "model": target.model_id,
        "store": False,
        "max_output_tokens": limit_tokens,
        "instructions": "Provide a short sample interview answer to the supplied question for the stated role.",
        "input": f"Role: {body.role}\nInterview question: {body.question}",
    }
    if target.config.get("temperature") is not None:
        payload["temperature"] = target.config["temperature"]
    data = await fetch_json("OpenAI", "POST", "https://api.openai.com/v1/responses", timeout=timeout,
                            headers={"Authorization": "Bearer " + target.api_key},
                            json=payload, **extra_opts)
    try:
        if data.get("status") != "completed":
            raise HTTPException(502, "OpenAI did not complete the reference answer.")
        text = "\n".join(part["text"] for item in data["output"] if item.get("type") == "message"
                         for part in item["content"] if part.get("type") == "output_text").strip()
    except (KeyError, TypeError, AttributeError) as exc:
        raise HTTPException(502, "OpenAI returned an invalid reference.") from exc
    if not text:
        raise HTTPException(502, "OpenAI returned an empty reference.")
    return {"label": "OpenAI " + target.model_id, "text": text}


class FileText(BaseModel):
    text: str = Field(min_length=1, max_length=500_000)


@workspace.post("/calendar/file")
def import_calendar(body: FileText):
    return calendar_file(body.text)


@workspace.post("/calendar/sync/{provider}")
async def sync_calendar(provider: Literal["google", "microsoft", "zoom", "webex", "calcom", "calendly", "imap"]):
    if provider == "imap":
        from .mailbox import sync_imap
        return await run_in_threadpool(sync_imap)
    if provider in booking_sources.KEYS:
        return await booking_sources.bookings(provider)
    return await cloud_calendar(provider)


@workspace.post("/calendar/calendly/{booking_id}")
async def invitee(booking_id: UUID):
    return await booking_sources.calendly_candidate(booking_id)


@workspace.post("/ats/file")
def import_ats(body: FileText):
    return {"items": ats.csv_rows(body.text)}


class CandidateLookup(BaseModel):
    email: str = Field(min_length=3, max_length=254, pattern=r"^[^\s@]+@[^\s@]+\.[^\s@]+$")


@workspace.post("/ats/{provider}/lookup")
async def candidate_lookup(provider: ats.ATS, body: CandidateLookup):
    return {"items": await ats.lookup(provider, body.email)}


workspace.include_router(catalog)
router.include_router(workspace)
