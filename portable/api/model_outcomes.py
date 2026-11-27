"""Account for completed, failed and locally blocked model dispatches."""
import sqlite3

from . import ai_cost_log, model_budgets, model_circuit, model_resolver, model_telemetry, store
from .error_sanitizer import sanitize_error_text


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
    target: model_resolver.ResolvedModel, *, ok: bool, http_status: int | None,
    latency_ms: int | None, error: str | None,
    usage: model_budgets.TokenUsage = model_budgets.TokenUsage(), provider_attempted: bool = True,
) -> None:
    safe_error = _redact_target_secrets(error, target) if (not ok and error) else error
    try:
        with store.connection(write=True) as db:
            if provider_attempted:
                ai_cost_log.record(db, target, ok=ok, http_status=http_status, latency_ms=latency_ms, usage=usage)
            if target.id is None:
                return  # server-setting models have no registry row for telemetry, budgets or circuits
            model_telemetry.record_check(
                db, target.id, source="live", ok=ok, http_status=http_status,
                latency_ms=latency_ms, error=safe_error, checked_at=store.timestamp(),
            )
            if provider_attempted:
                model_budgets.record_usage(db, target.id, input_tokens=usage.input_tokens, output_tokens=usage.output_tokens,
                                           ok=ok, config=target.config, unsplit_tokens=usage.unsplit_tokens)
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
