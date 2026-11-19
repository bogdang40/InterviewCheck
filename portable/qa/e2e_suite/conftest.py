"""Pytest fixtures and marker definitions for the opaque-box E2E test suite."""
from pathlib import Path
import sys

import pytest
from playwright.sync_api import sync_playwright

E2E_DIR = Path(__file__).resolve().parent
QA_DIR = E2E_DIR.parent
if str(QA_DIR) not in sys.path:
    sys.path.insert(0, str(QA_DIR))

from e2e_suite.harness import (  # noqa: E402
    ConsoleErrorCollector,
    DESKTOP_VIEWPORT,
    IsolatedWorkspace,
    MOBILE_VIEWPORT,
    PORTABLE_ROOT,
    load_parent_qa_conftest,
)


def pytest_configure(config):
    config.addinivalue_line("markers", "tier1: Tier 1 smoke and contract gate.")
    config.addinivalue_line("markers", "tier2: Tier 2 functional and security validation.")
    config.addinivalue_line("markers", "tier3: Tier 3 cross-viewport and persistence integrity.")
    config.addinivalue_line("markers", "tier4: Tier 4 real-world end-to-end scenarios.")
    config.addinivalue_line("markers", "m2_gated: Requires M2 security hardening changes.")
    config.addinivalue_line("markers", "m3_gated: Requires M3 UI redesign and /admin/ route.")


@pytest.fixture(scope="session")
def e2e_browser(request):
    if request.config.getoption("--frontend") == "static" and not (PORTABLE_ROOT / "web/out/index.html").is_file():
        pytest.fail("Build the UI with npm run build in portable/web before running static E2E tests.")
    parent_conftest = load_parent_qa_conftest()
    with sync_playwright() as playwright:
        browser = parent_conftest.launch_chromium(playwright)
        try:
            yield browser
        finally:
            browser.close()


@pytest.fixture
def e2e_workspace(tmp_path, monkeypatch, frontend):
    workspace = IsolatedWorkspace(tmp_path, monkeypatch, frontend)
    workspace.prepare_env()
    workspace.start()
    try:
        yield workspace
    finally:
        workspace.stop()


def _open_page(browser, viewport: dict[str, int], *, mobile: bool = False):
    context = browser.new_context(
        viewport=viewport,
        reduced_motion="reduce",
        is_mobile=mobile,
        has_touch=mobile,
    )
    page = context.new_page()
    page.set_default_timeout(8000)
    page.set_default_navigation_timeout(30_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    return context, page, collector


@pytest.fixture
def desktop_page(e2e_browser):
    context, page, collector = _open_page(e2e_browser, DESKTOP_VIEWPORT, mobile=False)
    try:
        yield page, collector
        collector.assert_clean()
    finally:
        context.close()


@pytest.fixture
def mobile_page(e2e_browser):
    context, page, collector = _open_page(e2e_browser, MOBILE_VIEWPORT, mobile=True)
    try:
        yield page, collector
        collector.assert_clean()
    finally:
        context.close()
