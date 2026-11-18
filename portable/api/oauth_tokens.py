"""Refresh delegated workspace tokens from operator credentials. Secrets stay in memory."""
import asyncio
import hashlib
import os
import re
import time

from fastapi import HTTPException

from .provider_http import configured, fetch_json, setting

GROUP = {"google": "GOOGLE", "meet": "GOOGLE", "microsoft": "MS_GRAPH", "teams": "MS_GRAPH"}
TOKEN = {"google": "GOOGLE_CALENDAR_ACCESS_TOKEN", "meet": "GOOGLE_MEET_ACCESS_TOKEN",
         "microsoft": "MS_GRAPH_ACCESS_TOKEN", "teams": "TEAMS_ACCESS_TOKEN"}
_cache = {}
_locks = {}


def refresh_configured(prefix):
    return all(configured(prefix + "_" + suffix) for suffix in ("CLIENT_ID", "REFRESH_TOKEN"))


def available(source):
    return configured(TOKEN[source]) or refresh_configured(GROUP[source])


async def bearer(source):
    prefix = GROUP[source]
    if not refresh_configured(prefix):
        return {"Authorization": "Bearer " + setting(TOKEN[source])}
    tenant = os.getenv("MS_GRAPH_TENANT", "common") if prefix == "MS_GRAPH" else ""
    if tenant and not re.fullmatch(r"[a-zA-Z0-9.-]{1,255}", tenant):
        raise HTTPException(503, "Configure a valid Microsoft tenant.")
    original = setting(prefix + "_REFRESH_TOKEN")
    client = setting(prefix + "_CLIENT_ID")
    secret = os.getenv(prefix + "_CLIENT_SECRET", "")
    # Changing account or client configuration invalidates any cached token.
    fingerprint = hashlib.sha256("\0".join((tenant, client, secret, original)).encode()).digest()
    lock = _locks.setdefault(prefix, asyncio.Lock())
    async with lock:
        cached = _cache.get(prefix)
        same_account = cached is not None and cached[0] == fingerprint
        if same_account and cached[1] > time.monotonic():
            return {"Authorization": "Bearer " + cached[2]}
        token = cached[3] if same_account else original
        payload = {"grant_type": "refresh_token", "client_id": client, "refresh_token": token}
        if secret:
            payload["client_secret"] = secret
        url = ("https://oauth2.googleapis.com/token" if prefix == "GOOGLE" else
               f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token")
        data = await fetch_json(prefix, "POST", url, data=payload)
        try:
            access = data["access_token"]
            renewed = data.get("refresh_token") or token
            lifetime = int(data.get("expires_in", 300))
            if not isinstance(access, str) or not access or not isinstance(renewed, str) or lifetime <= 0:
                raise ValueError
        except (TypeError, KeyError, ValueError) as exc:
            raise HTTPException(502, "The identity provider returned an invalid token response.") from exc
        _cache[prefix] = (fingerprint, time.monotonic() + max(0, lifetime - 60), access, renewed)
        return {"Authorization": "Bearer " + access}
