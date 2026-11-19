from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool

from . import access, access_admin, ats, audio, booking_sources, meeting_files, oauth_tokens
from .connection_catalog import router as catalog
from .mailbox import SETTINGS as MAIL_SETTINGS
from .calendar_sources import calendar_file, cloud_calendar
from .provider_http import configured, fetch_json, setting

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
    return {"transcription": configured("DEEPGRAM_API_KEY"),
            "reference": configured("OPENAI_API_KEY") and configured("INTERVIEWCHECK_REFERENCE_MODEL"),
            "access": access.account_enabled(), "inviteRequired": configured("INTERVIEWCHECK_SIGNUP_SECRET") or configured("INTERVIEWCHECK_PUBLIC_ORIGIN"),
            "ats": ats.sources(), "calendars": calendars + [name for name, key in booking_sources.KEYS.items() if configured(key)],
            "meetings": [name for name in ("zoom", "webex") if configured(booking_sources.KEYS[name])]
            + [name for name in ("meet", "teams") if oauth_tokens.available(name)]}


class ReferenceRequest(BaseModel):
    question: str = Field(min_length=1, max_length=4000)
    role: str = Field(default="", max_length=180)


@workspace.post("/reference")
async def reference(body: ReferenceRequest):
    model = setting("INTERVIEWCHECK_REFERENCE_MODEL")
    data = await fetch_json("OpenAI", "POST", "https://api.openai.com/v1/responses", timeout=75,
                            headers={"Authorization": "Bearer " + setting("OPENAI_API_KEY")},
                            json={"model": model, "store": False, "max_output_tokens": 1200,
                                  "instructions": "Provide a short sample interview answer to the supplied question for the stated role.",
                                  "input": f"Role: {body.role}\nInterview question: {body.question}"})
    try:
        if data.get("status") != "completed":
            raise HTTPException(502, "OpenAI did not complete the reference answer.")
        text = "\n".join(part["text"] for item in data["output"] if item.get("type") == "message"
                         for part in item["content"] if part.get("type") == "output_text").strip()
    except (KeyError, TypeError, AttributeError) as exc:
        raise HTTPException(502, "OpenAI returned an invalid reference.") from exc
    if not text:
        raise HTTPException(502, "OpenAI returned an empty reference.")
    return {"label": "OpenAI " + model, "text": text}


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
