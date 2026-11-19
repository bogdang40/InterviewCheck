"""Resilient model chain execution with RPM quotas, retries, failover, and live telemetry."""
import asyncio
from collections.abc import Awaitable, Callable
import sqlite3
import time
from typing import Any

from fastapi import HTTPException

from . import model_budgets, model_circuit, model_resolver, model_telemetry, provider_http, ssrf_guard, store
from .error_sanitizer import sanitize_error_text
from .model_execution_policy import (
    ModelQuotaLimiter,
    QUOTA_LIMITER,
    _clamped_retries,
    _is_ssrf_error,
    _rpm_limit,
    _safe_finite_float,
    _safe_timeout,
    reset_quotas,
)

FAILOVER_STATUSES = frozenset({429, 502, 503, 504})
_ORIG_RESOLVE_OR_503 = model_resolver.resolve_or_503
_ORIG_DISPATCH_COMPLETION = model_resolver.dispatch_completion


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


def _redact_target_secrets(text: str | None, target: model_resolver.ResolvedModel | None) -> str | None:
    if not text or target is None:
        return text
    cleaned = str(text)
    for attr in ("api_key", "signing_secret"):
        secret = getattr(target, attr, None)
        if isinstance(secret, str) and len(secret) >= 4 and secret in cleaned:
            cleaned = cleaned.replace(secret, "[REDACTED]")
    return cleaned


def _sanitize_target_error(
    text: str | None, fallback: str, target: model_resolver.ResolvedModel | None, *, max_len: int = 400
) -> str:
    return sanitize_error_text(_redact_target_secrets(text, target), fallback, max_len=max_len)


def _record_outcome(
    target: model_resolver.ResolvedModel,
    *,
    ok: bool,
    http_status: int | None,
    latency_ms: int | None,
    error: str | None,
    input_tokens: int = 0,
    output_tokens: int = 0,
) -> None:
    if target.id is None:
        return
    safe_error = _redact_target_secrets(error, target) if (not ok and error) else error
    try:
        with store.connection(write=True) as db:
            model_telemetry.record_check(
                db, target.id, source="live", ok=ok, http_status=http_status,
                latency_ms=latency_ms, error=safe_error, checked_at=store.timestamp(),
            )
            model_budgets.record_usage(
                db, target.id, input_tokens=input_tokens, output_tokens=output_tokens,
                ok=ok, config=target.config,
            )
            model_circuit.record_outcome(db, target.id, ok=ok, error=safe_error, secret=target.api_key)
    except (sqlite3.Error, OverflowError, ValueError):
        pass


def _check_target_budget(target: model_resolver.ResolvedModel) -> model_budgets.BudgetDecision | None:
    if target.id is None:
        return None
    try:
        with store.connection() as db:
            return model_budgets.check_budget(db, target.id, target.config)
    except sqlite3.Error:
        return None


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
        detail = _sanitize_target_error(str(exc), "Blocked unsafe provider endpoint.", target)
        _record_outcome(target, ok=False, http_status=400, latency_ms=0, error=detail)
        raise HTTPException(400, detail) from exc


async def _run_chain(
    candidates: list[model_resolver.ResolvedModel],
    call_fn: Callable[[model_resolver.ResolvedModel, Callable[[int, int], None]], Awaitable[Any]],
    *,
    fetch_fn=None,
    on_usage: Callable[[int, int], None] | None = None,
) -> tuple[model_resolver.ResolvedModel, Any]:
    real_transport = (fetch_fn is None or fetch_fn is provider_http.fetch_json) and (
        model_resolver.dispatch_completion is _ORIG_DISPATCH_COMPLETION
    )
    last_exc: HTTPException | None = None
    budget_blocked = False
    circuit_retry_after: int | None = None
    for target in candidates:
        decision = _check_target_budget(target)
        if decision is not None and not decision.allowed:
            budget_blocked = True
            continue
        c_decision = model_circuit.check_target(target.id)
        if c_decision is not None and not c_decision.allowed:
            wait_s = max(1, int(c_decision.retry_after_s or 1))
            circuit_retry_after = wait_s if circuit_retry_after is None else min(circuit_retry_after, wait_s)
            continue
        retries = _clamped_retries(target)
        rpm_limit = _rpm_limit(target)
        for attempt in range(retries + 1):
            if attempt > 0:
                retry_circuit = model_circuit.check_target(target.id)
                if retry_circuit is not None and not retry_circuit.allowed:
                    wait_s = max(1, int(retry_circuit.retry_after_s or 1))
                    circuit_retry_after = wait_s if circuit_retry_after is None else min(circuit_retry_after, wait_s)
                    break
            await _validate_target_endpoint(target, resolve_dns=real_transport)
            if target.id is not None and rpm_limit is not None:
                try:
                    QUOTA_LIMITER.consume(target.id, rpm_limit)
                except HTTPException as exc:
                    last_exc = exc
                    break
            usage_holder = [0, 0]

            def _record_tokens(in_tok: int, out_tok: int) -> None:
                usage_holder[0] = model_budgets.clamp_tokens(in_tok)
                usage_holder[1] = model_budgets.clamp_tokens(out_tok)
                if on_usage is not None:
                    on_usage(usage_holder[0], usage_holder[1])

            started = time.monotonic()
            try:
                result = await call_fn(target, _record_tokens)
            except ssrf_guard.SSRFValidationError as exc:
                elapsed = int((time.monotonic() - started) * 1000)
                detail = _sanitize_target_error(str(exc), "Blocked unsafe provider endpoint.", target)
                _record_outcome(
                    target, ok=False, http_status=400, latency_ms=elapsed, error=detail,
                    input_tokens=usage_holder[0], output_tokens=usage_holder[1],
                )
                raise HTTPException(400, detail) from exc
            except HTTPException as exc:
                elapsed = int((time.monotonic() - started) * 1000)
                detail = _sanitize_target_error(str(exc.detail), "Provider call failed.", target)
                _record_outcome(
                    target, ok=False, http_status=exc.status_code, latency_ms=elapsed, error=detail,
                    input_tokens=usage_holder[0], output_tokens=usage_holder[1],
                )
                safe_exc = HTTPException(exc.status_code, detail, headers=getattr(exc, "headers", None))
                if _is_ssrf_error(exc) or exc.status_code not in FAILOVER_STATUSES:
                    raise safe_exc from exc
                last_exc = safe_exc
                if attempt < retries:
                    await asyncio.sleep(min(0.2 * (attempt + 1), 0.5))
                    continue
                break
            elapsed = int((time.monotonic() - started) * 1000)
            _record_outcome(
                target, ok=True, http_status=200, latency_ms=elapsed, error=None,
                input_tokens=usage_holder[0], output_tokens=usage_holder[1],
            )
            return target, result
    if budget_blocked:
        raise HTTPException(429, "Model budget ceiling reached.")
    if last_exc is not None:
        raise last_exc
    if circuit_retry_after is not None:
        raise HTTPException(
            503,
            "All configured models are temporarily circuit-open.",
            headers={"Retry-After": str(circuit_retry_after)},
        )
    raise HTTPException(503, "No configured model could complete the request.")


def _dispatch_kwargs(record_tokens: Callable[[int, int], None]) -> dict[str, Any]:
    if model_resolver.dispatch_completion is _ORIG_DISPATCH_COMPLETION:
        return {"on_usage": record_tokens}
    return {}


async def execute_completion_chain(
    capability: str,
    instructions: str,
    prompt: str,
    *,
    provider: str | None = None,
    allow_reference_fallback: bool = False,
    fetch_fn=None,
    max_tokens: int | None = None,
    on_usage: Callable[[int, int], None] | None = None,
) -> tuple[model_resolver.ResolvedModel, tuple[str, str]]:
    candidates = resolve_candidates(capability, provider=provider, allow_reference_fallback=allow_reference_fallback)

    async def _call(target: model_resolver.ResolvedModel, record_tokens: Callable[[int, int], None]) -> tuple[str, str]:
        return await model_resolver.dispatch_completion(
            target, instructions, prompt, fetch_fn=fetch_fn, max_tokens=max_tokens, **_dispatch_kwargs(record_tokens)
        )

    return await _run_chain(candidates, _call, fetch_fn=fetch_fn, on_usage=on_usage)


async def execute_reference_chain(
    instructions: str,
    user_input: str,
    *,
    fetch_fn=None,
    default_max_tokens: int = 1200,
    on_usage: Callable[[int, int], None] | None = None,
) -> tuple[model_resolver.ResolvedModel, tuple[str, str]]:
    candidates = resolve_candidates("reference")
    fetch = fetch_fn or provider_http.fetch_json
    extra_opts = {"ssrf_safe": True} if fetch is provider_http.fetch_json else {}

    async def _call(target: model_resolver.ResolvedModel, record_tokens: Callable[[int, int], None]) -> tuple[str, str]:
        limit_tokens = target.config.get("max_tokens") or default_max_tokens
        if target.provider != "openai":
            model_id, text = await model_resolver.dispatch_completion(
                target, instructions, user_input, fetch_fn=fetch, max_tokens=limit_tokens, **_dispatch_kwargs(record_tokens)
            )
            return f"{target.display_name} {model_id}"[:180], text
        timeout = _safe_timeout(target.config.get("timeout_s"), default=75.0, low=1.0, high=180.0)
        payload: dict[str, Any] = {"model": target.model_id, "store": False, "max_output_tokens": limit_tokens, "instructions": instructions, "input": user_input}
        if target.config.get("temperature") is not None:
            payload["temperature"] = target.config["temperature"]
        data = await fetch("OpenAI", "POST", "https://api.openai.com/v1/responses", timeout=timeout, headers={"Authorization": "Bearer " + target.api_key}, json=payload, **extra_opts)
        record_tokens(*model_budgets.extract_usage(target.provider, data))
        try:
            if data.get("status") != "completed":
                raise HTTPException(502, "OpenAI did not complete the reference answer.")
            text = "\n".join(part["text"] for item in data["output"] if item.get("type") == "message" for part in item["content"] if part.get("type") == "output_text").strip()
        except (KeyError, TypeError, AttributeError) as exc:
            raise HTTPException(502, "OpenAI returned an invalid reference.") from exc
        if not text:
            raise HTTPException(502, "OpenAI returned an empty reference.")
        return f"OpenAI {target.model_id}", text

    return await _run_chain(candidates, _call, fetch_fn=fetch, on_usage=on_usage)


def _parse_embedding_vector(raw: Any) -> list[float]:
    if not isinstance(raw, list):
        raise ValueError("embedding must be a list")
    vec: list[float] = []
    for coord in raw:
        fval = _safe_finite_float(coord)
        if fval is None:
            raise ValueError("embedding coordinate must be a finite number")
        vec.append(fval)
    return vec


async def execute_embedding_chain(
    texts: list[str],
    *,
    provider: str | None = None,
    request_builder: Callable[[model_resolver.ResolvedModel, list[str]], tuple[str, dict[str, str], dict[str, Any]]],
    fetch_fn=None,
    on_usage: Callable[[int, int], None] | None = None,
) -> tuple[model_resolver.ResolvedModel, list[list[float]]]:
    candidates = resolve_candidates("embedding", provider=provider)
    fetch = fetch_fn or provider_http.fetch_json
    extra_opts = {"ssrf_safe": True} if fetch is provider_http.fetch_json else {}

    async def _call(target: model_resolver.ResolvedModel, record_tokens: Callable[[int, int], None]) -> list[list[float]]:
        url, headers, payload = request_builder(target, texts)
        timeout = _safe_timeout(target.config.get("timeout_s"), default=30.0, low=1.0, high=180.0)
        data = await fetch(model_resolver.DISPLAY_PROVIDER.get(target.provider, target.display_name), "POST", url, headers=headers, json=payload, timeout=timeout, **extra_opts)
        record_tokens(*model_budgets.extract_usage(target.provider, data))
        try:
            items = sorted(data["data"], key=lambda item: int(item["index"]))
            vectors = [_parse_embedding_vector(item["embedding"]) for item in items]
        except (KeyError, TypeError, ValueError, OverflowError) as exc:
            raise HTTPException(502, "Embedding provider returned an invalid response.") from exc
        if len(vectors) != len(texts):
            raise HTTPException(502, "Embedding provider returned an unexpected vector count.")
        return vectors

    return await _run_chain(candidates, _call, fetch_fn=fetch, on_usage=on_usage)


async def execute_transcription_chain(
    audio_bytes: bytes,
    content_type: str,
    *,
    url_builder: Callable[[str | None], tuple[str, str]],
    fetch_fn=None,
    on_usage: Callable[[int, int], None] | None = None,
) -> tuple[model_resolver.ResolvedModel, list[dict[str, str]]]:
    candidates = resolve_candidates("transcription")
    fetch = fetch_fn or provider_http.fetch_json
    extra_opts = {"ssrf_safe": True} if fetch is provider_http.fetch_json else {}

    async def _call(target: model_resolver.ResolvedModel, record_tokens: Callable[[int, int], None]) -> list[dict[str, str]]:
        http_url, _ = url_builder(target.endpoint)
        model_id = target.model_id or "nova-2"
        timeout = _safe_timeout(target.config.get("timeout_s"), default=180.0, low=10.0, high=300.0)
        data = await fetch(
            "Deepgram", "POST", http_url,
            params={"model": model_id, "diarize": "true", "utterances": "true", "punctuate": "true"},
            headers={"Authorization": f"Token {target.api_key}", "Content-Type": content_type},
            content=audio_bytes, timeout=timeout, limit=12_000_000, **extra_opts,
        )
        record_tokens(*model_budgets.extract_usage(target.provider, data))
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

    return await _run_chain(candidates, _call, fetch_fn=fetch, on_usage=on_usage)
