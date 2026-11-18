"""Candidate lookup, using the same vendor endpoints as the native connectors."""
import csv
import io
from typing import Literal
from urllib.parse import quote

from fastapi import HTTPException

from . import ats_directory
from .provider_http import configured, fetch_json, setting

ATS = Literal["ashby", "lever", "merge", "greenhouse", "workable", "teamtailor", "smartrecruiters",
              "bamboohr", "recruitee", "personio", "jobadder", "kombo", "unified"]
KEYS = {**ats_directory.KEYS, "ashby": ("ASHBY_API_KEY",), "lever": ("LEVER_API_KEY",),
        "merge": ("MERGE_API_KEY", "MERGE_ACCOUNT_TOKEN"),
        "greenhouse": ("GREENHOUSE_CLIENT_ID", "GREENHOUSE_CLIENT_SECRET")}


def sources():
    return [provider for provider, keys in KEYS.items() if all(configured(key) for key in keys)]


async def lookup(provider: ATS, email: str, *, with_id=False):
    try:
        items = await _lookup(provider, email)
        if not with_id:
            for item in items:
                item.pop("target_id", None)
        return items
    except (TypeError, KeyError, AttributeError, IndexError) as exc:
        raise HTTPException(502, f"{provider.title()} returned an invalid candidate record.") from exc


async def _lookup(provider, email):
    if provider in ats_directory.KEYS:
        return await ats_directory.lookup(provider, email)
    if provider == "ashby":
        async def call(path, body):
            data = await fetch_json("Ashby", "POST", "https://api.ashbyhq.com/" + path,
                                    auth=(setting("ASHBY_API_KEY"), ""), json=body,
                                    headers={"Accept": "application/json; version=1"})
            if data.get("success") is not True:
                raise HTTPException(502, "Ashby refused the candidate lookup.")
            return data["results"]
        rows = await call("candidate.search", {"email": email})
        items = []
        for person in rows[:10]:
            jobs = person.get("applicationIds") or []
            role = ""
            if jobs:
                app = await call("application.info", {"applicationId": jobs[-1]})
                role = (app.get("job") or {}).get("title", "")
            items.append({"candidate": person["name"], "role": role, "target_id": str(person.get("id") or "")})
        return items
    if provider == "lever":
        origin = "https://api.lever.co/v1/"
        auth = (setting("LEVER_API_KEY"), "")
        response = await fetch_json("Lever", "GET", origin + "opportunities", auth=auth,
                                    params={"email": email, "limit": 10, "expand": "applications"})
        items = []
        for person in response["data"]:
            if email.casefold() not in {value.casefold() for value in person["emails"]}:
                continue
            apps = person.get("applications") or []
            role = ""
            if apps and isinstance(apps[0], dict) and apps[0].get("posting"):
                posting = await fetch_json("Lever", "GET", origin + "postings/" + quote(apps[0]["posting"], safe=""), auth=auth)
                role = posting["data"]["text"]
            items.append({"candidate": person["name"], "role": role, "target_id": str(person.get("id") or "")})
        return items
    if provider == "merge":
        headers = {"Authorization": "Bearer " + setting("MERGE_API_KEY"), "X-Account-Token": setting("MERGE_ACCOUNT_TOKEN")}
        data = await fetch_json("Merge", "GET", "https://api.merge.dev/api/ats/v1/candidates", headers=headers,
                                params={"email_addresses": email, "page_size": 10})
        items = []
        for person in data["results"]:
            if not any(row["value"].casefold() == email.casefold() for row in person["email_addresses"]):
                continue
            apps = await fetch_json("Merge", "GET", "https://api.merge.dev/api/ats/v1/applications", headers=headers,
                                    params={"candidate_id": person["id"], "expand": "job", "page_size": 1})
            name = " ".join(value for value in (person.get("first_name"), person.get("last_name")) if value)
            jobs = apps["results"]
            role = (jobs[0].get("job") or {}).get("name", "") if jobs else ""
            items.append({"candidate": name, "role": role, "target_id": str(person.get("id") or "")})
        return items

    token = await fetch_json("Greenhouse", "POST", "https://auth.greenhouse.io/token",
                             auth=(setting("GREENHOUSE_CLIENT_ID"), setting("GREENHOUSE_CLIENT_SECRET")),
                             data={"grant_type": "client_credentials"})
    headers = {"Authorization": "Bearer " + token["access_token"]}
    async def get(path, **params):
        return await fetch_json("Greenhouse", "GET", "https://harvest.greenhouse.io/v3/" + path,
                                headers=headers, params={**params, "per_page": 10})
    items = []
    for person in await get("candidates", email=email):
        jobs = await get("applications", candidate_ids=person["id"])
        job = next((row["job_id"] for row in jobs if row.get("job_id")), None)
        roles = await get("jobs", ids=job) if job else []
        name = " ".join(value for value in (person.get("first_name"), person.get("last_name")) if value)
        items.append({"candidate": name, "role": roles[0]["name"] if roles else "", "target_id": str(person.get("id") or "")})
    return items


def csv_rows(text: str):
    reader = csv.DictReader(io.StringIO(text.lstrip("\ufeff")), strict=True)
    try:
        if not reader.fieldnames or not {"candidate", "role"}.issubset(reader.fieldnames):
            raise HTTPException(422, "The CSV must have candidate and role column headers.")
        items = []
        for row in reader:
            candidate = (row.get("candidate") or "").strip()
            role = (row.get("role") or "").strip()
            if None in row or len(candidate) > 160 or len(role) > 180 or not candidate or not role:
                raise HTTPException(422, f"Check the candidate and role on CSV line {reader.line_num}.")
            items.append({"candidate": candidate, "role": role})
            if len(items) > 200:
                raise HTTPException(422, "Import at most 200 candidate rows per file.")
    except csv.Error as error:
        raise HTTPException(422, f"Invalid CSV near line {reader.line_num}.") from error
    return items
