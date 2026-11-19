"""Resilient model chain execution with RPM quotas, retries, failover, and live telemetry."""
import asyncio
from collections.abc import Awaitable, Callable
import math
import sqlite3
import threading
import time
from typing import Any

from fastapi import HTTPException

from . import model_resolver, model_telemetry, provider_http, ssrf_guard, store
from .error_sanitizer import sanitize_error_text

FAILOVER_STATUSES = frozenset({429, 502, 503, 504})
_ORIG_RESOLVE_OR_503 = model_resolver.resolve_or_503
_ORIG_DISPATCH_COMPLETION = model_resolver.dispatch_completion


class ModelQuotaLimiter:
    def __init__(self, window_seconds: int = 60) -> None:
        self.window_seconds = window_seconds
        self._lock = threading.Lock()
        self._buckets: dict[str, tuple[int, float]] = {}

    def consume(self, model_id: str, rpm_limit: int) -> None:
        now = time.monotonic()
        with self._lock:
            count, start = self._buckets.get(model_id, (0, now))
            elapsed = now - start
            if elapsed >= self.window_seconds:
                self._buckets[model_id] = (1, now)
                return
            if count >= rpm_limit:
                retry_after = max(1, int(self.window_seconds - elapsed + 0.999))
                raise HTTPException(429, "Model request rate quota exceeded.", headers={"Retry-After": str(retry_after)})
            self._buckets[model_id] = (count + 1, start)

    def reset(self) -> None:
        with self._lock:
            self._buckets.clear()


QUOTA_LIMITER = ModelQuotaLimiter()


def reset_quotas() -> None:
    QUOTA_LIMITER.reset()


def resolve_candidates(
    capability: str,
    *,
    provider: str | None = None,
    allow_reference_fallback: bool = False,
    allow_slug_lookup: bool = True,
) -> list[model_resolver.ResolvedModel]:
    if model_resolver.resolve_or_503 is not _ORIG_RESOLVE_OR_503:
        return [
            model_resolver.resolve_or_503(
                capability,
                provider=provider,
                allow_reference_fallback=allow_reference_fallback,
                allow_slug_lookup=allow_slug_lookup,
            )
        ]
    chain = model_resolver.resolve_chain(
        capability,
        provider=provider,
        allow_reference_fallback=allow_reference_fallback,
        allow_slug_lookup=allow_slug_lookup,
    )
    if not chain:
        label = capability.replace("_", " ")
        raise HTTPException(503, f"Configure an enabled {label} model before running this action.")
    return chain


def _is_ssrf_error(exc: BaseException) -> bool:
    seen: set[int] = set()
    cur: BaseException | None = exc
    while cur is not None and id(cur) not in seen:
        seen.add(id(cur))
        if isinstance(cur, ssrf_guard.SSRFValidationError):
            return True
        cur = cur.__cause__ or cur.__context__
    return False


def _record_live(target: model_resolver.ResolvedModel, *, ok: bool, http_status: int | None, latency_ms: int | None, error: str | None) -> None:
    if target.id is None:
        return
    try:
        with store.connection(write=True) as db:
            model_telemetry.record_check(
                db, target.id, source="live", ok=ok, http_status=http_status,
                latency_ms=latency_ms, error=error, checked_at=store.timestamp(),
            )
    except sqlite3.Error:
        pass


async def _validate_target_endpoint(target: model_resolver.ResolvedModel, *, resolve_dns: bool) -> None:
    if target.provider in ("azure_openai", "openai_compatible"):
        ssrf_provider = target.provider
    elif target.provider == "deepgram" and target.endpoint:
        ssrf_provider = "openai_compatible"
    else:
        return
    try:
        ssrf_guard.validate_endpoint_url(target.endpoint or "", provider=ssrf_provider, resolve_dns=False)
        if resolve_dns:
            await ssrf_guard.validate_endpoint_url_async(target.endpoint or "", provider=ssrf_provider, resolve_dns=True)
    except ssrf_guard.SSRFValidationError as exc:
        detail = sanitize_error_text(str(exc), "Blocked unsafe provider endpoint.")
        _record_live(target, ok=False, http_status=400, latency_ms=0, error=detail)
        raise HTTPException(400, detail) from exc


def _clamped_retries(target: model_resolver.ResolvedModel) -> int:
    raw = target.config.get("max_retries", 0)
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        return 0
    return min(max(int(raw), 0), 3)


def _rpm_limit(target: model_resolver.ResolvedModel) -> int | None:
    raw = target.config.get("rpm_limit")
    if isinstance(raw, bool) or not isinstance(raw, int) or raw < 1:
        return None
    return raw


async def _run_chain(
    candidates: list[model_resolver.ResolvedModel],
    call_fn: Callable[[model_resolver.ResolvedModel], Awaitable[Any]],
    *,
    fetch_fn=None,
) -> tuple[model_resolver.ResolvedModel, Any]:
    real_transport = (fetch_fn is None or fetch_fn is provider_http.fetch_json) and (
        model_resolver.dispatch_completion is _ORIG_DISPATCH_COMPLETION
    )
    last_exc: HTTPException | None = None
    for target in candidates:
        retries = _clamped_retries(target)
        rpm_limit = _rpm_limit(target)
        for attempt in range(retries + 1):
            await _validate_target_endpoint(target, resolve_dns=real_transport)
            if target.id is not None and rpm_limit is not None:
                try:
                    QUOTA_LIMITER.consume(target.id, rpm_limit)
                except HTTPException as exc:
                    last_exc = exc
                    break
            started = time.monotonic()
            try:
                result = await call_fn(target)
            except ssrf_guard.SSRFValidationError as exc:
                elapsed = int((time.monotonic() - started) * 1000)
                detail = sanitize_error_text(str(exc), "Blocked unsafe provider endpoint.")
                _record_live(target, ok=False, http_status=400, latency_ms=elapsed, error=detail)
                raise HTTPException(400, detail) from exc
            except HTTPException as exc:
                elapsed = int((time.monotonic() - started) * 1000)
                detail = sanitize_error_text(str(exc.detail), "Provider call failed.")
                _record_live(target, ok=False, http_status=exc.status_code, latency_ms=elapsed, error=detail)
                if _is_ssrf_error(exc) or exc.status_code not in FAILOVER_STATUSES:
                    raise
                last_exc = exc
                if attempt < retries:
                    await asyncio.sleep(min(0.2 * (attempt + 1), 0.5))
                    continue
                break
            elapsed = int((time.monotonic() - started) * 1000)
            _record_live(target, ok=True, http_status=200, latency_ms=elapsed, error=None)
            return target, result
    assert last_exc is not None
    raise last_exc


async def execute_completion_chain(
    capability: str,
    instructions: str,
    prompt: str,
    *,
    provider: str | None = None,
    allow_reference_fallback: bool = False,
    fetch_fn=None,
    max_tokens: int | None = None,
) -> tuple[model_resolver.ResolvedModel, tuple[str, str]]:
    candidates = resolve_candidates(capability, provider=provider, allow_reference_fallback=allow_reference_fallback)

    async def _call(target: model_resolver.ResolvedModel) -> tuple[str, str]:
        return await model_resolver.dispatch_completion(target, instructions, prompt, fetch_fn=fetch_fn, max_tokens=max_tokens)

    return await _run_chain(candidates, _call, fetch_fn=fetch_fn)


async def execute_reference_chain(
    instructions: str,
    user_input: str,
    *,
    fetch_fn=None,
    default_max_tokens: int = 1200,
) -> tuple[model_resolver.ResolvedModel, tuple[str, str]]:
    candidates = resolve_candidates("reference")
    fetch = fetch_fn or provider_http.fetch_json
    extra_opts = {"ssrf_safe": True} if fetch is provider_http.fetch_json else {}

    async def _call(target: model_resolver.ResolvedModel) -> tuple[str, str]:
        limit_tokens = target.config.get("max_tokens") or default_max_tokens
        if target.provider != "openai":
            model_id, text = await model_resolver.dispatch_completion(target, instructions, user_input, fetch_fn=fetch, max_tokens=limit_tokens)
            return f"{target.display_name} {model_id}"[:180], text
        raw_timeout = target.config.get("timeout_s")
        timeout = min(max(float(raw_timeout), 1.0), 180.0) if (isinstance(raw_timeout, (int, float)) and not isinstance(raw_timeout, bool) and math.isfinite(raw_timeout)) else 75.0
        payload: dict[str, Any] = {"model": target.model_id, "store": False, "max_output_tokens": limit_tokens, "instructions": instructions, "input": user_input}
        if target.config.get("temperature") is not None:
            payload["temperature"] = target.config["temperature"]
        data = await fetch("OpenAI", "POST", "https://api.openai.com/v1/responses", timeout=timeout, headers={"Authorization": "Bearer " + target.api_key}, json=payload, **extra_opts)
        try:
            if data.get("status") != "completed":
                raise HTTPException(502, "OpenAI did not complete the reference answer.")
            text = "\n".join(part["text"] for item in data["output"] if item.get("type") == "message" for part in item["content"] if part.get("type") == "output_text").strip()
        except (KeyError, TypeError, AttributeError) as exc:
            raise HTTPException(502, "OpenAI returned an invalid reference.") from exc
        if not text:
            raise HTTPException(502, "OpenAI returned an empty reference.")
        return f"OpenAI {target.model_id}", text

    return await _run_chain(candidates, _call, fetch_fn=fetch)


async def execute_embedding_chain(
    texts: list[str],
    *,
    provider: str | None = None,
    request_builder: Callable[[model_resolver.ResolvedModel, list[str]], tuple[str, dict[str, str], dict[str, Any]]],
    fetch_fn=None,
) -> tuple[model_resolver.ResolvedModel, list[list[float]]]:
    candidates = resolve_candidates("embedding", provider=provider)
    fetch = fetch_fn or provider_http.fetch_json
    extra_opts = {"ssrf_safe": True} if fetch is provider_http.fetch_json else {}

    async def _call(target: model_resolver.ResolvedModel) -> list[list[float]]:
        url, headers, payload = request_builder(target, texts)
        timeout = min(max(float(target.config.get("timeout_s") or 30.0), 1.0), 180.0)
        data = await fetch(model_resolver.DISPLAY_PROVIDER.get(target.provider, target.display_name), "POST", url, headers=headers, json=payload, timeout=timeout, **extra_opts)
        try:
            items = sorted(data["data"], key=lambda item: int(item["index"]))
            vectors = [[float(v) for v in item["embedding"]] for item in items]
        except (KeyError, TypeError, ValueError) as exc:
            raise HTTPException(502, "Embedding provider returned an invalid response.") from exc
        if len(vectors) != len(texts):
            raise HTTPException(502, "Embedding provider returned an unexpected vector count.")
        return vectors

    return await _run_chain(candidates, _call, fetch_fn=fetch)


async def execute_transcription_chain(
    audio_bytes: bytes,
    content_type: str,
    *,
    url_builder: Callable[[str | None], tuple[str, str]],
    fetch_fn=None,
) -> tuple[model_resolver.ResolvedModel, list[dict[str, str]]]:
    candidates = resolve_candidates("transcription")
    fetch = fetch_fn or provider_http.fetch_json
    extra_opts = {"ssrf_safe": True} if fetch is provider_http.fetch_json else {}

    async def _call(target: model_resolver.ResolvedModel) -> list[dict[str, str]]:
        http_url, _ = url_builder(target.endpoint)
        model_id = target.model_id or "nova-2"
        raw_timeout = target.config.get("timeout_s")
        timeout = min(max(float(raw_timeout if raw_timeout is not None else 180.0), 10.0), 300.0)
        data = await fetch(
            "Deepgram", "POST", http_url,
            params={"model": model_id, "diarize": "true", "utterances": "true", "punctuate": "true"},
            headers={"Authorization": f"Token {target.api_key}", "Content-Type": content_type},
            content=audio_bytes, timeout=timeout, limit=12_000_000, **extra_opts,
        )
        try:
            results = data["results"]
            segments = [{"speaker": str(item.get("speaker", "Unknown")), "text": item["transcript"]} for item in results.get("utterances", []) if isinstance(item["transcript"], str) and item["transcript"].strip()]
            if not segments:
                text = results["channels"][0]["alternatives"][0]["transcript"]
                if isinstance(text, str) and text.strip():
                    segments.append({"speaker": "Unknown", "text": text})
        except (IndexError, AttributeError, KeyError, TypeError) as exc:
            raise HTTPException(502, "Deepgram returned an unreadable transcript.") from exc
        if not segments:
            raise HTTPException(422, "Deepgram found no speech in the recording.")
        return segments

    return await _run_chain(candidates, _call, fetch_fn=fetch)
