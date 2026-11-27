"""Entitled workspace reads and administrator writes for panel discussions."""
from typing import Annotated, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import Field, StringConstraints, field_validator

from . import access, panel_authority, panel_ledger, rate_limit, store
from .models import Input

router = APIRouter(tags=["calibration"])
HEX = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
ROUTE = "/calibration/sessions/{sid}/answers/{aid}/panel"


class PanelInput(Input):
    action: Literal["discussion_complete", "follow_up_required", "reopened"]
    expected_evidence: HEX
    expected_basis: HEX
    expected_version: HEX
    expected_editor: HEX
    rationale: str = Field(min_length=1, max_length=1000)

    @field_validator("rationale")
    @classmethod
    def valid_rationale(cls, value):
        if not value.replace("\n", "").isprintable():
            raise ValueError("Use printable text in the panel rationale.")
        return value


def _read(sid, aid, before, private, actor=None):
    with store.connection() as db:
        case = panel_ledger.read_case(db, sid, aid)
        if actor is not None:
            case["editor"] = panel_authority.context(db, sid, aid, actor)
        return {**case, "history": panel_ledger.history(db, sid, aid, before=before, private=private)}


@router.get(ROUTE)
def read(sid: UUID, aid: UUID, before: int | None = Query(default=None, ge=1, le=2**63-1)):
    return _read(str(sid), str(aid), before, False)


async def administrator(request: Request):
    user, token = await access.require_admin_session(request)
    uid, email = user.get("id"), user.get("email")
    if not all(isinstance(v, str) and v.strip() == v and v and len(v) <= cap and
               v.isprintable() for v, cap in ((uid, 180), (email, 320))):
        raise HTTPException(403, "A named administrator account is required for private panel review.")
    if access.account_enabled():
        entitled = await access.require_entitlement(request)
        if not entitled or (entitled.get("id"), entitled.get("email")) != (uid, email):
            raise HTTPException(403, "Read this panel again using the currently entitled administrator account.")
    return panel_authority.Editor(uid, email, token)


@router.get(ROUTE + "/edit")
def read_editor(sid: UUID, aid: UUID, before: int | None = Query(default=None, ge=1, le=2**63-1),
                actor=Depends(administrator)):
    return _read(str(sid), str(aid), before, False, actor)


@router.get(ROUTE + "/private")
def read_private(sid: UUID, aid: UUID, before: int | None = Query(default=None, ge=1, le=2**63-1),
                 actor=Depends(administrator)):
    return _read(str(sid), str(aid), before, True, actor)


@router.post(ROUTE, dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
def record(sid: UUID, aid: UUID, payload: PanelInput, actor=Depends(administrator)):
    return _record(str(sid), str(aid), payload, actor)


def _record(sid, aid, payload, actor):
    with store.connection(write=True) as db:
        panel_authority.verify(db, sid, aid, payload.expected_editor, actor)
        case = panel_ledger.transition(db, sid, aid, payload=payload, actor=(actor.user_id, actor.email), timestamp=store.timestamp())
        case["editor"] = panel_authority.context(db, sid, aid, actor)
        return {**case, "history": panel_ledger.history(db, sid, aid, private=True)}
