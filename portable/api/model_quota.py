"""Process-local per-model request quotas."""
import threading
import time

from fastapi import HTTPException


class ModelQuotaLimiter:
    def __init__(self, window_seconds: int = 60) -> None:
        self.window_seconds = window_seconds
        self._lock = threading.Lock()
        self._buckets: dict[str, tuple[int, float]] = {}

    def consume(self, model_id: str, rpm_limit: int) -> float:
        now = time.monotonic()
        with self._lock:
            count, start = self._buckets.get(model_id, (0, now))
            elapsed = now - start
            if elapsed >= self.window_seconds:
                self._buckets[model_id] = (1, now)
                return now
            if count >= rpm_limit:
                retry_after = max(1, int(self.window_seconds - elapsed + 0.999))
                raise HTTPException(429, "Model request rate quota exceeded.", headers={"Retry-After": str(retry_after)})
            self._buckets[model_id] = (count + 1, start)
            return start

    def release(self, model_id: str, start: float) -> None:
        # A late refusal must never debit a different minute's bucket.
        with self._lock:
            bucket = self._buckets.get(model_id)
            if bucket and bucket[1] == start and bucket[0] > 0:
                self._buckets[model_id] = (bucket[0] - 1, start)

    def reset(self) -> None:
        with self._lock:
            self._buckets.clear()


QUOTA_LIMITER = ModelQuotaLimiter()


def reset_quotas() -> None:
    QUOTA_LIMITER.reset()
