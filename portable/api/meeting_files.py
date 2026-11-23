"""Import recording files selected from vendor listings. No client-supplied download URLs."""
from collections import OrderedDict
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import time
from typing import Literal
from urllib.parse import quote, urljoin, urlsplit
from uuid import UUID, uuid4

import httpx
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from starlette.concurrency import run_in_threadpool

from . import meeting_artifacts, model_resolver, oauth_tokens, rate_limit
from .access import require_entitlement
from .audio import LIMIT, transcribe_bytes
from .booking_sources import KEYS
from .provider_http import fetch_json, setting

router = APIRouter(dependencies=[Depends(require_entitlement)])


@dataclass(frozen=True)
class File:
    provider: str
    kind: str
    location: str
    needs_detail: bool = False
    title: str = ""
    start: str = ""
    end: str = ""


# Handles keep temporary URLs and vendor identifiers out of the browser and logs.
handles: OrderedDict[UUID, tuple[float, File]] = OrderedDict()


def entry(file, title, start):
    handle = uuid4()
    while handles and (len(handles) >= 512 or next(iter(handles.values()))[0] < time.monotonic()):
        handles.popitem(last=False)
    handles[handle] = (time.monotonic() + 900, file)
    return {"id": str(handle), "title": title, "start": start, "kind": file.kind}


@router.post("/recordings/{provider}", dependencies=[Depends(rate_limit.limit(rate_limit.INTEGRATION_REMOTE))])
async def recordings(provider: Literal["zoom", "webex", "meet", "teams"]):
    end = datetime.now(timezone.utc)
    begin = end - timedelta(days=29)
    if provider in {"meet", "teams"}:
        try:
            rows, more = await meeting_artifacts.conferences(provider)
            items = [entry(File(provider, "meeting", row["location"], title=row["title"], start=row["start"], end=row["end"]),
                           row["title"], row["start"]) for row in rows]
        except (TypeError, ValueError, KeyError, AttributeError) as exc:
            raise HTTPException(502, "The provider returned an invalid meeting list.") from exc
        return {"items": items, "note": "Showing the first page." if more else ""}
    headers = {"Authorization": "Bearer " + setting(KEYS[provider])}
    items = []
    try:
        if provider == "zoom":
            data = await fetch_json("Zoom", "GET", "https://api.zoom.us/v2/users/me/recordings", headers=headers,
                                    params={"from": begin.date().isoformat(), "to": end.date().isoformat(), "page_size": 100})
            for row in data["meetings"]:
                for item in row.get("recording_files", []):
                    kind = {"TRANSCRIPT": "transcript", "M4A": "audio", "MP4": "video"}.get(item.get("file_type"))
                    if kind and item.get("download_url") and item.get("status") == "completed":
                        items.append(entry(File(provider, kind, item["download_url"]), row["topic"], row["start_time"]))
            more = data.get("next_page_token")
        else:
            params = {"from": begin.isoformat(), "to": end.isoformat(), "max": 100}
            base = "https://webexapis.com/v1/"
            transcripts = await fetch_json("Webex", "GET", base + "meetingTranscripts", headers=headers, params=params)
            media = await fetch_json("Webex", "GET", base + "recordings", headers=headers, params=params)
            for row in transcripts["items"]:
                if str(row.get("status", "available")).lower() == "available":
                    link = row.get("vttDownloadLink") or base + "meetingTranscripts/" + quote(row["id"], safe="") + "/download?format=vtt"
                    items.append(entry(File(provider, "transcript", link), row["meetingTopic"], row["startTime"]))
            for row in media["items"]:
                if row.get("status") != "deleted":
                    link = base + "recordings/" + quote(row["id"], safe="")
                    items.append(entry(File(provider, "recording", link, True), row["topic"],
                                       row.get("timeRecorded") or row["createTime"]))
            more = len(transcripts["items"]) == 100 or len(media["items"]) == 100
    except (TypeError, KeyError, AttributeError) as exc:
        raise HTTPException(502, f"{provider.title()} returned an invalid recording list.") from exc
    return {"items": sorted(items, key=lambda item: item["start"], reverse=True),
            "note": "Showing the first page from this provider." if more else ""}


def vendor_url(url: str, provider: str):
    try:
        parts = urlsplit(url)
        hosts = ("zoom.us", "zoom.com") if provider == "zoom" else ("webex.com", "webexapis.com", "webexcontent.com")
        if provider == "teams":
            hosts = ("graph.microsoft.com",)
        allowed = (parts.hostname and any(parts.hostname == host or parts.hostname.endswith("." + host) for host in hosts))
        if parts.scheme == "https" and allowed and not parts.username and not parts.password and parts.port in (None, 443):
            return url
    except (TypeError, ValueError):
        pass
    raise HTTPException(502, "The recording uses an unsupported download host. Import a local copy.")


async def download(file: File, limit: int) -> tuple[bytes, str]:
    url = vendor_url(file.location, file.provider)
    headers = (await oauth_tokens.bearer("teams") if file.provider == "teams" else
               {"Authorization": "Bearer " + setting(KEYS[file.provider])})
    mime = "audio/mp4" if file.kind == "audio" else "video/mp4"
    if file.needs_detail:
        data = await fetch_json("Webex", "GET", url, headers=headers)
        links = data.get("temporaryDirectDownloadLinks") or {}
        if not isinstance(links, dict):
            raise HTTPException(502, "Webex returned an invalid download link.")
        url = vendor_url(links.get("audioDownloadLink") or links.get("recordingDownloadLink") or "", file.provider)
        mime = "audio/mpeg" if links.get("audioDownloadLink") else "video/mp4"
        headers = {}
    try:
        async with httpx.AsyncClient(timeout=60, follow_redirects=False) as client:
            for _ in range(4):
                async with client.stream("GET", url, headers=headers) as response:
                    if response.is_redirect:
                        next_url = vendor_url(urljoin(url, response.headers.get("location", "")), file.provider)
                        if urlsplit(next_url).netloc != urlsplit(url).netloc:
                            headers = {}
                        url = next_url
                        continue
                    if response.status_code != 200:
                        raise HTTPException(502, f"Recording download returned HTTP {response.status_code}.")
                    result = bytearray()
                    async for block in response.aiter_bytes():
                        if len(result) + len(block) > limit:
                            raise HTTPException(413, "The recording exceeds the import limit. Select a shorter excerpt.")
                        result.extend(block)
                    if not result:
                        raise HTTPException(422, "The provider returned an empty file.")
                    return bytes(result), mime
    except httpx.HTTPError as exc:
        raise HTTPException(502, "The recording download failed.") from exc
    raise HTTPException(502, "Too many redirects while downloading the recording.")


class ImportSelection(BaseModel):
    send_to_deepgram: bool = False


@router.post("/recording/{handle}", dependencies=[Depends(rate_limit.limit(rate_limit.INTEGRATION_REMOTE))])
async def import_file(handle: UUID, body: ImportSelection):
    cached = handles.get(handle)
    if not cached or cached[0] < time.monotonic():
        raise HTTPException(410, "Refresh the recording list and select the file again.")
    file = cached[1]
    if file.kind == "meeting":
        try:
            paths, note = await meeting_artifacts.files(file.provider, file.location, file.start, file.end)
            return {"items": [entry(File(file.provider, kind, path), file.title, file.start) for kind, path in paths], "note": note}
        except (TypeError, ValueError, KeyError, IndexError, AttributeError) as exc:
            raise HTTPException(502, "The provider returned invalid file details.") from exc
    if file.provider == "meet":
        try:
            return await meeting_artifacts.meet_segments(file.location)
        except (TypeError, ValueError, KeyError, AttributeError) as exc:
            raise HTTPException(502, "Google Meet returned invalid transcript entries.") from exc
    if file.kind != "transcript":
        if not body.send_to_deepgram:
            raise HTTPException(400, "Confirm transfer of this recording to Deepgram.")
        await run_in_threadpool(model_resolver.resolve_or_503, "transcription")
    raw, mime = await download(file, 2_000_000 if file.kind == "transcript" else LIMIT)
    if file.kind != "transcript":
        return await transcribe_bytes(raw, mime)
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeError as exc:
        raise HTTPException(422, "The transcript encoding is unsupported.") from exc
    if not text.lstrip().startswith("WEBVTT"):
        raise HTTPException(422, "The provider did not return a WebVTT transcript.")
    return {"vtt": text}
