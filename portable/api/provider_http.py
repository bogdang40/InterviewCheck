"""Bounded requests to configured providers. Never return bodies from failed calls."""
import os
import json
import httpx
from fastapi import HTTPException


def configured(key: str) -> bool:
    return bool(os.getenv(key, "").strip())


def setting(key: str) -> str:
    value = os.getenv(key, "").strip()
    if not value:
        raise HTTPException(503, f"Configure {key} on this workstation.")
    return value


async def fetch_json(provider: str, method: str, url: str, *, timeout=30, limit=4_000_000, **options):
    try:
        async with httpx.AsyncClient(timeout=timeout, follow_redirects=False) as client:
            async with client.stream(method, url, **options) as response:
                if not 200 <= response.status_code < 300:
                    status = response.status_code
                    code = status if status in {400, 401, 402, 403, 404, 409, 422, 429, 503} else 502
                    raise HTTPException(code, f"{provider} returned HTTP {status}.")
                if response.status_code == 204:
                    return {}
                data = bytearray()
                async for chunk in response.aiter_bytes():
                    if len(data) + len(chunk) > limit:
                        raise HTTPException(502, f"{provider} response exceeds the size limit.")
                    data.extend(chunk)
                return json.loads(data)
    except (ValueError, UnicodeError) as exc:
        raise HTTPException(502, f"{provider} returned invalid JSON.") from exc
    except httpx.TimeoutException as exc:
        raise HTTPException(504, f"{provider} request timed out.") from exc
    except httpx.HTTPError as exc:
        raise HTTPException(502, f"Could not reach {provider}.") from exc
