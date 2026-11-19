"""Quota limiting, SSRF error inspection, and numeric clamping policies for model execution."""
import math
import threading
import time
from typing import Any

from fastapi import HTTPException

from . import model_resolver, ssrf_guard


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


def _is_ssrf_error(exc: BaseException) -> bool:
    seen: set[int] = set()
    cur: BaseException | None = exc
    while cur is not None and id(cur) not in seen:
        seen.add(id(cur))
        if isinstance(cur, ssrf_guard.SSRFValidationError):
            return True
        cur = cur.__cause__ or cur.__context__
    return False


def _safe_finite_float(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        fval = float(value)
    except (TypeError, ValueError, OverflowError):
        return None
    return fval if math.isfinite(fval) else None


def _safe_timeout(raw: Any, *, default: float, low: float, high: float) -> float:
    fval = _safe_finite_float(raw)
    if fval is None:
        return default
    return min(max(fval, low), high)


def _clamped_retries(target: model_resolver.ResolvedModel) -> int:
    fval = _safe_finite_float(target.config.get("max_retries", 0))
    if fval is None:
        return 0
    return min(max(int(fval), 0), 3)


def _rpm_limit(target: model_resolver.ResolvedModel) -> int | None:
    raw = target.config.get("rpm_limit")
    if isinstance(raw, bool) or not isinstance(raw, int) or raw < 1:
        return None
    return raw
