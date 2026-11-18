"""Preview, explicitly send, and retain the delivery state of a private ATS note."""
import re
from typing import Literal
from uuid import UUID, uuid4
from urllib.parse import quote

from fastapi import APIRouter, HTTPException
from pydantic import Field

from . import ats, store
from .ats_directory import subdomain
from .models import Input
from .provider_http import configured, fetch_json, setting

router = APIRouter()
Provider = Literal["ashby", "lever", "greenhouse", "merge", "workable", "recruitee"]


def destinations():
    requirements = {"ashby": (), "lever": (), "greenhouse": (), "merge": ("MERGE_REMOTE_USER_ID",),
                    "workable": ("WORKABLE_MEMBER_ID",), "recruitee": ()}
    return [name for name in ats.sources() if name in requirements and all(configured(k) for k in requirements[name])]


class RecipientQuery(Input):
    provider: Provider
    email: str = Field(min_length=3, max_length=254, pattern=r"^[^\s@]+@[^\s@]+\.[^\s@]+$")


class Draft(RecipientQuery):
    target_id: str = Field(min_length=1, max_length=160, pattern=r"^[A-Za-z0-9_-]+$")


class Delivery(Input):
    note: str = Field(min_length=1, max_length=8000)
    confirmed: Literal[True]


def receipt(db, sid, draft_id):
    row = db.execute("SELECT * FROM note_exports WHERE id=? AND session_id=?", (draft_id, sid)).fetchone()
    if row is None:
        raise HTTPException(404, "Note draft does not exist in this session.")
    return dict(row)


def draft_text(session):
    # Only the human record is proposed for external transfer. The operator can edit it.
    parts = [f"Interview with {session['candidate']} for {session['role']}."]
    for i, answer in enumerate(session["answers"], 1):
        if answer["disposition"] != "pending" or answer["note"]:
            parts.append(f"Question {i}: {answer['question']}\nInterviewer outcome: {answer['disposition']}\n{answer['note']}".strip())
    return "\n\n".join(parts)[:8000]


@router.get("/sessions/{sid}/ats")
def state(sid: UUID):
    with store.connection() as db:
        store.get_summary(db, str(sid))
        rows = db.execute("SELECT id,state,provider,recipient,remote_id FROM note_exports WHERE session_id=? ORDER BY rowid DESC LIMIT 20",
                          (str(sid),))
        return {"providers": destinations(), "history": [dict(r) for r in rows]}


@router.post("/sessions/{sid}/ats/recipients")
async def recipients(sid: UUID, query: RecipientQuery):
    with store.connection() as db:
        store.get_summary(db, str(sid))
    if query.provider not in destinations():
        raise HTTPException(503, "Configure a provider with private note access.")
    return [r for r in await ats.lookup(query.provider, query.email, with_id=True) if r.get("target_id")]


@router.post("/sessions/{sid}/ats/drafts")
async def prepare(sid: UUID, form: Draft):
    # Re-resolve at preview so the destination is a provider record with an actual name.
    options = await recipients(sid, form)
    target = next((r for r in options if r["target_id"] == form.target_id), None)
    if target is None:
        raise HTTPException(409, "The selected candidate is no longer in the provider search results.")
    with store.connection(write=True) as db:
        session = store.get_session(db, str(sid))
        key = str(uuid4())
        db.execute("INSERT INTO note_exports VALUES (?,?,?,?,?,?,?,?)",
                   (key, str(sid), form.provider, form.target_id, target["candidate"], draft_text(session), "draft", store.timestamp()))
        return receipt(db, str(sid), key)


async def send_private(provider, target, text):
    if provider == "ashby":
        result = await fetch_json("Ashby", "POST", "https://api.ashbyhq.com/candidate.createNote",
            auth=(setting("ASHBY_API_KEY"), ""), headers={"Accept": "application/json; version=1"},
            json={"candidateId": target, "note": {"type": "text/plain", "value": text}, "isPrivate": True, "sendNotifications": False})
        if not isinstance(result, dict) or result.get("success") is not True:
            raise HTTPException(502, "Ashby did not confirm note creation.")
    elif provider == "lever":
        await fetch_json("Lever", "POST", f"https://api.lever.co/v1/opportunities/{target}/notes",
                         auth=(setting("LEVER_API_KEY"), ""), json={"value": text, "secret": True, "notifyFollowers": False})
    elif provider == "workable":
        host = subdomain("WORKABLE_SUBDOMAIN") + ".workable.com"
        await fetch_json("Workable", "POST", f"https://{host}/spi/v3/candidates/{target}/comments",
                         headers={"Authorization": "Bearer " + setting("WORKABLE_API_KEY")},
                         json={"member_id": setting("WORKABLE_MEMBER_ID"), "comment": {"body": text, "policy": ["admin"]}})
    elif provider == "recruitee":
        base = "https://api.recruitee.com/c/" + quote(setting("RECRUITEE_COMPANY_ID"), safe="")
        headers = {"Authorization": "Bearer " + setting("RECRUITEE_API_KEY")}
        account = await fetch_json("Recruitee", "GET", base + "/admin", headers=headers)
        record = account.get("admin") if isinstance(account, dict) else None
        admin = record.get("id") if isinstance(record, dict) else None
        if type(admin) is not int or admin <= 0:
            raise HTTPException(502, "Recruitee did not identify the account for protected visibility.")
        await fetch_json("Recruitee", "POST", f"{base}/candidates/{target}/notes", headers=headers,
                         json={"note": {"body": text, "visibility": {"level": "protected", "admin_ids": [admin], "role_ids": []}},
                               "attachments": []})
    elif provider == "merge":
        headers = {"Authorization": "Bearer " + setting("MERGE_API_KEY"), "X-Account-Token": setting("MERGE_ACCOUNT_TOKEN")}
        url = "https://api.merge.dev/api/ats/v1/activities"
        schema = await fetch_json("Merge", "GET", url + "/meta/post", headers=headers)
        try:
            visibility = schema["request_schema"]["properties"]["model"]["properties"]["visibility"]
        except (KeyError, TypeError):
            visibility = None
        if not isinstance(visibility, dict) or ("enum" in visibility and "PRIVATE" not in (visibility["enum"] or [])):
            raise HTTPException(422, "The linked ATS does not advertise private activity visibility.")
        result = await fetch_json("Merge", "POST", url, headers=headers,
            json={"remote_user_id": setting("MERGE_REMOTE_USER_ID"), "model": {
                "candidate": target, "activity_type": "NOTE", "subject": "InterviewCheck", "body": text, "visibility": "PRIVATE"}})
        model = result.get("model") if isinstance(result, dict) else None
        if not isinstance(model, dict) or model.get("visibility") != "PRIVATE" or result.get("warnings") or result.get("errors"):
            raise HTTPException(502, "Merge did not confirm private note visibility.")
    else:
        if not target.isascii() or not target.isdigit():
            raise HTTPException(422, "Invalid Greenhouse candidate ID.")
        token = await fetch_json("Greenhouse", "POST", "https://auth.greenhouse.io/token",
            auth=(setting("GREENHOUSE_CLIENT_ID"), setting("GREENHOUSE_CLIENT_SECRET")), data={"grant_type": "client_credentials"})
        access = token.get("access_token") if isinstance(token, dict) else None
        if not isinstance(access, str) or not access:
            raise HTTPException(502, "Greenhouse did not return an access token.")
        await fetch_json("Greenhouse", "POST", "https://harvest.greenhouse.io/v3/notes", headers={"Authorization": "Bearer " + access},
            json={"candidate_id": int(target), "note_type": "NOTE", "visibility": "private", "body": text})


@router.post("/sessions/{sid}/ats/drafts/{draft_id}/send")
async def send(sid: UUID, draft_id: UUID, form: Delivery):
    session_id, key = str(sid), str(draft_id)
    with store.connection(write=True) as db:
        row = receipt(db, session_id, key)
        if row["state"] == "sent" and row["draft"] == form.note:
            return row
        if row["state"] != "draft":
            raise HTTPException(409, "This draft already has a delivery attempt. Check the destination before preparing another.")
        if row["provider"] not in destinations():
            raise HTTPException(503, "Configure a provider with private note access.")
        if row["provider"] == "lever" and re.search(r"(?<![\w.+-])@[\w.-]+", form.note):
            raise HTTPException(422, "Remove user mentions. Lever grants mentioned users access to the note.")
        db.execute("UPDATE note_exports SET state='attempted',draft=? WHERE id=?", (form.note, key))
    # Persist the attempt before the network call. A crash, concurrent send or
    # lost response must not cause an automatic duplicate note upstream.
    try:
        await send_private(row["provider"], row["remote_id"], form.note)
    except HTTPException as error:
        raise HTTPException(error.status_code, f"{error.detail} Delivery unconfirmed. Check the ATS before preparing another note.") from error
    with store.connection(write=True) as db:
        db.execute("UPDATE note_exports SET state='sent' WHERE id=?", (key,))
        return receipt(db, session_id, key)
