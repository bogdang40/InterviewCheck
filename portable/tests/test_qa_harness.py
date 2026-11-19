"""Unit tests for the portable QA Next.js and Playwright harness."""
from http.client import RemoteDisconnected
import importlib.util
import json
from pathlib import Path
import sys
from types import SimpleNamespace
from urllib.error import URLError

from playwright.sync_api import Error as PlaywrightError
import pytest

QA_DIR = Path(__file__).resolve().parents[1] / "qa"
if str(QA_DIR) not in sys.path:
    sys.path.insert(0, str(QA_DIR))

import next_frontend  # noqa: E402
import smoke_next  # noqa: E402

_CONFTEST_SPEC = importlib.util.spec_from_file_location("qa_conftest_under_test", QA_DIR / "conftest.py")
qa_conftest = importlib.util.module_from_spec(_CONFTEST_SPEC)
_CONFTEST_SPEC.loader.exec_module(qa_conftest)


def test_manifest_api_port_parses_dict_and_list_rewrites(tmp_path):
    dist_dict = tmp_path / "dict-dist"
    dist_dict.mkdir()
    (dist_dict / "routes-manifest.json").write_text(
        json.dumps({
            "rewrites": {
                "beforeFiles": [],
                "afterFiles": [
                    {"source": "/api/:path*", "destination": "http://127.0.0.1:8123/api/:path*"},
                    {"source": "/v1/:path*", "destination": "http://127.0.0.1:8123/v1/:path*"},
                ],
                "fallback": [],
            }
        }),
        encoding="utf-8",
    )
    assert next_frontend.manifest_api_port(dist_dict) == 8123

    dist_list = tmp_path / "list-dist"
    dist_list.mkdir()
    (dist_list / "routes-manifest.json").write_text(
        json.dumps({"rewrites": [{"source": "/api/:path*", "destination": "http://127.0.0.1:9001/api/:path*"}]}),
        encoding="utf-8",
    )
    assert next_frontend.manifest_api_port(dist_list) == 9001


def test_manifest_api_port_returns_none_for_missing_or_invalid_manifest(tmp_path):
    assert next_frontend.manifest_api_port(tmp_path / "missing") is None

    bad_json = tmp_path / "bad-json"
    bad_json.mkdir()
    (bad_json / "routes-manifest.json").write_text("{not-json", encoding="utf-8")
    assert next_frontend.manifest_api_port(bad_json) is None

    bad_port = tmp_path / "bad-port"
    bad_port.mkdir()
    (bad_port / "routes-manifest.json").write_text(
        json.dumps({"rewrites": [{"source": "/api/:path*", "destination": "http://127.0.0.1:abc/api/:path*"}]}),
        encoding="utf-8",
    )
    assert next_frontend.manifest_api_port(bad_port) is None


def test_wait_for_http_ready_retries_remote_disconnected_and_connection_errors(tmp_path):
    log_path = tmp_path / "next.log"
    log_path.write_text("starting", encoding="utf-8")
    process = SimpleNamespace(poll=lambda: None)
    outcomes = [
        RemoteDisconnected("Remote end closed connection without response"),
        ConnectionResetError("Connection reset by peer"),
        URLError("Connection refused"),
        200,
    ]
    calls = []

    class _Response:
        def __init__(self, status):
            self.status = status

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

    def fake_opener(url, timeout=25):
        calls.append((url, timeout))
        outcome = outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return _Response(outcome)

    next_frontend.wait_for_http_ready(
        "http://127.0.0.1:3456",
        process,
        log_path,
        "dev",
        timeout=5,
        opener=fake_opener,
        sleep=lambda _seconds: None,
    )
    assert len(calls) == 4


def test_wait_for_http_ready_raises_when_process_exits(tmp_path):
    log_path = tmp_path / "next.log"
    log_path.write_text("fatal startup failure", encoding="utf-8")
    process = SimpleNamespace(poll=lambda: 1)

    with pytest.raises(RuntimeError, match="fatal startup failure"):
        next_frontend.wait_for_http_ready(
            "http://127.0.0.1:3456",
            process,
            log_path,
            "start",
            opener=lambda *_args, **_kwargs: pytest.fail("should not poll exited process"),
            sleep=lambda _seconds: None,
        )


def test_smoke_wait_for_health_retries_http_exception(tmp_path):
    log_path = tmp_path / "smoke.log"
    log_path.write_text("booting", encoding="utf-8")
    process = SimpleNamespace(poll=lambda: None)
    outcomes = [
        RemoteDisconnected("Remote end closed connection without response"),
        ConnectionResetError("reset"),
        (200, b'{"ok": true}'),
    ]
    attempts = 0

    def fake_opener(_base, _path):
        nonlocal attempts
        attempts += 1
        outcome = outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome

    smoke_next.wait_for_health("http://127.0.0.1:3000", process, log_path, opener=fake_opener, sleep=lambda _s: None)
    assert attempts == 3


def test_launch_chromium_falls_back_to_chrome_only_when_unset_and_executable_missing():
    calls = []

    class _Chromium:
        def launch(self, channel=None, args=None):
            calls.append((channel, args))
            if channel is None:
                raise PlaywrightError("BrowserType.launch: Executable doesn't exist at /tmp/chromium")
            return f"browser:{channel}"

    playwright = SimpleNamespace(chromium=_Chromium())
    assert qa_conftest.launch_chromium(playwright, env={}) == "browser:chrome"
    assert [c[0] for c in calls] == [None, "chrome"]


def test_launch_chromium_respects_explicit_channel_and_non_missing_errors():
    class _Chromium:
        def __init__(self, message):
            self.message = message
            self.channels = []

        def launch(self, channel=None, args=None):
            self.channels.append(channel)
            raise PlaywrightError(self.message)

    explicit = _Chromium("BrowserType.launch: Executable doesn't exist at /tmp/none")
    with pytest.raises(PlaywrightError, match="Executable doesn't exist"):
        qa_conftest.launch_chromium(
            SimpleNamespace(chromium=explicit),
            env={"INTERVIEWCHECK_BROWSER_CHANNEL": "nonexistent-channel"},
        )
    assert explicit.channels == ["nonexistent-channel"]

    other = _Chromium("BrowserType.launch: Target closed unexpectedly")
    with pytest.raises(PlaywrightError, match="Target closed"):
        qa_conftest.launch_chromium(SimpleNamespace(chromium=other), env={})
    assert other.channels == [None]


def test_resolve_start_api_port_handles_explicit_bindable_and_busy_ports(tmp_path, monkeypatch):
    web = tmp_path / "web"
    dist = web / ".next-server"
    dist.mkdir(parents=True)
    (dist / "BUILD_ID").write_text("build-1", encoding="utf-8")
    (dist / "routes-manifest.json").write_text(
        json.dumps({"rewrites": [{"source": "/api/:path*", "destination": "http://127.0.0.1:8000/api/:path*"}]}),
        encoding="utf-8",
    )

    assert qa_conftest.resolve_start_api_port(web, env={"INTERVIEWCHECK_API_PORT": "8444"}) == 8444

    monkeypatch.setattr(qa_conftest, "can_bind", lambda port: port == 8000)
    assert qa_conftest.resolve_start_api_port(web, env={}) == 8000

    monkeypatch.setattr(qa_conftest, "can_bind", lambda _port: False)
    monkeypatch.setattr(qa_conftest, "free_port", lambda: 54321)
    assert qa_conftest.resolve_start_api_port(web, env={}) == 54321


def test_uvicorn_keep_alive_exceeds_default_five_seconds(tmp_path, monkeypatch):
    from e2e_suite.harness import IsolatedWorkspace

    ws = IsolatedWorkspace(tmp_path, monkeypatch, (None, None, 0))
    ws.prepare_env()
    ws.start()
    try:
        assert ws._server is not None
        assert ws._server.config.timeout_keep_alive >= 120
    finally:
        ws.stop()

    portable_root = Path(__file__).resolve().parents[1]
    assert "--timeout-keep-alive" in (portable_root / "web-runtime.mjs").read_text(encoding="utf-8")
    assert "--timeout-keep-alive" in (portable_root / "run.py").read_text(encoding="utf-8")
    assert "timeout_keep_alive=300" in (QA_DIR / "conftest.py").read_text(encoding="utf-8")

