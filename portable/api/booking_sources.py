"""Read one bounded schedule window from booking and meeting tools."""
from datetime import datetime, timedelta, timezone
from uuid import UUID

from fastapi import HTTPException

from .provider_http import fetch_json, setting

KEYS = {"zoom": "ZOOM_ACCESS_TOKEN", "webex": "WEBEX_ACCESS_TOKEN", "calendly": "CALENDLY_ACCESS_TOKEN",
        "calcom": "CALCOM_API_KEY"}


async def bookings(provider: str):
    begin = datetime.now(timezone.utc)
    end = begin + timedelta(days=30)
    headers = {"Authorization": "Bearer " + setting(KEYS[provider])}
    try:
        if provider == "calendly":
            base = "https://api.calendly.com/"
            me = await fetch_json("Calendly", "GET", base + "users/me", headers=headers)
            data = await fetch_json("Calendly", "GET", base + "scheduled_events", headers=headers, params={
                "user": me["resource"]["uri"], "status": "active", "min_start_time": begin.isoformat(),
                "max_start_time": end.isoformat(), "sort": "start_time:asc", "count": 100})
            rows = [{"title": row["name"], "start": row["start_time"], "candidate": "", "role": "",
                     "booking_id": str(UUID(row["uri"].rstrip("/").rsplit("/", 1)[-1]))}
                    for row in data["collection"]]
            more = data.get("pagination", {}).get("next_page")
        elif provider == "calcom":
            headers["cal-api-version"] = "2026-05-01"
            data = await fetch_json("Cal.com", "GET", "https://api.cal.com/v2/bookings", headers=headers, params={
                "status": "upcoming", "afterStart": begin.isoformat(), "beforeEnd": end.isoformat(),
                "sortStart": "asc", "limit": 100})
            rows = [{"title": row["title"], "start": row["start"], "candidate": single_name(row.get("attendees", [])), "role": ""}
                    for row in data["data"] if row.get("status") in ("accepted", "awaiting_host")]
            more = data.get("pagination", {}).get("hasMore")
        elif provider == "zoom":
            data = await fetch_json("Zoom", "GET", "https://api.zoom.us/v2/users/me/meetings", headers=headers,
                                    params={"type": "upcoming", "page_size": 100})
            rows = [{"title": row["topic"], "start": row["start_time"], "candidate": "", "role": ""}
                    for row in data["meetings"] if row.get("start_time") and
                    begin <= datetime.fromisoformat(row["start_time"]) <= end]
            more = data.get("next_page_token")
        else:
            data = await fetch_json("Webex", "GET", "https://webexapis.com/v1/meetings", headers=headers,
                                    params={"meetingType": "scheduledMeeting", "from": begin.isoformat(),
                                            "to": end.isoformat(), "max": 100})
            rows = [{"title": row["title"], "start": row["start"], "candidate": "", "role": ""}
                    for row in data["items"] if row.get("state") not in ("cancelled", "canceled")]
            more = len(data["items"]) == 100
    except (KeyError, TypeError, ValueError, AttributeError) as exc:
        raise HTTPException(502, f"{provider.title()} returned an invalid schedule.") from exc
    return {"items": rows, "note": "The schedule reached its 100 event page limit." if more else ""}


def single_name(attendees):
    return attendees[0].get("name", "") if len(attendees) == 1 else ""


async def calendly_candidate(booking_id: UUID):
    data = await fetch_json("Calendly", "GET", f"https://api.calendly.com/scheduled_events/{booking_id}/invitees",
                            headers={"Authorization": "Bearer " + setting("CALENDLY_ACCESS_TOKEN")},
                            params={"status": "active", "count": 2})
    try:
        return {"candidate": single_name(data["collection"])}
    except (KeyError, TypeError, AttributeError) as exc:
        raise HTTPException(502, "Calendly returned an invalid invitee.") from exc
