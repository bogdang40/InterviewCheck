"""Preview, explicitly send, and retain the delivery state of a private ATS note."""
import re
from typing import Literal
from uuid import UUID, uuid4
from urllib.parse import quote

from fastapi import APIRouter, Depends, HTTPException
from pydantic import Field

from . import ats, rate_limit, store
from .ats_directory import subdomain
from .models import Input
from .provider_http import configured, fetch_json, setting

router = APIRouter()
Provider = Literal["ashby", "lever", "greenhouse", "merge", "workable", "recruitee"]


NOTE_KEYS = {"ashby": (), "lever": (), "greenhouse": (), "merge": ("MERGE_REMOTE_USER_ID",),
             "workable": ("WORKABLE_MEMBER_ID",), "recruitee": ()}


def destinations():
    return [name for name in ats.sources() if name in NOTE_KEYS and all(configured(k) for k in NOTE_KEYS[name])]


class RecipientQuery(Input):
    provider: Provider
    email: str = Field(min_length=3, max_length=254, pattern=r"^[^\s@]+@[^\s@]+\.[^\s@]+$")


class Draft(RecipientQuery):
    target_id: str = Field(min_length=1, max_length=160, pattern=r"^[A-Za-z0-9_-]+$")


class Delivery(Input):
    note: str = Field(min_length=1, max_length=8000)
    confirmed: Literal[True]


def receipt(db, sid, draft_id):
    row = db.execute("""SELECT n.* FROM note_exports n JOIN active_sessions s ON s.id=n.session_id
                        WHERE n.id=? AND n.session_id=?""", (draft_id, sid)).fetchone()
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


def begin_operation(db, sid):
    store.get_summary(db, sid)
    db.execute("INSERT OR IGNORE INTO ats_access_versions(session_id,version) VALUES(?,?)", (sid, str(uuid4())))
    return db.execute("SELECT version FROM ats_access_versions WHERE session_id=?", (sid,)).fetchone()[0]


def check_operation(db, sid, version):
    allowed = db.execute("""SELECT 1 FROM ats_access_versions v JOIN active_sessions s ON s.id=v.session_id
                            WHERE v.session_id=? AND v.version=?""", (sid, version)).fetchone()
    if not allowed:
        raise HTTPException(404, "The original interview is no longer available for this operation.")


async def find_recipients(query):
    if query.provider not in destinations():
        raise HTTPException(503, "Configure a provider with private note access.")
    found = await ats.lookup(query.provider, query.email, with_id=True)
    return [r for r in found if r.get("target_id")]


@router.post("/sessions/{sid}/ats/recipients", dependencies=[Depends(rate_limit.limit(rate_limit.INTEGRATION_REMOTE))])
async def recipients(sid: UUID, query: RecipientQuery):
    with store.connection(write=True) as db:
        version = begin_operation(db, str(sid))
    options = await find_recipients(query)
    with store.connection() as db:
        check_operation(db, str(sid), version)
    return options


@router.post("/sessions/{sid}/ats/drafts", dependencies=[Depends(rate_limit.limit(rate_limit.INTEGRATION_REMOTE))])
async def prepare(sid: UUID, form: Draft):
    # Re-resolve at preview so the destination is a provider record with an actual name.
    with store.connection(write=True) as db:
        version = begin_operation(db, str(sid))
    options = await find_recipients(form)
    with store.connection(write=True) as db:
        check_operation(db, str(sid), version)
        target = next((r for r in options if r["target_id"] == form.target_id), None)
        if target is None:
            raise HTTPException(409, "The selected candidate is no longer in the provider search results.")
        session = store.get_session(db, str(sid))
        key = str(uuid4())
        db.execute("INSERT INTO note_exports VALUES (?,?,?,?,?,?,?,?)",
                   (key, str(sid), form.provider, form.target_id, target["candidate"], draft_text(session), "draft", store.timestamp()))
        return receipt(db, str(sid), key)


async def send_private(provider, target, text, *, before_send=None):
    async def deliver(name, url, **kwargs):
        if before_send is not None:
            before_send()
        return await fetch_json(name, "POST", url, **kwargs)

    if provider == "ashby":
        result = await deliver("Ashby", "https://api.ashbyhq.com/candidate.createNote",
            auth=(setting("ASHBY_API_KEY"), ""), headers={"Accept": "application/json; version=1"},
            json={"candidateId": target, "note": {"type": "text/plain", "value": text}, "isPrivate": True, "sendNotifications": False})
        if not isinstance(result, dict) or result.get("success") is not True:
            raise HTTPException(502, "Ashby did not confirm note creation.")
    elif provider == "lever":
        await deliver("Lever", f"https://api.lever.co/v1/opportunities/{target}/notes",
                         auth=(setting("LEVER_API_KEY"), ""), json={"value": text, "secret": True, "notifyFollowers": False})
    elif provider == "workable":
        host = subdomain("WORKABLE_SUBDOMAIN") + ".workable.com"
        await deliver("Workable", f"https://{host}/spi/v3/candidates/{target}/comments",
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
        await deliver("Recruitee", f"{base}/candidates/{target}/notes", headers=headers,
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
        result = await deliver("Merge", url, headers=headers,
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
        await deliver("Greenhouse", "https://harvest.greenhouse.io/v3/notes", headers={"Authorization": "Bearer " + access},
            json={"candidate_id": int(target), "note_type": "NOTE", "visibility": "private", "body": text})


@router.post("/sessions/{sid}/ats/drafts/{draft_id}/send", dependencies=[Depends(rate_limit.limit(rate_limit.INTEGRATION_REMOTE))])
async def send(sid: UUID, draft_id: UUID, form: Delivery):
    session_id, key = str(sid), str(draft_id)
    with store.connection(write=True) as db:
        version = begin_operation(db, session_id)
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
    def before_send():
        with store.connection() as db:
            check_operation(db, session_id, version)
    try:
        await send_private(row["provider"], row["remote_id"], form.note, before_send=before_send)
    except HTTPException as error:
        before_send()
        raise HTTPException(error.status_code, f"{error.detail} Delivery unconfirmed. Check the ATS before preparing another note.") from error
    with store.connection(write=True) as db:
        # The vendor can finish after the operator has removed the session.
        # Never recreate an export or disclose its destination from Trash.
        check_operation(db, session_id, version)
        receipt(db, session_id, key)
        db.execute("UPDATE note_exports SET state='sent' WHERE id=? AND session_id=? AND state='attempted'", (key, session_id))
        return receipt(db, session_id, key)
