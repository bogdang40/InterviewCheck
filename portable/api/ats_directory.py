"""Read-only candidate directories. Only operator-configured vendor hosts receive credentials."""
import os
import re
from urllib.parse import quote

from fastapi import HTTPException

from .provider_http import fetch_json, setting

KEYS = {
    "workable": ("WORKABLE_API_KEY", "WORKABLE_SUBDOMAIN"), "teamtailor": ("TEAMTAILOR_API_KEY",),
    "smartrecruiters": ("SMARTRECRUITERS_API_KEY",), "bamboohr": ("BAMBOOHR_API_KEY", "BAMBOOHR_SUBDOMAIN"),
    "recruitee": ("RECRUITEE_API_KEY", "RECRUITEE_COMPANY_ID"), "personio": ("PERSONIO_CLIENT_ID", "PERSONIO_CLIENT_SECRET"),
    "jobadder": ("JOBADDER_ACCESS_TOKEN",), "kombo": ("KOMBO_API_KEY", "KOMBO_INTEGRATION_ID"),
    "unified": ("UNIFIED_API_KEY", "UNIFIED_CONNECTION_ID"),
}


def region_host(key, default, alternate):
    region = os.getenv(key, "").lower()
    return alternate.get(region, default)


def subdomain(key):
    value = setting(key).lower()
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", value):
        raise HTTPException(503, "Configure a valid tenant name for this ATS integration.")
    return value


def person(first, last, role=""):
    return {"candidate": " ".join(s for s in (first, last) if s), "role": role or ""}


async def lookup(provider, email):
    email = email.casefold()
    async def get(url, headers=None, auth=None, **params):
        return await fetch_json(provider.title(), "GET", url, headers=headers or {}, params=params, auth=auth)
    if provider == "workable":
        host = subdomain("WORKABLE_SUBDOMAIN") + ".workable.com"
        data = await get(f"https://{host}/spi/v3/candidates", {"Authorization": "Bearer " + setting("WORKABLE_API_KEY")},
                         email=email, limit=10)
        return [{"candidate": p["name"], "role": (p.get("job") or {}).get("title", ""), "target_id": str(p.get("id") or "")} for p in data["candidates"]
                if not p.get("email") or p["email"].casefold() == email]
    if provider == "teamtailor":
        host = region_host("TEAMTAILOR_REGION", "api.teamtailor.com", {"na": "api.na.teamtailor.com"})
        data = await get(f"https://{host}/v1/candidates",
                         {"Authorization": "Token token=" + setting("TEAMTAILOR_API_KEY"), "X-Api-Version": "20240904"},
                         **{"filter[email]": email, "page[size]": 10})
        records = [p["attributes"] for p in data["data"]]
        return [person(p.get("first-name"), p.get("last-name")) for p in records if p["email"].casefold() == email]
    if provider == "smartrecruiters":
        data = await get("https://api.smartrecruiters.com/candidates", {"X-SmartToken": setting("SMARTRECRUITERS_API_KEY")},
                         q=email, limit=10)
        return [person(p.get("firstName"), p.get("lastName"), ((p.get("primaryAssignment") or {}).get("job") or {}).get("title"))
                for p in data["content"] if (p.get("email") or "").casefold() == email]
    if provider == "bamboohr":
        host = subdomain("BAMBOOHR_SUBDOMAIN") + ".bamboohr.com"
        data = await get(f"https://{host}/api/v1/applicant_tracking/applications", {"Accept": "application/json"},
                         auth=(setting("BAMBOOHR_API_KEY"), "x"), searchString=email)
        return [person(a["applicant"].get("firstName"), a["applicant"].get("lastName"),
                       ((a.get("job") or {}).get("title") or {}).get("label"))
                for a in data["applications"] if (a["applicant"].get("email") or "").casefold() == email]
    if provider == "recruitee":
        company = quote(setting("RECRUITEE_COMPANY_ID"), safe="")
        data = await get(f"https://api.recruitee.com/c/{company}/candidates", {"Authorization": "Bearer " + setting("RECRUITEE_API_KEY")},
                         query=email, limit=10)
        return [{"candidate": p["name"], "role": "", "target_id": str(p.get("id") or "")} for p in data["candidates"]
                if any(address.casefold() == email for address in (p.get("emails") or []))]
    if provider == "jobadder":
        data = await get("https://api.jobadder.com/v2/candidates", {"Authorization": "Bearer " + setting("JOBADDER_ACCESS_TOKEN")},
                         Email=email, Limit=10)
        return [person(p.get("firstName"), p.get("lastName")) for p in data["items"] if (p.get("email") or "").casefold() == email]
    if provider == "personio":
        token = await fetch_json("Personio", "POST", "https://api.personio.de/v2/auth/token", data={
            "client_id": setting("PERSONIO_CLIENT_ID"), "client_secret": setting("PERSONIO_CLIENT_SECRET"),
            "scope": "personio:recruiting:read", "grant_type": "client_credentials"})
        data = await get("https://api.personio.de/v2/recruiting/applications", {"Authorization": "Bearer " + token["access_token"]},
                         **{"candidate.email": email})
        return [person(a["candidate"].get("first_name"), a["candidate"].get("last_name"), (a.get("job") or {}).get("name"))
                for a in data["_data"] if not a["candidate"].get("email") or a["candidate"]["email"].casefold() == email]
    if provider == "kombo":
        host = region_host("KOMBO_REGION", "api.kombo.dev", {"us": "api.us.kombo.dev", "ca": "api.ca.kombo.dev"})
        data = await get(f"https://{host}/v1/ats/candidates", {"Authorization": "Bearer " + setting("KOMBO_API_KEY"),
                         "X-Integration-Id": setting("KOMBO_INTEGRATION_ID")}, email=email, page_size=10)
        items = []
        for p in data["data"]["results"]:
            apps = p.get("applications") or []
            app = next((a for a in apps if a.get("outcome") == "PENDING"), apps[0] if apps else {})
            items.append(person(p.get("first_name"), p.get("last_name"), (app.get("job") or {}).get("name")))
        return items
    if provider == "unified":
        host = region_host("UNIFIED_REGION", "api.unified.to", {"eu": "api-eu.unified.to", "au": "api-au.unified.to"})
        connection = quote(setting("UNIFIED_CONNECTION_ID"), safe="")
        base = f"https://{host}/ats/{connection}/"
        headers = {"Authorization": "Bearer " + setting("UNIFIED_API_KEY")}
        data = await get(base + "candidate", headers, query=email, limit=10)
        results = []
        for p in data:
            if not any(address["email"].casefold() == email for address in (p.get("emails") or [])):
                continue
            role = ""
            if p.get("job_ids"):
                job = await get(base + "job/" + quote(str(p["job_ids"][0]), safe=""), headers)
                role = job.get("name", "")
            results.append({"candidate": p.get("name") or person(p.get("first_name"), p.get("last_name"))["candidate"], "role": role})
        return results
    raise HTTPException(404, "Unknown candidate directory.")
