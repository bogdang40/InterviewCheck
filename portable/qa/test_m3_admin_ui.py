"""Playwright E2E tests for M3 Model Admin Panel (/admin/), /account/ password rotation, and mobile drawer."""
from pathlib import Path
import re
import sys

import pytest
from playwright.sync_api import expect

QA_ROOT = Path(__file__).resolve().parent
if str(QA_ROOT) not in sys.path:
    sys.path.insert(0, str(QA_ROOT))

from e2e_suite.harness import (  # noqa: E402
    ConsoleErrorCollector,
    DESKTOP_VIEWPORT,
    IsolatedWorkspace,
    MOBILE_VIEWPORT,
    assert_no_horizontal_overflow,
    signup_user,
)

ADMIN_EMAIL = "admin-m3@example.test"
MEMBER_EMAIL = "member-m3@example.test"
BOOTSTRAP_SECRET = "m3-bootstrap-secret-1234"
ADMIN_PASS = "Synthetic-M3-Admin-Pass-1"
NEW_ADMIN_PASS = "Synthetic-M3-Admin-Pass-2"


@pytest.fixture
def m3_workspace(tmp_path, monkeypatch, frontend):
    ws = IsolatedWorkspace(tmp_path, monkeypatch, frontend)
    ws.prepare_env()
    ws.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    ws.start()
    try:
        yield ws
    finally:
        ws.stop()


@pytest.fixture(scope="module")
def m3_browser(qa_browser):
    return qa_browser


def _new_page(browser, viewport, *, mobile=False):
    ctx = browser.new_context(viewport=viewport, reduced_motion="reduce", is_mobile=mobile, has_touch=mobile)
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    page.set_default_navigation_timeout(30_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    return ctx, page, collector


def _bootstrap_users(ws: IsolatedWorkspace) -> None:
    with ws.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
    with ws.client() as c:
        signup_user(c, email=MEMBER_EMAIL, password="Synthetic-M3-Member-1")


def test_admin_unauthenticated_and_non_admin_gates_emit_zero_errors(tmp_path, monkeypatch, frontend, m3_browser):
    # 1. Local mode (access inactive)
    local_ws = IsolatedWorkspace(tmp_path / "local", monkeypatch, frontend)
    local_ws.prepare_env()
    local_ws.start()
    ctx, page, collector = _new_page(m3_browser, DESKTOP_VIEWPORT)
    try:
        resp = page.goto(local_ws.base_url + "/admin/", wait_until="domcontentloaded")
        assert resp is not None and resp.status == 200
        expect(page.get_by_role("heading", name="Account authentication inactive")).to_be_visible()
        assert_no_horizontal_overflow(page)
        collector.assert_clean()
    finally:
        ctx.close()
        local_ws.stop()

    # 2. Embedded auth mode: unauthenticated /admin/ and /account/
    auth_ws = IsolatedWorkspace(tmp_path / "auth", monkeypatch, frontend)
    auth_ws.prepare_env()
    auth_ws.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    auth_ws.start()
    _bootstrap_users(auth_ws)
    ctx2, page2, collector2 = _new_page(m3_browser, DESKTOP_VIEWPORT)
    try:
        page2.goto(auth_ws.base_url + "/admin/", wait_until="domcontentloaded")
        expect(page2.get_by_role("heading", name="Administrator sign in required")).to_be_visible()
        page2.goto(auth_ws.base_url + "/account/", wait_until="domcontentloaded")
        expect(page2.get_by_role("button", name="Sign in", exact=True)).to_be_visible()
        collector2.assert_clean()

        # Non-admin member signs in via /account/, then visits /admin/
        page2.get_by_label("Operator email").fill(MEMBER_EMAIL)
        page2.get_by_label("Password", exact=True).fill("Synthetic-M3-Member-1")
        page2.get_by_role("button", name="Sign in", exact=True).click()
        expect(page2.get_by_text(MEMBER_EMAIL)).to_be_visible()
        page2.goto(auth_ws.base_url + "/admin/", wait_until="domcontentloaded")
        expect(page2.get_by_role("heading", name="Administrator access required")).to_be_visible()
        collector2.assert_clean()
    finally:
        ctx2.close()
        auth_ws.stop()


def test_admin_models_crud_ssrf_probe_toggle_accounts_audit_and_password_rotation(m3_workspace, m3_browser):
    _bootstrap_users(m3_workspace)
    ctx, page, collector = _new_page(m3_browser, DESKTOP_VIEWPORT)
    secret_key = "sk-m3-synthetic-key-4321"
    try:
        # Sign in via /admin/
        page.goto(m3_workspace.base_url + "/admin/", wait_until="domcontentloaded")
        expect(page.get_by_role("heading", name="Administrator sign in required")).to_be_visible()
        page.get_by_label("Operator email").fill(ADMIN_EMAIL)
        page.get_by_label("Password", exact=True).fill(ADMIN_PASS)
        page.get_by_role("button", name="Sign in", exact=True).click()
        expect(page.get_by_role("heading", name="Model administration")).to_be_visible()
        expect(page.get_by_role("navigation", name="Workspace").get_by_role("link", name="Admin", exact=True)).to_be_visible()
        collector.assert_clean()

        # SSRF rejection (HTTP 400) leaves modal open and creates zero partial DB rows
        page.get_by_role("button", name="Connect model").first.click()
        dialog = page.get_by_role("dialog", name="Connect model")
        dialog.get_by_label("Provider").select_option("openai_compatible")
        dialog.get_by_label("Display name").fill("SSRF Probe Candidate")
        dialog.get_by_label("Model ID").fill("local-llm")
        dialog.get_by_label("Endpoint URL (HTTPS)").fill("https://127.0.0.1/v1")
        dialog.get_by_role("button", name="Save and connect").click()
        expect(dialog.get_by_role("alert")).to_be_visible()
        assert all("127.0.0.1" not in msg or "400" in msg for msg in collector.console_errors)
        collector.reset()

        # Create valid synthetic model
        dialog.get_by_label("Provider").select_option("openai")
        dialog.get_by_label("Display name").fill("Primary GPT-4o")
        dialog.get_by_label("Model ID").fill("gpt-4o")
        dialog.get_by_label("Slug (optional, auto-generated if blank)").fill("primary-gpt4o")
        dialog.get_by_label("API key").fill(secret_key)
        dialog.get_by_label("Temperature (0 to 2)").fill("0.3")
        dialog.get_by_label("Max tokens (1 to 128000)").fill("1024")
        dialog.get_by_label("Timeout seconds (1 to 180)").fill("2")
        dialog.get_by_role("button", name="Save and connect").click()
        expect(dialog).to_have_count(0)
        expect(page.get_by_text("Primary GPT-4o", exact=True)).to_be_visible()
        expect(page.get_by_text("...4321")).to_be_visible()
        assert secret_key not in page.content()

        # Reload persistence
        page.reload(wait_until="domcontentloaded")
        expect(page.get_by_text("Primary GPT-4o", exact=True)).to_be_visible()
        expect(page.get_by_text("...4321")).to_be_visible()
        collector.assert_clean()

        # Configure without apiKey preserves key_hint
        page.get_by_role("button", name="Configure").click()
        edit_dialog = page.get_by_role("dialog")
        edit_dialog.get_by_label("Display name").fill("Primary GPT-4o Updated")
        edit_dialog.get_by_role("button", name="Save configuration").click()
        expect(edit_dialog).to_have_count(0)
        expect(page.get_by_text("Primary GPT-4o Updated", exact=True)).to_be_visible()
        expect(page.get_by_text("...4321")).to_be_visible()

        # Probe fails gracefully (400/502/504) and updates status to error in-place
        page.get_by_role("button", name="Test connection").click()
        expect(page.get_by_text("error", exact=True).first).to_be_visible(timeout=12_000)
        assert not collector.page_errors
        collector.reset()

        # Toggle Disable -> Enable
        page.get_by_role("button", name="Disable").click()
        expect(page.get_by_text("disabled", exact=True).first).to_be_visible()
        page.get_by_role("button", name="Enable").click()
        expect(page.get_by_role("button", name="Disable")).to_be_visible()

        # Accounts tab: 409 self-disable protection
        page.get_by_role("tab", name="Accounts").click()
        admin_row = page.get_by_role("row").filter(has_text=ADMIN_EMAIL)
        admin_row.get_by_role("button", name="Manage").click()
        page.get_by_label("Disable account and revoke sessions").check()
        page.get_by_label(f"Confirm changes for {ADMIN_EMAIL}").check()
        page.get_by_role("button", name="Apply account changes").click()
        expect(page.get_by_role("alert").filter(has_text="cannot disable")).to_be_visible()
        assert not collector.page_errors
        collector.reset()

        # Audit log tab: displays admin.model.* events without 404
        page.get_by_role("tab", name="Audit log").click()
        expect(page.get_by_text("admin.model.create").first).to_be_visible()
        collector.assert_clean()

        # Disconnect model
        page.get_by_role("tab", name="Models").click()
        page.get_by_role("button", name="Disconnect").click()
        page.get_by_role("button", name="Confirm disconnect").click()
        expect(page.get_by_text("No models registered")).to_be_visible()
        collector.assert_clean()

        # /account/ link to /admin/ + Password rotation
        page.goto(m3_workspace.base_url + "/account/", wait_until="domcontentloaded")
        expect(page.get_by_role("link", name="Open model admin panel")).to_be_visible()
        expect(page.get_by_role("heading", name="Manage accounts")).to_be_visible()
        pw_form = page.get_by_role("form", name="Change password")
        pw_form.get_by_label("Current password").fill(ADMIN_PASS)
        pw_form.get_by_label("New password", exact=True).fill(NEW_ADMIN_PASS)
        pw_form.get_by_label("Confirm new password").fill(NEW_ADMIN_PASS)
        pw_form.get_by_role("button", name="Update password").click()
        expect(pw_form.get_by_role("status")).to_contain_text("Password updated")
        collector.assert_clean()

        # Verify new password works after sign out
        page.get_by_role("button", name="Sign out", exact=True).click()
        expect(page.get_by_label("Operator email")).to_be_visible()
        page.get_by_label("Operator email").fill(ADMIN_EMAIL)
        page.get_by_label("Password", exact=True).fill(NEW_ADMIN_PASS)
        page.get_by_role("button", name="Sign in", exact=True).click()
        expect(page.get_by_text(ADMIN_EMAIL)).to_be_visible()
        collector.assert_clean()
    finally:
        ctx.close()


def test_mobile_drawer_navigation_at_390x844(m3_workspace, m3_browser):
    _bootstrap_users(m3_workspace)
    ctx, page, collector = _new_page(m3_browser, MOBILE_VIEWPORT, mobile=True)
    try:
        page.goto(m3_workspace.base_url + "/account/", wait_until="domcontentloaded")
        page.get_by_label("Operator email").fill(ADMIN_EMAIL)
        page.get_by_label("Password", exact=True).fill(ADMIN_PASS)
        page.get_by_role("button", name="Sign in", exact=True).click()
        expect(page.get_by_text(ADMIN_EMAIL)).to_be_visible()
        assert_no_horizontal_overflow(page)

        # Open mobile drawer and verify all links + Sample review + Admin
        page.get_by_role("button", name="Open navigation menu").click()
        nav = page.get_by_role("navigation", name="Workspace")
        for label in ("Overview", "Interviews", "Role library", "Connections", "Data", "Admin"):
            expect(nav.get_by_role("link", name=label, exact=True)).to_be_visible()
        expect(page.get_by_role("link", name="Sample review", exact=True)).to_be_visible()

        nav.get_by_role("link", name="Admin", exact=True).click()
        expect(page).to_have_url(re.compile(r"/admin/?$"))
        expect(page.get_by_role("heading", name="Model administration")).to_be_visible()
        assert_no_horizontal_overflow(page)
        collector.assert_clean()
    finally:
        ctx.close()
