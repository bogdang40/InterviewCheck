from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool

from . import access, access_admin, access_security, access_totp, ats, audio, authoring, booking_sources, meeting_files, model_execution, model_resolver, oauth_tokens, prompt_framing, rate_limit
from .connection_catalog import router as catalog
from .mailbox import SETTINGS as MAIL_SETTINGS
from .calendar_sources import calendar_file, cloud_calendar
from .provider_http import configured, fetch_json

router = APIRouter(prefix="/api/integrations")
router.include_router(access.router)
router.include_router(access_admin.router)
router.include_router(access_totp.router)
router.include_router(audio.router)
router.include_router(meeting_files.router)
router.include_router(access_security.router)
workspace = APIRouter(dependencies=[Depends(access.require_entitlement)])


@router.get("/status")
async def status(request: Request):
    account_on = access.account_enabled()
    prod_on = access.production_mode()
    invite_req = configured("INTERVIEWCHECK_SIGNUP_SECRET") or prod_on
    signed_in = False
    if account_on or prod_on:
        entitled = False
        if account_on and request.cookies.get(access.COOKIE):
            try:
                account = await access.snapshot(request)
                signed_in = True
                entitled = (account.get("entitlement") or {}).get("active") is True
            except HTTPException:
                signed_in = False
                entitled = False
        if not entitled:
            return {"access": account_on, "inviteRequired": invite_req, "signedIn": signed_in}
        signed_in = True
    calendars = [name for name in ("google", "microsoft") if oauth_tokens.available(name)]
    if all(configured(key) for key in MAIL_SETTINGS):
        calendars.append("imap")
    return {
        "transcription": model_resolver.resolve_capability("transcription") is not None,
        "reference": bool(authoring.providers("reference")),
        "embedding": model_resolver.resolve_capability("embedding") is not None,
        "judge": model_resolver.resolve_capability("judge") is not None,
        "access": account_on,
        "inviteRequired": invite_req,
        "signedIn": signed_in,
        "ats": ats.sources(),
        "calendars": calendars + [name for name, key in booking_sources.KEYS.items() if configured(key)],
        "meetings": [name for name in ("zoom", "webex") if configured(booking_sources.KEYS[name])]
        + [name for name in ("meet", "teams") if oauth_tokens.available(name)],
    }


@router.api_route("/admin", methods=["GET", "POST", "PUT", "DELETE", "PATCH"],
                  dependencies=[Depends(access_admin.admin_token), Depends(rate_limit.limit(rate_limit.ADMIN_READ))], include_in_schema=False)
@router.api_route("/admin/{unknown:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"],
                  dependencies=[Depends(access_admin.admin_token), Depends(rate_limit.limit(rate_limit.ADMIN_READ))], include_in_schema=False)
def missing_integration_admin(unknown: str = ""):
    raise HTTPException(404, "Unknown admin route.")


class ReferenceRequest(BaseModel):
    question: str = Field(min_length=1, max_length=4000)
    role: str = Field(default="", max_length=180)


@workspace.post("/reference", dependencies=[Depends(rate_limit.limit(rate_limit.AI_REQUEST))])
async def reference(body: ReferenceRequest):
    instructions = prompt_framing.frame_instructions(
        "Provide a short sample interview answer to the supplied question for the stated role.",
        output_rule="Return plain text only.",
    )
    user_input = prompt_framing.untrusted_json_prompt({"role": body.role.strip(), "question": body.question.strip()})
    _, (label, text) = await model_execution.execute_reference_chain(
        instructions,
        user_input,
        fetch_fn=fetch_json,
    )
    return {"label": label, "text": prompt_framing.sanitize_model_text(text)}


class FileText(BaseModel):
    text: str = Field(min_length=1, max_length=500_000)


@workspace.post("/calendar/file")
def import_calendar(body: FileText):
    return calendar_file(body.text)


@workspace.post("/calendar/sync/{provider}", dependencies=[Depends(rate_limit.limit(rate_limit.INTEGRATION_REMOTE))])
async def sync_calendar(provider: Literal["google", "microsoft", "zoom", "webex", "calcom", "calendly", "imap"]):
    if provider == "imap":
        from .mailbox import sync_imap
        return await run_in_threadpool(sync_imap)
    if provider in booking_sources.KEYS:
        return await booking_sources.bookings(provider)
    return await cloud_calendar(provider)


@workspace.post("/calendar/calendly/{booking_id}", dependencies=[Depends(rate_limit.limit(rate_limit.INTEGRATION_REMOTE))])
async def invitee(booking_id: UUID):
    return await booking_sources.calendly_candidate(booking_id)


@workspace.post("/ats/file")
def import_ats(body: FileText):
    return {"items": ats.csv_rows(body.text)}


class CandidateLookup(BaseModel):
    email: str = Field(min_length=3, max_length=254, pattern=r"^[^\s@]+@[^\s@]+\.[^\s@]+$")


@workspace.post("/ats/{provider}/lookup", dependencies=[Depends(rate_limit.limit(rate_limit.INTEGRATION_REMOTE))])
async def candidate_lookup(provider: ats.ATS, body: CandidateLookup):
    return {"items": await ats.lookup(provider, body.email)}


workspace.include_router(catalog)
router.include_router(workspace)
