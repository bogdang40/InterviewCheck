"""Opaque-box server lifecycle, auth, audio mock, and Playwright diagnostic helpers."""
from contextlib import contextmanager
from dataclasses import dataclass, field
import importlib.util
import os
from pathlib import Path
import socket
import threading
import time

import httpx
import pytest
from playwright.sync_api import Page
import uvicorn

QA_ROOT = Path(__file__).resolve().parents[1]
PORTABLE_ROOT = QA_ROOT.parent
DESKTOP_VIEWPORT = {"width": 1440, "height": 900}
MOBILE_VIEWPORT = {"width": 390, "height": 844}

SCRUBBED_ENV_KEYS = (
    "INTERVIEWCHECK_ACCESS_URL",
    "INTERVIEWCHECK_ACCESS_MODE",
    "INTERVIEWCHECK_OPERATOR_EMAIL",
    "INTERVIEWCHECK_OPERATOR_ID",
    "INTERVIEWCHECK_PUBLIC_ORIGIN",
    "INTERVIEWCHECK_PRODUCTION",
    "INTERVIEWCHECK_SIGNUP_SECRET",
    "INTERVIEWCHECK_WEB_PORT",
    "INTERVIEWCHECK_MODEL_SECRET_KEY",
    "INTERVIEWCHECK_MODEL_SECRET_FILE",
    "ADMIN_EMAILS",
    "ADMIN_BOOTSTRAP_SECRET",
    "TRIAL_DAYS",
    "STRIPE_SECRET_KEY",
    "STRIPE_WEBHOOK_SECRET",
    "DEEPGRAM_API_KEY",
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "AZURE_OPENAI_API_KEY",
    "ASHBY_API_KEY",
    "LEVER_API_KEY",
    "MERGE_API_KEY",
    "GREENHOUSE_CLIENT_ID",
    "GOOGLE_CALENDAR_ACCESS_TOKEN",
    "MS_GRAPH_ACCESS_TOKEN",
    "ZOOM_ACCESS_TOKEN",
    "WEBEX_ACCESS_TOKEN",
    "CALENDLY_TOKEN",
    "CALCOM_API_KEY",
)

AUDIO_MOCK_INIT_SCRIPT = """
(() => {
  const devices = navigator.mediaDevices || (navigator.mediaDevices = {});
  function buildSyntheticAudioStream() {
    const AudioCtx = window.AudioContext || window.webkitAudioContext;
    if (!AudioCtx) {
      throw new Error("AudioContext unavailable in synthetic mock.");
    }
    const ctx = new AudioCtx();
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    gain.gain.value = 0.02;
    const dest = ctx.createMediaStreamDestination();
    osc.connect(gain);
    gain.connect(dest);
    osc.start();
    const stream = dest.stream;
    const originalStop = stream.getTracks.bind(stream);
    stream.addEventListener("inactive", () => {
      try { osc.stop(); } catch (_) {}
      try { ctx.close(); } catch (_) {}
    });
    stream._mockStop = () => {
      for (const track of originalStop()) { track.stop(); }
      try { osc.stop(); } catch (_) {}
      try { ctx.close(); } catch (_) {}
    };
    return stream;
  }

  function buildSyntheticVideoTrack() {
    const canvas = document.createElement("canvas");
    canvas.width = 64;
    canvas.height = 48;
    const ctx2d = canvas.getContext("2d");
    if (ctx2d) {
      ctx2d.fillStyle = "#182026";
      ctx2d.fillRect(0, 0, canvas.width, canvas.height);
    }
    const stream = canvas.captureStream ? canvas.captureStream(5) : new MediaStream();
    return stream.getVideoTracks()[0] || null;
  }

  devices.getUserMedia = async (constraints = {}) => {
    const stream = new MediaStream();
    if (constraints.audio) {
      const audioStream = buildSyntheticAudioStream();
      for (const track of audioStream.getAudioTracks()) {
        stream.addTrack(track);
      }
    }
    if (constraints.video) {
      const videoTrack = buildSyntheticVideoTrack();
      if (videoTrack) stream.addTrack(videoTrack);
    }
    return stream;
  };

  devices.getDisplayMedia = async (constraints = {}) => {
    const stream = await devices.getUserMedia({
      video: constraints.video !== false,
      audio: Boolean(constraints.audio),
    });
    window.__icMockDisplayTracks = stream.getTracks();
    return stream;
  };
})();
"""


def load_parent_qa_conftest():
    spec = importlib.util.spec_from_file_location("qa_parent_conftest", QA_ROOT / "conftest.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@dataclass
class ConsoleErrorCollector:
    """Capture browser console errors, uncaught exceptions, and 5xx HTTP responses."""

    console_errors: list[str] = field(default_factory=list)
    page_errors: list[str] = field(default_factory=list)
    server_errors: list[str] = field(default_factory=list)
    ignore_server_5xx: bool = False

    def attach(self, page: Page) -> None:
        def on_console(msg) -> None:
            if msg.type == "error":
                self.console_errors.append(msg.text)

        def on_pageerror(err) -> None:
            self.page_errors.append(str(err))

        def on_response(response) -> None:
            if not self.ignore_server_5xx and response.status >= 500:
                self.server_errors.append(f"{response.status} {response.url}")

        page.on("console", on_console)
        page.on("pageerror", on_pageerror)
        page.on("response", on_response)

    def reset(self) -> None:
        self.console_errors.clear()
        self.page_errors.clear()
        self.server_errors.clear()

    def assert_clean(self) -> None:
        assert not self.page_errors, f"Uncaught page errors: {self.page_errors}"
        assert not self.console_errors, f"Browser console errors: {self.console_errors}"
        assert not self.server_errors, f"Unexpected 5xx responses: {self.server_errors}"


class IsolatedWorkspace:
    """Restartable isolated FastAPI workspace backed by temporary SQLite databases."""

    def __init__(self, tmp_path: Path, monkeypatch, frontend_info: tuple[str | None, int | None, int]):
        self.tmp_path = tmp_path
        self.monkeypatch = monkeypatch
        self.public_url, self.web_port, self.configured_api_port = frontend_info
        self.review_db = tmp_path / "review.sqlite3"
        self.access_db = tmp_path / "access.sqlite3"
        self.secret_file = tmp_path / ".model_secret.key"
        self.screenshot_dir = self._resolve_screenshot_dir(tmp_path)
        self._server: uvicorn.Server | None = None
        self._thread: threading.Thread | None = None
        self._bound_api_port: int = self.configured_api_port

    @staticmethod
    def _resolve_screenshot_dir(tmp_path: Path) -> Path:
        configured = os.getenv("INTERVIEWCHECK_E2E_SCREENSHOT_DIR", "").strip()
        target = Path(configured) if configured else (tmp_path / "screenshots")
        target.mkdir(parents=True, exist_ok=True)
        return target

    @property
    def base_url(self) -> str:
        return self.public_url or f"http://127.0.0.1:{self._bound_api_port}"

    def prepare_env(self) -> None:
        for key in SCRUBBED_ENV_KEYS:
            self.monkeypatch.delenv(key, raising=False)
        if self.web_port:
            self.monkeypatch.setenv("INTERVIEWCHECK_WEB_PORT", str(self.web_port))
        self.monkeypatch.setenv("INTERVIEWCHECK_DB", str(self.review_db))
        self.monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(self.access_db))
        self.monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "e2e-deterministic-test-secret-key")
        self.monkeypatch.syspath_prepend(str(PORTABLE_ROOT))
        self.monkeypatch.chdir(PORTABLE_ROOT)

    def configure_embedded_auth(
        self,
        *,
        admin_emails: tuple[str, ...] = ("admin1@example.test", "admin2@example.test"),
        bootstrap_secret: str = "e2e-bootstrap-secret-1234",
        signup_secret: str | None = None,
        trial_days: str = "3",
        operator_email: str | None = None,
    ) -> None:
        self.monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
        self.monkeypatch.setenv("ADMIN_EMAILS", ",".join(admin_emails))
        self.monkeypatch.setenv("ADMIN_BOOTSTRAP_SECRET", bootstrap_secret)
        self.monkeypatch.setenv("TRIAL_DAYS", trial_days)
        if signup_secret:
            self.monkeypatch.setenv("INTERVIEWCHECK_SIGNUP_SECRET", signup_secret)
        else:
            self.monkeypatch.delenv("INTERVIEWCHECK_SIGNUP_SECRET", raising=False)
        if operator_email:
            self.monkeypatch.setenv("INTERVIEWCHECK_OPERATOR_EMAIL", operator_email)
        else:
            self.monkeypatch.delenv("INTERVIEWCHECK_OPERATOR_EMAIL", raising=False)

    def start(self) -> str:
        if self._server is not None:
            return self.base_url
        from api.main import app

        target_port = self._bound_api_port
        listener = socket.create_server(("127.0.0.1", target_port))
        self._bound_api_port = listener.getsockname()[1]
        server = uvicorn.Server(uvicorn.Config(app, access_log=False, log_level="warning"))
        thread = threading.Thread(target=server.run, kwargs={"sockets": [listener]}, daemon=True)
        thread.start()
        deadline = time.monotonic() + 15
        while not server.started:
            if not thread.is_alive() or time.monotonic() >= deadline:
                listener.close()
                raise RuntimeError("FastAPI did not start within 15 seconds.")
            time.sleep(0.05)
        self._server = server
        self._thread = thread
        return self.base_url

    def stop(self) -> None:
        if self._server is None:
            return
        self._server.should_exit = True
        if self._thread is not None:
            self._thread.join(timeout=10)
            assert not self._thread.is_alive(), "FastAPI did not stop cleanly."
        self._server = None
        self._thread = None

    def restart(self) -> str:
        self.stop()
        return self.start()

    @contextmanager
    def client(self, *, headers: dict[str, str] | None = None):
        merged = {"X-InterviewCheck": "1"}
        if headers:
            merged.update(headers)
        with httpx.Client(base_url=self.base_url, headers=merged, trust_env=False, timeout=15.0) as client:
            yield client


def signup_user(
    client: httpx.Client,
    *,
    email: str,
    password: str = "Synthetic-E2E-Pass-9876",
    admin_secret: str | None = None,
    invite_code: str | None = None,
) -> dict:
    payload: dict[str, str] = {"email": email, "password": password}
    if admin_secret is not None:
        payload["adminSecret"] = admin_secret
    if invite_code is not None:
        payload["inviteCode"] = invite_code
    response = client.post("/api/integrations/access/signup", json=payload)
    response.raise_for_status()
    return response.json()


def login_user(client: httpx.Client, *, email: str, password: str = "Synthetic-E2E-Pass-9876") -> dict:
    response = client.post("/api/integrations/access/login", json={"email": email, "password": password})
    response.raise_for_status()
    return response.json()


def install_audio_mock(page: Page) -> None:
    """Install synthetic AudioContext/MediaStream shims so macOS Chromium never stalls."""
    page.add_init_script(AUDIO_MOCK_INIT_SCRIPT)


def assert_no_horizontal_overflow(page: Page) -> None:
    metrics = page.evaluate(
        "() => ({ scrollWidth: document.documentElement.scrollWidth, clientWidth: document.documentElement.clientWidth })"
    )
    assert metrics["scrollWidth"] <= metrics["clientWidth"], (
        f"Horizontal overflow detected: scrollWidth={metrics['scrollWidth']} > clientWidth={metrics['clientWidth']}"
    )


def capture_screenshot(page: Page, screenshot_dir: Path, name: str, viewport_label: str) -> Path:
    safe_name = "".join(ch if ch.isalnum() or ch in {"-", "_"} else "_" for ch in name)
    output = screenshot_dir / f"{safe_name}_{viewport_label}.png"
    page.screenshot(path=str(output), full_page=True)
    assert output.is_file() and output.stat().st_size > 0
    return output
