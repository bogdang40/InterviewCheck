"""Start the released browser app with an empty database for each scenario."""
import os
from pathlib import Path
import socket
import threading
import time

import pytest
from playwright.sync_api import sync_playwright
import uvicorn


@pytest.fixture
def workspace_url(tmp_path, monkeypatch):
    root = Path(__file__).resolve().parents[1]
    # This fixture has no authority to use credentials present on a developer workstation.
    for key in ("INTERVIEWCHECK_ACCESS_URL", "DEEPGRAM_API_KEY", "OPENAI_API_KEY",
                "ASHBY_API_KEY", "LEVER_API_KEY", "MERGE_API_KEY", "GREENHOUSE_CLIENT_ID",
                "GOOGLE_CALENDAR_ACCESS_TOKEN", "MS_GRAPH_ACCESS_TOKEN", "ZOOM_ACCESS_TOKEN",
                "WEBEX_ACCESS_TOKEN", "ANTHROPIC_API_KEY", "AZURE_OPENAI_API_KEY",
                "CALENDLY_TOKEN", "CALCOM_API_KEY"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "workspace.sqlite"))
    monkeypatch.syspath_prepend(str(root))
    monkeypatch.chdir(root)
    from api.main import app

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
        server = uvicorn.Server(uvicorn.Config(app, access_log=False, log_level="warning"))
        thread = threading.Thread(target=server.run, kwargs={"sockets": [listener]}, daemon=True)
        thread.start()
        try:
            deadline = time.monotonic() + 15
            while not server.started:
                if not thread.is_alive() or time.monotonic() >= deadline:
                    pytest.fail("FastAPI did not start within 15 seconds.")
                time.sleep(0.05)
            yield f"http://127.0.0.1:{port}"
        finally:
            server.should_exit = True
            thread.join(timeout=10)
            assert not thread.is_alive(), "FastAPI did not stop"


@pytest.fixture
def browser_page():
    root = Path(__file__).resolve().parents[1]
    if not (root / "web/out/index.html").is_file():
        pytest.fail("Build the UI with npm run build in portable/web before running browser tests.")
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            channel=os.getenv("INTERVIEWCHECK_BROWSER_CHANNEL") or None,
            args=["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream"],
        )
        context = browser.new_context(
            viewport={"width": 1440, "height": 960},
            reduced_motion="reduce",
        )
        page = context.new_page()
        page.set_default_timeout(7000)
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        try:
            yield page
            assert not errors, f"Browser runtime errors: {errors}"
        finally:
            context.close()
            browser.close()
