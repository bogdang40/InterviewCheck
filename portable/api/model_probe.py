"""Live non-redirecting provider verification for connected models."""
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import math
import re
import time
from typing import Any, Literal
from urllib.parse import quote

import httpx

from . import ssrf_guard
from .error_sanitizer import sanitize_error_text

MODEL_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,179}$")
MAX_PROBE_RESPONSE_BYTES = 1_048_576


class _ProbeResponseTooLarge(Exception):
    def __init__(self, status_code: int) -> None:
        super().__init__("Provider probe response exceeded the size limit.")
        self.status_code = status_code


@dataclass(frozen=True)
class ProbeOutcome:
    ok: bool
    status: Literal["connected", "error"]
    http_status: int | None
    latency_ms: int | None
    last_error: str | None
    checked_at: str
    ssrf_blocked: bool = False
    timed_out: bool = False


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _classify_http_status(status: int) -> str:
    if 300 <= status < 400:
        return f"Provider redirected the request (HTTP {status}). Redirects are blocked."
    if status == 401:
        return "Authentication failed (HTTP 401). Check the API key."
    if status == 403:
        return "Access denied by provider (HTTP 403). Check key permissions."
    if status == 404:
        return "Model, deployment, or endpoint was not found (HTTP 404)."
    if status == 429:
        return "Provider rate limit or quota exceeded (HTTP 429)."
    if status in (400, 422):
        return f"Provider rejected the probe payload (HTTP {status})."
    return f"Provider service error (HTTP {status})."


def _openai_compatible_base(endpoint: str) -> str:
    base = endpoint.rstrip("/")
    for suffix in ("/chat/completions", "/embeddings"):
        if base.endswith(suffix):
            base = base[:-len(suffix)]
            break
    return base


def _extract_parameters(model: dict[str, Any] | Any) -> dict[str, Any]:
    if isinstance(model, dict):
        if isinstance(model.get("parameters"), dict):
            return model["parameters"]
        if "config_json" in model:
            from . import model_registry
            return model_registry.parse_parameters(model["config_json"])
        return {}
    if hasattr(model, "keys"):
        keys = model.keys()
        if "parameters" in keys and isinstance(model["parameters"], dict):
            return model["parameters"]
        if "config_json" in keys:
            from . import model_registry
            return model_registry.parse_parameters(model["config_json"])
    return {}


async def _probe_request(
    client: httpx.AsyncClient, method: str, url: str, **kwargs: Any
) -> tuple[int, bytes | None]:
    async with client.stream(method, url, **kwargs) as response:
        if not 200 <= response.status_code < 300:
            return response.status_code, None
        content_length = response.headers.get("content-length")
        if content_length is not None:
            try:
                if int(content_length) > MAX_PROBE_RESPONSE_BYTES:
                    raise _ProbeResponseTooLarge(response.status_code)
            except ValueError:
                pass
        data = bytearray()
        async for chunk in response.aiter_bytes():
            if len(data) + len(chunk) > MAX_PROBE_RESPONSE_BYTES:
                raise _ProbeResponseTooLarge(response.status_code)
            data.extend(chunk)
        return response.status_code, bytes(data)


async def _run_provider_probe(
    client: httpx.AsyncClient,
    *,
    provider: str,
    capability: str,
    model_id: str,
    endpoint: str | None,
    api_version: str | None,
    api_key: str,
) -> tuple[int, bytes | None]:
    if provider == "openai":
        url = f"https://api.openai.com/v1/models/{quote(model_id, safe='')}"
        return await _probe_request(client, "GET", url, headers={"Authorization": f"Bearer {api_key}"})
    if provider == "anthropic":
        url = f"https://api.anthropic.com/v1/models/{quote(model_id, safe='')}"
        return await _probe_request(client, "GET", url, headers={"x-api-key": api_key, "anthropic-version": "2023-06-01"})
    if provider == "azure_openai":
        headers = {"api-key": api_key}
        ver = quote(api_version or "", safe="")
        dep = quote(model_id, safe="")
        if capability == "embedding":
            url = f"{endpoint}/openai/deployments/{dep}/embeddings?api-version={ver}"
            return await _probe_request(client, "POST", url, headers=headers, json={"input": "probe"})
        url = f"{endpoint}/openai/deployments/{dep}/chat/completions?api-version={ver}"
        return await _probe_request(
            client,
            "POST",
            url,
            headers=headers,
            json={"messages": [{"role": "user", "content": "ok"}], "max_completion_tokens": 1},
        )
    if provider == "deepgram":
        return await _probe_request(
            client, "GET", "https://api.deepgram.com/v1/projects", headers={"Authorization": f"Token {api_key}"}
        )

    base = _openai_compatible_base(endpoint or "")
    v1_base = base if base.endswith("/v1") else f"{base}/v1"
    headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
    status_code, raw_body = await _probe_request(client, "GET", f"{v1_base}/models", headers=headers)
    if status_code in (404, 405):
        if capability == "embedding":
            return await _probe_request(
                client, "POST", f"{v1_base}/embeddings", headers=headers, json={"model": model_id, "input": "ok"}
            )
        return await _probe_request(
            client,
            "POST",
            f"{v1_base}/chat/completions",
            headers=headers,
            json={"model": model_id, "messages": [{"role": "user", "content": "ok"}], "max_tokens": 1},
        )
    return status_code, raw_body


async def probe_model(model: dict[str, Any] | Any, *, api_key: str) -> ProbeOutcome:
    checked_at = _now_iso()
    provider = model["provider"]
    capability = model["capability"]
    model_id = model["model_id"]
    endpoint = model["endpoint"]
    api_version = model["api_version"]
    config = _extract_parameters(model)

    if provider != "openai_compatible" and not api_key:
        return ProbeOutcome(
            ok=False, status="error", http_status=None, latency_ms=None,
            last_error="No API key is configured for this model.", checked_at=checked_at,
        )
    if not MODEL_ID_RE.fullmatch(model_id or ""):
        return ProbeOutcome(
            ok=False, status="error", http_status=None, latency_ms=None,
            last_error="Model identifier is invalid.", checked_at=checked_at,
        )
    if provider in ("azure_openai", "openai_compatible"):
        try:
            endpoint = await ssrf_guard.validate_endpoint_url_async(endpoint or "", provider=provider)
        except ssrf_guard.SSRFValidationError as exc:
            return ProbeOutcome(
                ok=False, status="error", http_status=None, latency_ms=None,
                last_error=sanitize_error_text(str(exc), "Endpoint URL is invalid."), checked_at=checked_at, ssrf_blocked=True,
            )

    raw_timeout = config.get("timeout_s") if isinstance(config, dict) else None
    if isinstance(raw_timeout, (int, float)) and not isinstance(raw_timeout, bool) and math.isfinite(raw_timeout):
        timeout_s = min(max(float(raw_timeout), 2.0), 15.0)
    else:
        timeout_s = 10.0
    started = time.monotonic()
    try:
        async with httpx.AsyncClient(
            timeout=timeout_s,
            follow_redirects=False,
            trust_env=False,
            transport=ssrf_guard.SafeAsyncTransport(),
        ) as client:
            status_code, raw_body = await _run_provider_probe(
                client,
                provider=provider,
                capability=capability,
                model_id=model_id,
                endpoint=endpoint,
                api_version=api_version,
                api_key=api_key,
            )
    except _ProbeResponseTooLarge as exc:
        elapsed = int((time.monotonic() - started) * 1000)
        return ProbeOutcome(
            ok=False, status="error", http_status=exc.status_code, latency_ms=elapsed,
            last_error="Provider probe response exceeded the size limit.", checked_at=checked_at,
        )
    except ssrf_guard.SSRFValidationError as exc:
        elapsed = int((time.monotonic() - started) * 1000)
        return ProbeOutcome(
            ok=False, status="error", http_status=None, latency_ms=elapsed,
            last_error=sanitize_error_text(str(exc), "Endpoint resolved to a blocked address."), checked_at=checked_at, ssrf_blocked=True,
        )
    except httpx.TimeoutException:
        elapsed = int((time.monotonic() - started) * 1000)
        return ProbeOutcome(
            ok=False, status="error", http_status=None, latency_ms=elapsed,
            last_error="Provider connection timed out.", checked_at=checked_at, timed_out=True,
        )
    except (httpx.HTTPError, OSError):
        elapsed = int((time.monotonic() - started) * 1000)
        return ProbeOutcome(
            ok=False, status="error", http_status=None, latency_ms=elapsed,
            last_error="Could not reach provider endpoint.", checked_at=checked_at,
        )

    elapsed = int((time.monotonic() - started) * 1000)
    if 200 <= status_code < 300:
        try:
            payload = json.loads(raw_body or b"")
        except (ValueError, UnicodeError):
            return ProbeOutcome(
                ok=False, status="error", http_status=status_code, latency_ms=elapsed,
                last_error="Provider returned invalid probe JSON.", checked_at=checked_at,
            )
        if not isinstance(payload, dict):
            return ProbeOutcome(
                ok=False, status="error", http_status=status_code, latency_ms=elapsed,
                last_error="Provider returned an unexpected probe payload.", checked_at=checked_at,
            )
        return ProbeOutcome(
            ok=True, status="connected", http_status=status_code,
            latency_ms=elapsed, last_error=None, checked_at=checked_at,
        )
    return ProbeOutcome(
        ok=False, status="error", http_status=status_code, latency_ms=elapsed,
        last_error=_classify_http_status(status_code), checked_at=checked_at,
    )
