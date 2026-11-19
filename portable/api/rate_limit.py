"""In-memory fixed-window rate limiting for admin, AI, integration, and billing endpoints."""
import threading
import time
from typing import Callable

from fastapi import HTTPException, Request

_MAX_BUCKETS = 5000
_LIMITERS: list["FixedWindowRateLimiter"] = []


class FixedWindowRateLimiter:
    def __init__(self, max_requests: int, window_seconds: int = 60) -> None:
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        self._lock = threading.Lock()
        self._buckets: dict[str, tuple[int, float]] = {}
        _LIMITERS.append(self)

    def hit(self, key: str) -> tuple[bool, int]:
        now = time.monotonic()
        with self._lock:
            if len(self._buckets) >= _MAX_BUCKETS:
                expired = [k for k, (_, start) in self._buckets.items() if now - start >= self.window_seconds]
                for k in expired:
                    del self._buckets[k]
                if len(self._buckets) >= _MAX_BUCKETS:
                    oldest = min(self._buckets.items(), key=lambda item: item[1][1])[0]
                    del self._buckets[oldest]
            count, start = self._buckets.get(key, (0, now))
            elapsed = now - start
            if elapsed >= self.window_seconds:
                self._buckets[key] = (1, now)
                return True, 0
            if count >= self.max_requests:
                retry_after = max(1, int(self.window_seconds - elapsed + 0.999))
                return False, retry_after
            self._buckets[key] = (count + 1, start)
            return True, 0

    def reset(self) -> None:
        with self._lock:
            self._buckets.clear()


def reset_all() -> None:
    for limiter in _LIMITERS:
        limiter.reset()


ADMIN_READ = FixedWindowRateLimiter(120, 60)
ADMIN_WRITE = FixedWindowRateLimiter(40, 60)
ADMIN_PROBE = FixedWindowRateLimiter(15, 60)
AI_REQUEST = FixedWindowRateLimiter(20, 60)
INTEGRATION_REMOTE = FixedWindowRateLimiter(30, 60)
BILLING_ACTION = FixedWindowRateLimiter(20, 60)


def limit(limiter: FixedWindowRateLimiter, *, scope: str = "ip") -> Callable[[Request], None]:
    def dependency(request: Request) -> None:
        embedded = getattr(request.app.state, "embedded", True)
        if embedded:
            from .origin import workspace_client
            address = workspace_client(request)
        else:
            address = request.client.host if request.client else "local"
        key = f"{scope}:{address}" if scope != "ip" else address
        allowed, retry_after = limiter.hit(key)
        if not allowed:
            raise HTTPException(
                429,
                "Too many requests. Try again in a minute.",
                headers={"Retry-After": str(retry_after)},
            )

    return dependency
