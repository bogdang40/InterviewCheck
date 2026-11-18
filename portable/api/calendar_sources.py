"""Prepare interviews from calendar files and read-only cloud calendar accounts."""
from datetime import date, datetime, timedelta, timezone

from fastapi import HTTPException
from icalendar import Calendar

from . import oauth_tokens
from .provider_http import fetch_json


def calendar_file(text: str):
    try:
        calendar = Calendar.from_ical(text)
        if not isinstance(calendar, Calendar):
            raise ValueError("Missing calendar")
        events = {}
        recurring = False
        for event in calendar.walk("VEVENT"):
            uid = str(event.get("uid", "")).strip()
            if not uid:
                continue
            key = (uid, str(event.get("recurrence-id", "")))
            version = (int(event.get("sequence", 0)), str(event.get("dtstamp", "").to_ical() if event.get("dtstamp") else ""))
            if key not in events or version >= events[key][0]:
                events[key] = (version, event)
        items = []
        for _, event in events.values():
            if str(event.get("status", "")).upper() == "CANCELLED" or str(calendar.get("method", "")).upper() == "CANCEL":
                continue
            if event.get("rrule") or event.get("rdate") or event.get("exdate"):
                recurring = True
                continue
            start = getattr(event.get("dtstart"), "dt", None)
            if isinstance(start, date):
                items.append({"title": str(event.get("summary", "Interview")), "start": start.isoformat(),
                              "candidate": str(event.get("X-INTERVIEWCHECK-CANDIDATE", "")),
                              "role": str(event.get("X-INTERVIEWCHECK-ROLE", ""))})
    except (ValueError, TypeError, KeyError, OverflowError) as error:
        raise HTTPException(422, "The file must contain a valid iCalendar calendar.") from error
    items.sort(key=lambda row: row["start"])
    warnings = []
    if len(items) > 200:
        warnings.append("Showing the first 200 events.")
    if recurring:
        warnings.append("Recurring series were omitted. Export individual occurrences to prepare them.")
    return {"items": items[:200], "note": " ".join(warnings)}


async def cloud_calendar(provider: str):
    begin = datetime.now(timezone.utc)
    end = begin + timedelta(days=30)
    if provider == "google":
        url = "https://www.googleapis.com/calendar/v3/calendars/primary/events"
        headers = await oauth_tokens.bearer("google")
        params = {"timeMin": begin.isoformat(), "timeMax": end.isoformat(), "singleEvents": "true",
                  "orderBy": "startTime", "maxResults": 100}
        data = await fetch_json("Google Calendar", "GET", url, headers=headers, params=params)
        try:
            rows = [{"title": row.get("summary", "Interview"), "start": row["start"].get("dateTime") or row["start"]["date"],
                     "candidate": "", "role": ""} for row in data["items"] if row.get("status") != "cancelled"]
            more = data.get("nextPageToken")
        except (TypeError, KeyError, AttributeError) as exc:
            raise HTTPException(502, "Google Calendar returned an invalid event.") from exc
    else:
        url = "https://graph.microsoft.com/v1.0/me/calendarView"
        headers = {**await oauth_tokens.bearer("microsoft"), "Prefer": 'outlook.timezone="UTC"'}
        data = await fetch_json("Microsoft 365", "GET", url, headers=headers, params={
            "startDateTime": begin.isoformat(), "endDateTime": end.isoformat(), "$top": 100,
            "$select": "subject,start,isCancelled", "$orderby": "start/dateTime"})
        try:
            rows = [{"title": row.get("subject", "Interview"), "start": row["start"]["dateTime"].rstrip("Z") + "Z",
                     "candidate": "", "role": ""} for row in data["value"] if not row.get("isCancelled")]
            more = data.get("@odata.nextLink")
        except (TypeError, KeyError, AttributeError) as exc:
            raise HTTPException(502, "Microsoft 365 returned an invalid event.") from exc
    return {"items": rows, "note": "Showing the first 100 events." if more else ""}
