"""Start the released browser app with an empty database for each scenario."""
import os
from pathlib import Path
import socket
import threading
import time

import pytest
from playwright.sync_api import Error as PlaywrightError, sync_playwright
import uvicorn

from next_frontend import can_bind, free_port, manifest_api_port, serve_next

BROWSER_ARGS = ["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream"]


def resolve_start_api_port(web, env=None):
    env = os.environ if env is None else env
    explicit = env.get("INTERVIEWCHECK_API_PORT")
    if explicit:
        return int(explicit)
    built_dist = web / ".next-server"
    if (built_dist / "BUILD_ID").is_file():
        built_port = manifest_api_port(built_dist)
        if built_port and can_bind(built_port):
            return built_port
    return free_port()


def launch_chromium(playwright, env=None):
    env = os.environ if env is None else env
    channel = env.get("INTERVIEWCHECK_BROWSER_CHANNEL") or None
    try:
        return playwright.chromium.launch(channel=channel, args=BROWSER_ARGS)
    except PlaywrightError as error:
        if channel is not None or "Executable doesn't exist" not in str(error):
            raise
        return playwright.chromium.launch(channel="chrome", args=BROWSER_ARGS)


def pytest_addoption(parser):
    parser.addoption("--frontend", choices=["static", "dev", "start"], default="static",
                     help="Serve the portable export, Next dev, or the production Next server.")


@pytest.fixture(scope="session")
def frontend(request, tmp_path_factory):
    mode = request.config.getoption("--frontend")
    if mode == "static":
        yield None, None, 0
        return
    web = Path(__file__).resolve().parents[1] / "web"
    # Next embeds the rewrite destination during its production build.
    api_port = resolve_start_api_port(web) if mode == "start" else free_port()
    with serve_next(web, mode, api_port, tmp_path_factory.mktemp("next") / "server.log") as (base, port):
        yield base, port, api_port


@pytest.fixture
def workspace_url(tmp_path, monkeypatch, frontend):
    root = Path(__file__).resolve().parents[1]
    public_url, web_port, api_port = frontend
    # This fixture has no authority to use credentials present on a developer workstation.
    for key in ("INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_OPERATOR_EMAIL",
                "INTERVIEWCHECK_WEB_PORT", "DEEPGRAM_API_KEY", "OPENAI_API_KEY",
                "ASHBY_API_KEY", "LEVER_API_KEY", "MERGE_API_KEY", "GREENHOUSE_CLIENT_ID",
                "GOOGLE_CALENDAR_ACCESS_TOKEN", "MS_GRAPH_ACCESS_TOKEN", "ZOOM_ACCESS_TOKEN",
                "WEBEX_ACCESS_TOKEN", "ANTHROPIC_API_KEY", "AZURE_OPENAI_API_KEY",
                "CALENDLY_TOKEN", "CALCOM_API_KEY"):
        monkeypatch.delenv(key, raising=False)
    if web_port:
        monkeypatch.setenv("INTERVIEWCHECK_WEB_PORT", str(web_port))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "accounts.sqlite"))
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "workspace.sqlite"))
    monkeypatch.syspath_prepend(str(root))
    monkeypatch.chdir(root)
    from api.main import app

    with socket.create_server(("127.0.0.1", api_port)) as listener:
        port = listener.getsockname()[1]
        # Keep idle loopback sockets open longer than Next.js httpxy pooling to avoid 5s close races on Windows.
        server = uvicorn.Server(uvicorn.Config(app, access_log=False, log_level="warning", timeout_keep_alive=300))
        thread = threading.Thread(target=server.run, kwargs={"sockets": [listener]}, daemon=True)
        thread.start()
        try:
            deadline = time.monotonic() + 15
            while not server.started:
                if not thread.is_alive() or time.monotonic() >= deadline:
                    pytest.fail("FastAPI did not start within 15 seconds.")
                time.sleep(0.05)
            yield public_url or f"http://127.0.0.1:{port}"
        finally:
            server.should_exit = True
            thread.join(timeout=10)
            assert not thread.is_alive(), "FastAPI did not stop"


@pytest.fixture(scope="session")
def qa_browser(request):
    root = Path(__file__).resolve().parents[1]
    if request.config.getoption("--frontend") == "static" and not (root / "web/out/index.html").is_file():
        pytest.fail("Build the UI with npm run build in portable/web before running browser tests.")
    with sync_playwright() as playwright:
        browser = launch_chromium(playwright)
        try:
            yield browser
        finally:
            browser.close()


@pytest.fixture
def browser_page(qa_browser):
    context = qa_browser.new_context(
        viewport={"width": 1440, "height": 960},
        reduced_motion="reduce",
    )
    page = context.new_page()
    page.set_default_timeout(7000)
    page.set_default_navigation_timeout(30_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    try:
        yield page
        assert not errors, f"Browser runtime errors: {errors}"
    finally:
        context.close()
