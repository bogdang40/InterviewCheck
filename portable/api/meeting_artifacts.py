"""Read meeting metadata first. Resolve a selected conference's files only on request."""
from datetime import datetime, timedelta, timezone
import re
from urllib.parse import quote

from fastapi import HTTPException

from . import oauth_tokens
from .provider_http import fetch_json

MEET = "https://meet.googleapis.com/v2/"
GRAPH = "https://graph.microsoft.com/v1.0/"


def instant(value):
    stamp = datetime.fromisoformat(value)
    return stamp if stamp.tzinfo else stamp.replace(tzinfo=timezone.utc)


def meet_path(name, expected):
    if not isinstance(name, str) or not re.fullmatch(expected, name):
        raise ValueError("Invalid Meet resource name.")
    return name


async def conferences(source):
    hdr = await oauth_tokens.bearer(source)
    end = datetime.now(timezone.utc)
    start = end - timedelta(days=29)
    if source == "meet":
        data = await fetch_json("Google Meet", "GET", MEET + "conferenceRecords", headers=hdr,
                                params={"filter": f'start_time >= "{start.isoformat()}"', "pageSize": 50})
        rows = [{"location": meet_path(row["name"], r"conferenceRecords/[\w-]+"),
                 "title": "Google Meet " + row["name"].split("/")[-1], "start": row["startTime"], "end": row["endTime"]}
                for row in data.get("conferenceRecords", []) if row.get("endTime")]
        more = data.get("nextPageToken")
    else:
        data = await fetch_json("Microsoft 365", "GET", GRAPH + "me/calendarView", headers={**hdr, "Prefer": 'outlook.timezone="UTC"'},
                                params={"startDateTime": start.isoformat(), "endDateTime": end.isoformat(), "$top": 100,
                                        "$select": "subject,start,end,isCancelled,onlineMeeting,onlineMeetingProvider",
                                        "$orderby": "start/dateTime desc"})
        rows = [{"location": row["onlineMeeting"]["joinUrl"], "title": row.get("subject") or "Teams meeting",
                 "start": instant(row["start"]["dateTime"]).isoformat(), "end": instant(row["end"]["dateTime"]).isoformat()}
                for row in data.get("value", []) if not row.get("isCancelled") and row.get("onlineMeetingProvider") == "teamsForBusiness"
                and (row.get("onlineMeeting") or {}).get("joinUrl")]
        more = data.get("@odata.nextLink")
    return rows, bool(more)


async def files(source, location, start, end):
    hdr = await oauth_tokens.bearer(source)
    if source == "meet":
        data = await fetch_json("Google Meet", "GET", MEET + location + "/transcripts", headers=hdr, params={"pageSize": 100})
        paths = [("transcript", meet_path(row["name"], re.escape(location) + r"/transcripts/[\w-]+"))
                 for row in data.get("transcripts", []) if row.get("state") in {"FILE_GENERATED", "ENDED"}]
        return paths, "First 100 transcripts shown." if data.get("nextPageToken") else ""
    lookup = await fetch_json("Microsoft Teams", "GET", GRAPH + "me/onlineMeetings", headers=hdr,
                              params={"$filter": "JoinWebUrl eq '" + location.replace("'", "''") + "'"})
    if not lookup.get("value"):
        raise HTTPException(404, "Teams did not return a meeting for this occurrence.")
    mid = quote(lookup["value"][0]["id"], safe="")
    prefix = GRAPH + "me/onlineMeetings/" + mid + "/"
    paths = []
    warnings = []
    for collection, kind in (("transcripts", "transcript"), ("recordings", "video")):
        try:
            data = await fetch_json("Microsoft Teams", "GET", prefix + collection, headers=hdr)
        except HTTPException as exc:
            if exc.status_code != 403:
                raise
            warnings.append("Teams denied access to " + collection + ".")
            continue
        for row in data["value"]:
            created = instant(row["createdDateTime"])
            if instant(start) - timedelta(hours=1) <= created <= instant(end) + timedelta(hours=3):
                loc = prefix + collection + "/" + quote(row["id"], safe="") + "/content"
                paths.append((kind, loc + ("?$format=text/vtt" if kind == "transcript" else "")))
        if data.get("@odata.nextLink"):
            warnings.append("More " + collection + " exist outside the first page.")
    return paths, " ".join(warnings)


async def meet_segments(path):
    hdr = await oauth_tokens.bearer("meet")
    conference = path.split("/transcripts/", 1)[0]
    participants = await fetch_json("Google Meet", "GET", MEET + conference + "/participants", headers=hdr, params={"pageSize": 100})
    names = {}
    for index, participant in enumerate(participants.get("participants", []), 1):
        name = next((participant[key].get("displayName") for key in ("signedinUser", "anonymousUser", "phoneUser")
                     if isinstance(participant.get(key), dict) and participant[key].get("displayName")), "")
        names[participant["name"]] = f"{name} ({index})" if name else f"Speaker {index}"
    entries = []
    total_bytes = 0
    cursor = None
    for _ in range(50):
        query = {"pageSize": 100}
        if cursor:
            query["pageToken"] = cursor
        page = await fetch_json("Google Meet", "GET", MEET + path + "/entries", headers=hdr, params=query)
        for row in page.get("transcriptEntries", []):
            speaker = row["participant"]
            if speaker not in names:
                names[speaker] = f"Speaker {len(names) + 1}"
            if row["text"].strip():
                total_bytes += len(row["text"].encode("utf-8"))
                if total_bytes > 2_000_000 or len(entries) >= 5000:
                    raise HTTPException(413, "The transcript exceeds the import limit. Import a local excerpt.")
                entries.append((instant(row["startTime"]), names[speaker], row["text"]))
        cursor = page.get("nextPageToken")
        if not cursor:
            break
    if cursor:
        raise HTTPException(413, "The transcript exceeds 5000 entries. Import a local excerpt.")
    if not entries:
        raise HTTPException(422, "The meeting has no transcript entries.")
    return {"segments": [{"speaker": speaker, "text": text} for _, speaker, text in sorted(entries, key=lambda e: e[0])]}
