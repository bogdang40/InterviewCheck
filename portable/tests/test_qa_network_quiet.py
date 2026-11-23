"""Unit tests for the QA helper that waits until a page has no API request in flight."""
from pathlib import Path
import sys

import pytest

QA_DIR = Path(__file__).resolve().parents[1] / "qa"
if str(QA_DIR) not in sys.path:
    sys.path.insert(0, str(QA_DIR))

from e2e_suite.network_quiet import InFlightRequests  # noqa: E402


class FakePage:
    """A page whose events fire at scheduled times on a fake clock that wait_for_timeout advances."""

    def __init__(self):
        self.now = 0.0
        self.handlers: dict[str, list] = {}
        self.schedule: list[tuple[float, str, object]] = []

    def clock(self) -> float:
        return self.now

    def on(self, event, handler):
        self.handlers.setdefault(event, []).append(handler)

    def at(self, seconds, event, request):
        self.schedule.append((seconds, event, request))
        self.schedule.sort(key=lambda item: item[0])

    def emit(self, event, request):
        for handler in self.handlers.get(event, []):
            handler(request)

    def wait_for_timeout(self, ms):
        self.now += ms / 1000
        while self.schedule and self.schedule[0][0] <= self.now:
            _, event, request = self.schedule.pop(0)
            self.emit(event, request)


class FakeRequest:
    """Hashable by identity, like Playwright's request objects."""

    def __init__(self, path, method="GET"):
        self.url = f"http://127.0.0.1:3000{path}"
        self.method = method


def request(path, method="GET"):
    return FakeRequest(path, method)


def tracked_page():
    page = FakePage()
    return page, InFlightRequests(page, clock=page.clock)


def test_waits_for_a_request_chained_after_the_first_one_finishes():
    page, in_flight = tracked_page()
    status, account = request("/api/integrations/status"), request("/api/integrations/account")
    page.emit("request", status)
    page.at(0.2, "requestfinished", status)
    page.at(0.25, "request", account)  # the page asks for the account only after status answers
    page.at(0.9, "requestfinished", account)
    in_flight.wait_until_quiet(quiet_ms=300)
    assert page.now >= 0.9 + 0.3
    assert in_flight.pending_urls == []


def test_failed_requests_settle_and_other_paths_are_ignored():
    page, in_flight = tracked_page()
    aborted, script = request("/api/interviews/feed"), request("/_next/static/chunk.js")
    page.emit("request", aborted)
    page.emit("request", script)
    page.at(0.1, "requestfailed", aborted)
    in_flight.wait_until_quiet(quiet_ms=300)
    assert 0.4 <= page.now < 0.5


def test_reports_requests_that_never_finish():
    page, in_flight = tracked_page()
    page.emit("request", request("/api/integrations/plans"))
    with pytest.raises(AssertionError, match="GET http://127.0.0.1:3000/api/integrations/plans"):
        in_flight.wait_until_quiet(timeout_ms=500)
