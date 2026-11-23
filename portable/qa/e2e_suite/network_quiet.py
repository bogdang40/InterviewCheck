"""Know when a page has no workspace API requests in flight.

A test that ends the browser session (password rotation, sign out, clearing
cookies) while the page is still loading races the page's own requests: one sent
with the old session and authenticated after the session ended is refused with
401, and the browser logs that refusal as a console error. Waiting for a quiet
page first makes the session end at a moment the test controls.
"""
from typing import Callable
from urllib.parse import urlsplit
import time

DEFAULT_QUIET_MS = 300
DEFAULT_TIMEOUT_MS = 10_000
POLL_MS = 25


class InFlightRequests:
    """Track a page's API requests from start to finish or failure."""

    def __init__(self, page, *, path_prefix: str = "/api/", clock: Callable[[], float] = time.monotonic):
        self._page = page
        self._path_prefix = path_prefix
        self._clock = clock
        self._pending: dict[object, str] = {}
        self._last_change = clock()
        page.on("request", self._started)
        page.on("requestfinished", self._settled)
        page.on("requestfailed", self._settled)

    @property
    def pending_urls(self) -> list[str]:
        return sorted(self._pending.values())

    def wait_until_quiet(self, *, quiet_ms: int = DEFAULT_QUIET_MS, timeout_ms: int = DEFAULT_TIMEOUT_MS) -> None:
        """Return once no API request has been in flight for quiet_ms, so chained requests have started too."""
        deadline = self._clock() + timeout_ms / 1000
        while self._pending or self._clock() - self._last_change < quiet_ms / 1000:
            if self._clock() >= deadline:
                raise AssertionError(f"API requests still in flight after {timeout_ms} ms: {self.pending_urls}")
            self._page.wait_for_timeout(POLL_MS)

    def _tracked(self, request) -> bool:
        return urlsplit(request.url).path.startswith(self._path_prefix)

    def _started(self, request) -> None:
        if self._tracked(request):
            self._pending[request] = f"{request.method} {request.url}"
            self._last_change = self._clock()

    def _settled(self, request) -> None:
        if self._pending.pop(request, None) is not None:
            self._last_change = self._clock()
