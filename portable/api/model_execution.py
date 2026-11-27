"""Resilient model chain execution with RPM quotas, retries, failover, and live telemetry."""
import asyncio
from collections.abc import Awaitable, Callable
import time
from typing import Any

from fastapi import HTTPException
from starlette.concurrency import run_in_threadpool

from . import model_budgets, model_circuit, model_resolver, provider_allowance, provider_http, ssrf_guard
from .model_outcomes import _check_target_budget, _record_outcome, _redact_target_secrets, _sanitize_target_error
from .model_execution_policy import (
    ModelQuotaLimiter, QUOTA_LIMITER,
    _clamped_retries,
    _is_ssrf_error,
    _rpm_limit, _safe_finite_float,
    _safe_timeout,
    reset_quotas,
)

FAILOVER_STATUSES = frozenset({429, 502, 503, 504})
_ORIG_RESOLVE_OR_503 = model_resolver.resolve_or_503
_ORIG_DISPATCH_COMPLETION = model_resolver.dispatch_completion
MeterCallback = Callable[[model_budgets.TokenUsage], None]


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
        await run_in_threadpool(_record_outcome, target, ok=False, http_status=400, latency_ms=0, error=detail, provider_attempted=False)
        raise HTTPException(400, detail) from exc


async def _run_chain(
    candidates: list[model_resolver.ResolvedModel],
    call_fn: Callable[[model_resolver.ResolvedModel, MeterCallback], Awaitable[Any]],
    *,
    fetch_fn=None,
    on_usage: Callable[[int, int], None] | None = None,
    before_attempt: Callable[[], Awaitable[None]] | None = None,
) -> tuple[model_resolver.ResolvedModel, Any]:
    real_transport = (fetch_fn is None or fetch_fn is provider_http.fetch_json) and (
        model_resolver.dispatch_completion is _ORIG_DISPATCH_COMPLETION
    )
    last_exc: HTTPException | None = None
    budget_blocked = False
    circuit_retry_after: int | None = None
    for target in candidates:
        retries = _clamped_retries(target)
        transcription = target.capability == "transcription"
        for attempt in range(retries + 1):
            # A failed response can contain paid tokens. Apply the recorded spend before retrying.
            decision = await run_in_threadpool(_check_target_budget, target)
            if decision is not None and not decision.allowed:
                budget_blocked = True
                break
            circuit = await run_in_threadpool(model_circuit.check_target, target.id, claim=transcription)
            if circuit is not None and not circuit.allowed:
                wait_s = max(1, int(circuit.retry_after_s or 1))
                circuit_retry_after = wait_s if circuit_retry_after is None else min(circuit_retry_after, wait_s)
                break
            await _validate_target_endpoint(target, resolve_dns=real_transport)
            if before_attempt is not None:
                await before_attempt()
            if transcription and target.id and (rpm := _rpm_limit(target)) is not None:
                try:
                    QUOTA_LIMITER.consume(target.id, rpm)
                except HTTPException as exc:
                    last_exc = exc
                    break
            usage = model_budgets.TokenUsage()

            def record_usage(result: model_budgets.TokenUsage) -> None:
                nonlocal usage
                usage = result
                if on_usage is not None:
                    on_usage(result.input_tokens, result.output_tokens)

            started = time.monotonic()
            try:
                result = await call_fn(target, record_usage)
            except provider_allowance.TargetRefusal as exc:
                if exc.status_code == 503:
                    wait = int(exc.headers["Retry-After"])
                    circuit_retry_after = wait if circuit_retry_after is None else min(circuit_retry_after, wait)
                else:
                    last_exc = exc
                break
            except provider_allowance.AdmissionError:
                raise
            except ssrf_guard.SSRFValidationError as exc:
                elapsed = int((time.monotonic() - started) * 1000)
                detail = _sanitize_target_error(str(exc), "Blocked unsafe provider endpoint.", target)
                await run_in_threadpool(
                    _record_outcome, target, ok=False, http_status=400, latency_ms=elapsed, error=detail,
                    usage=usage, provider_attempted=False,
                )
                raise HTTPException(400, detail) from exc
            except HTTPException as exc:
                elapsed = int((time.monotonic() - started) * 1000)
                detail = _sanitize_target_error(str(exc.detail), "Provider call failed.", target)
                locally_blocked = _is_ssrf_error(exc)
                await run_in_threadpool(
                    _record_outcome, target, ok=False, http_status=exc.status_code, latency_ms=elapsed, error=detail,
                    usage=usage, provider_attempted=not locally_blocked,
                )
                safe_exc = HTTPException(exc.status_code, detail, headers=getattr(exc, "headers", None))
                if locally_blocked or exc.status_code not in FAILOVER_STATUSES:
                    raise safe_exc from exc
                last_exc = safe_exc
                if attempt < retries:
                    await asyncio.sleep(min(0.2 * (attempt + 1), 0.5))
                    continue
                break
            elapsed = int((time.monotonic() - started) * 1000)
            await run_in_threadpool(
                _record_outcome, target, ok=True, http_status=200, latency_ms=elapsed, error=None,
                usage=usage,
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


async def dispatch_completion(target, instructions, prompt, *, record_usage, before_send=None,
                              use_circuit=True, **kwargs):
    dispatch = model_resolver.dispatch_completion
    if dispatch is _ORIG_DISPATCH_COMPLETION:
        return await dispatch(target, instructions, prompt, on_metering=record_usage, before_send=before_send,
                              use_circuit=use_circuit, **kwargs)
    return await provider_allowance.send(dispatch, target, instructions, prompt, admission_target=target,
                                         before_send=before_send, use_circuit=use_circuit, **kwargs)


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
    before_attempt: Callable[[], Awaitable[None]] | None = None,
) -> tuple[model_resolver.ResolvedModel, tuple[str, str]]:
    candidates = await run_in_threadpool(
        resolve_candidates, capability, provider=provider, allow_reference_fallback=allow_reference_fallback
    )

    async def _call(target: model_resolver.ResolvedModel, record_usage: MeterCallback) -> tuple[str, str]:
        return await dispatch_completion(
            target, instructions, prompt, fetch_fn=fetch_fn, max_tokens=max_tokens, record_usage=record_usage, before_send=before_attempt
        )

    return await _run_chain(candidates, _call, fetch_fn=fetch_fn, on_usage=on_usage, before_attempt=before_attempt)


async def execute_reference_chain(
    instructions: str,
    user_input: str,
    *,
    fetch_fn=None,
    default_max_tokens: int = 1200,
    on_usage: Callable[[int, int], None] | None = None,
) -> tuple[model_resolver.ResolvedModel, tuple[str, str]]:
    candidates = await run_in_threadpool(resolve_candidates, "reference")
    fetch = fetch_fn or provider_http.fetch_json
    extra_opts = {"ssrf_safe": True} if fetch is provider_http.fetch_json else {}

    async def _call(target: model_resolver.ResolvedModel, record_usage: MeterCallback) -> tuple[str, str]:
        limit_tokens = target.config.get("max_tokens") or default_max_tokens
        if target.provider != "openai":
            model_id, text = await dispatch_completion(
                target, instructions, user_input, fetch_fn=fetch, max_tokens=limit_tokens, record_usage=record_usage
            )
            return f"{target.display_name} {model_id}"[:180], text
        timeout = _safe_timeout(target.config.get("timeout_s"), default=75.0, low=1.0, high=180.0)
        payload: dict[str, Any] = {"model": target.model_id, "store": False, "max_output_tokens": limit_tokens, "instructions": instructions, "input": user_input}
        if target.config.get("temperature") is not None:
            payload["temperature"] = target.config["temperature"]
        data = await provider_allowance.send(fetch, "OpenAI", "POST", "https://api.openai.com/v1/responses", admission_target=target, use_circuit=True, timeout=timeout, headers={"Authorization": "Bearer " + target.api_key}, json=payload, **extra_opts)
        record_usage(model_budgets.provider_usage(target.provider, data, capability=target.capability))
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
    candidates = await run_in_threadpool(resolve_candidates, "embedding", provider=provider)
    fetch = fetch_fn or provider_http.fetch_json
    extra_opts = {"ssrf_safe": True} if fetch is provider_http.fetch_json else {}

    async def _call(target: model_resolver.ResolvedModel, record_usage: MeterCallback) -> list[list[float]]:
        url, headers, payload = request_builder(target, texts)
        timeout = _safe_timeout(target.config.get("timeout_s"), default=30.0, low=1.0, high=180.0)
        data = await provider_allowance.send(fetch, model_resolver.DISPLAY_PROVIDER.get(target.provider, target.display_name), "POST", url, admission_target=target, use_circuit=True, headers=headers, json=payload, timeout=timeout, **extra_opts)
        record_usage(model_budgets.provider_usage(target.provider, data, capability=target.capability))
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
    candidates = await run_in_threadpool(resolve_candidates, "transcription")
    fetch = fetch_fn or provider_http.fetch_json
    extra_opts = {"ssrf_safe": True} if fetch is provider_http.fetch_json else {}

    async def _call(target: model_resolver.ResolvedModel, record_usage: MeterCallback) -> list[dict[str, str]]:
        http_url, _ = url_builder(target.endpoint)
        model_id = target.model_id or "nova-2"
        timeout = _safe_timeout(target.config.get("timeout_s"), default=180.0, low=10.0, high=300.0)
        data = await fetch(
            "Deepgram", "POST", http_url,
            params={"model": model_id, "diarize": "true", "utterances": "true", "punctuate": "true"},
            headers={"Authorization": f"Token {target.api_key}", "Content-Type": content_type},
            content=audio_bytes, timeout=timeout, limit=12_000_000, **extra_opts,
        )
        record_usage(model_budgets.provider_usage(target.provider, data, capability=target.capability))
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
