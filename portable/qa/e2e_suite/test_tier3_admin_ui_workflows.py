"""Tier 3 opaque-box browser /admin/ workflows and /account/ session rotation tests."""
import re

import pytest
from playwright.sync_api import expect

from e2e_suite.harness import (
    ConsoleErrorCollector,
    DESKTOP_VIEWPORT,
    assert_no_horizontal_overflow,
    signup_user,
)

ADMIN1_EMAIL = "admin1-t3@example.test"
MEMBER_EMAIL = "member-t3@example.test"
BOOTSTRAP_SECRET = "t3-admin-bootstrap-1234"
ADMIN_PASS = "Synthetic-T3-Admin-Pass-1"
NEW_ADMIN_PASS = "Synthetic-T3-Admin-Pass-2"
MEMBER_PASS = "Synthetic-T3-Member-Pass-1"


def _open_context(browser):
    ctx = browser.new_context(viewport=DESKTOP_VIEWPORT, reduced_motion="reduce")
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    page.set_default_navigation_timeout(30_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    return ctx, page, collector


def _sign_in_on_account(page, base_url: str, email: str, password: str) -> None:
    page.goto(base_url + "/account/", wait_until="domcontentloaded")
    page.get_by_label("Operator email").fill(email)
    page.get_by_label("Password", exact=True).fill(password)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(email)).to_be_visible()


def _sign_in_on_admin(page, base_url: str, email: str, password: str) -> None:
    page.goto(base_url + "/admin/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Administrator sign in required")).to_be_visible(timeout=15_000)
    page.get_by_label("Operator email").fill(email)
    page.get_by_label("Password", exact=True).fill(password)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_role("heading", name="Model administration")).to_be_visible(timeout=15_000)


@pytest.mark.tier3
def test_admin_gate_fails_closed_for_local_unauth_and_non_admin_browser_sessions(e2e_workspace, desktop_page):
    page, collector = desktop_page

    # 1. Local mode without access service active fails closed on /admin/.
    page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Account authentication inactive")).to_be_visible(timeout=15_000)
    assert_no_horizontal_overflow(page)
    page.goto(e2e_workspace.base_url + "/", wait_until="domcontentloaded")
    expect(page.get_by_role("navigation", name="Workspace").get_by_role("link", name="Admin", exact=True)).to_have_count(0)
    collector.assert_clean()

    # Unmount active page before restarting server in embedded auth mode.
    page.goto("about:blank")
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN1_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN1_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as c:
        signup_user(c, email=MEMBER_EMAIL, password=MEMBER_PASS)

    # Unauthenticated visitor sees administrator sign-in gate.
    page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Administrator sign in required")).to_be_visible(timeout=15_000)
    assert_no_horizontal_overflow(page)

    # Non-admin member sees access-denied gate and signs out cleanly.
    _sign_in_on_account(page, e2e_workspace.base_url, MEMBER_EMAIL, MEMBER_PASS)
    expect(page.get_by_role("navigation", name="Workspace").get_by_role("link", name="Admin", exact=True)).to_have_count(0)
    page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Administrator access required")).to_be_visible(timeout=15_000)
    page.get_by_role("button", name="Sign out", exact=True).click()
    expect(page.get_by_role("heading", name="Administrator sign in required")).to_be_visible(timeout=15_000)
    collector.assert_clean()


@pytest.mark.tier3
def test_admin_model_register_configure_rotate_probe_error_toggle_filter_and_disconnect(e2e_workspace, desktop_page):
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN1_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN1_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)

    page, collector = desktop_page
    _sign_in_on_admin(page, e2e_workspace.base_url, ADMIN1_EMAIL, ADMIN_PASS)

    key_initial = "sk-t3-initial-1111"
    key_rotated = "sk-t3-rotated-2222"
    key_anthropic = "sk-t3-anth-3333"

    # Register OpenAI reference model.
    page.get_by_role("button", name="Connect model").first.click()
    dlg = page.get_by_role("dialog", name="Connect model")
    dlg.get_by_label("Provider").select_option("openai")
    dlg.get_by_label("Display name").fill("Fleet OpenAI Ref")
    dlg.get_by_label("Model ID").fill("gpt-4o")
    dlg.get_by_label("Slug (optional, auto-generated if blank)").fill("fleet-openai-ref")
    dlg.get_by_label("API key").fill(key_initial)
    dlg.get_by_label("Timeout seconds (1 to 180)").fill("2")
    dlg.get_by_role("button", name="Save and connect").click()
    expect(dlg).to_have_count(0)
    expect(page.get_by_text("...1111")).to_be_visible()

    # Register Anthropic judge model.
    page.get_by_role("button", name="Connect model").first.click()
    dlg = page.get_by_role("dialog", name="Connect model")
    dlg.get_by_label("Provider").select_option("anthropic")
    dlg.get_by_role("combobox", name=re.compile(r"^Capability")).select_option("judge")
    dlg.get_by_label("Display name").fill("Fleet Claude Judge")
    dlg.get_by_label("Model ID").fill("claude-sonnet-4-6")
    dlg.get_by_label("API key").fill(key_anthropic)
    dlg.get_by_role("button", name="Save and connect").click()
    expect(dlg).to_have_count(0)

    # Filter controls narrow visible cards and clear cleanly.
    page.get_by_label("Provider filter").select_option("anthropic")
    expect(page.locator("article.admin-model-card")).to_have_count(1)
    expect(page.get_by_text("Fleet Claude Judge", exact=True)).to_be_visible()
    page.get_by_label("Provider filter").select_option("")
    page.get_by_label("Capability filter").select_option("reference")
    expect(page.locator("article.admin-model-card")).to_have_count(1)
    expect(page.get_by_text("Fleet OpenAI Ref", exact=True)).to_be_visible()
    page.get_by_label("Capability filter").select_option("")
    page.get_by_label("Search models").fill("Claude")
    expect(page.locator("article.admin-model-card")).to_have_count(1)
    page.get_by_label("Search models").fill("")
    expect(page.locator("article.admin-model-card")).to_have_count(2)

    # Configure without API key preserves existing encrypted key.
    openai_card = page.locator("article.admin-model-card", has_text="Fleet OpenAI Ref")
    openai_card.get_by_role("button", name="Configure").click()
    edit_dlg = page.get_by_role("dialog")
    edit_dlg.get_by_label("Display name").fill("Fleet OpenAI Ref v2")
    edit_dlg.get_by_role("button", name="Save configuration").click()
    expect(edit_dlg).to_have_count(0)
    openai_card = page.locator("article.admin-model-card", has_text="Fleet OpenAI Ref v2")
    expect(openai_card.get_by_text("...1111")).to_be_visible()

    # Rotate API key via Configure modal.
    openai_card.get_by_role("button", name="Configure").click()
    edit_dlg = page.get_by_role("dialog")
    edit_dlg.locator("input[type='password']").fill(key_rotated)
    edit_dlg.get_by_role("button", name="Save configuration").click()
    expect(edit_dlg).to_have_count(0)
    expect(openai_card.get_by_text("...2222")).to_be_visible()
    for secret in (key_initial, key_rotated, key_anthropic):
        assert secret not in page.content()

    # Probe failure surfaces explicit error banner + card error state without crashing.
    collector.ignore_server_5xx = True
    openai_card.get_by_role("button", name="Test connection").click()
    expect(openai_card.get_by_text("error", exact=True)).to_be_visible(timeout=12_000)
    expect(openai_card.get_by_role("alert")).to_be_visible()
    assert not collector.page_errors
    page.wait_for_timeout(150)
    collector.ignore_server_5xx = False
    collector.reset()

    # Toggle Disable -> Enable.
    openai_card.get_by_role("button", name="Disable").click()
    expect(openai_card.get_by_text("disabled", exact=True)).to_be_visible()
    openai_card.get_by_role("button", name="Enable").click()
    expect(openai_card.get_by_role("button", name="Disable")).to_be_visible()

    # Disconnect both models cleanly.
    for name in ("Fleet OpenAI Ref v2", "Fleet Claude Judge"):
        card = page.locator("article.admin-model-card", has_text=name)
        card.get_by_role("button", name="Disconnect").click()
        card.get_by_role("button", name="Confirm disconnect").click()
    expect(page.get_by_text("No models registered")).to_be_visible()
    collector.assert_clean()


@pytest.mark.tier3
def test_admin_accounts_role_promotion_disable_and_cross_context_token_revocation(e2e_workspace, e2e_browser):
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN1_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN1_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as c:
        signup_user(c, email=MEMBER_EMAIL, password=MEMBER_PASS)

    admin_ctx, admin_page, admin_collector = _open_context(e2e_browser)
    member_ctx, member_page, member_collector = _open_context(e2e_browser)
    try:
        _sign_in_on_admin(admin_page, e2e_workspace.base_url, ADMIN1_EMAIL, ADMIN_PASS)
        _sign_in_on_account(member_page, e2e_workspace.base_url, MEMBER_EMAIL, MEMBER_PASS)

        # Open Accounts tab and confirm self-disable 409 guard.
        admin_page.get_by_role("tab", name="Accounts").click()
        admin_row = admin_page.get_by_role("row").filter(has_text=ADMIN1_EMAIL)
        admin_row.get_by_role("button", name="Manage").click()
        admin_page.get_by_label("Disable account and revoke sessions").check()
        admin_page.get_by_label(f"Confirm changes for {ADMIN1_EMAIL}").check()
        admin_page.get_by_role("button", name="Apply account changes").click()
        expect(admin_page.get_by_role("alert").filter(has_text="cannot disable")).to_be_visible()
        assert not admin_collector.page_errors
        admin_page.wait_for_timeout(150)
        admin_collector.reset()

        # Promote member to administrator and verify member's prior session token is revoked.
        admin_page.get_by_label("Search accounts").fill(MEMBER_EMAIL)
        admin_page.get_by_role("button", name="Search", exact=True).click()
        expect(admin_page.get_by_role("tabpanel").locator("tbody tr")).to_have_count(1)
        member_row = admin_page.get_by_role("row").filter(has_text=MEMBER_EMAIL)
        member_row.get_by_role("button", name="Manage").click()
        expect(admin_page.get_by_role("heading", name=f"Edit {MEMBER_EMAIL}")).to_be_visible()
        admin_page.get_by_role("combobox", name=re.compile(r"^Role")).select_option("admin")
        admin_page.get_by_label(f"Confirm changes for {MEMBER_EMAIL}").check()
        admin_page.get_by_role("button", name="Apply account changes").click()
        expect(admin_page.get_by_role("status")).to_contain_text(f"Updated account {MEMBER_EMAIL}")

        # Member context reload should now be unauthenticated (token rotated/revoked on role change).
        member_page.goto(e2e_workspace.base_url + "/account/", wait_until="domcontentloaded")
        expect(member_page.get_by_role("button", name="Sign in", exact=True)).to_be_visible()
        member_page.wait_for_timeout(150)
        member_collector.reset()

        # Member signs in fresh and now accesses /admin/.
        _sign_in_on_admin(member_page, e2e_workspace.base_url, MEMBER_EMAIL, MEMBER_PASS)

        # Admin disables member account; member context session is immediately revoked.
        member_row = admin_page.get_by_role("row").filter(has_text=MEMBER_EMAIL)
        member_row.get_by_role("button", name="Manage").click()
        expect(admin_page.get_by_role("heading", name=f"Edit {MEMBER_EMAIL}")).to_be_visible()
        admin_page.get_by_label("Disable account and revoke sessions").check()
        admin_page.get_by_label(f"Confirm changes for {MEMBER_EMAIL}").check()
        admin_page.get_by_role("button", name="Apply account changes").click()
        expect(member_row.get_by_text("Disabled", exact=True)).to_be_visible()

        member_page.reload(wait_until="domcontentloaded")
        expect(member_page.get_by_role("heading", name="Administrator sign in required")).to_be_visible()
        member_page.get_by_label("Operator email").fill(MEMBER_EMAIL)
        member_page.get_by_label("Password", exact=True).fill(MEMBER_PASS)
        member_page.get_by_role("button", name="Sign in", exact=True).click()
        expect(member_page.get_by_role("alert").filter(has_text="disabled")).to_be_visible()

        admin_collector.assert_clean()
        assert not member_collector.page_errors
    finally:
        admin_ctx.close()
        member_ctx.close()


@pytest.mark.tier3
def test_admin_audit_log_tab_records_and_filters_model_and_account_events(e2e_workspace, desktop_page):
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN1_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN1_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)

    page, collector = desktop_page
    _sign_in_on_admin(page, e2e_workspace.base_url, ADMIN1_EMAIL, ADMIN_PASS)

    # Create, toggle, and disconnect a model to emit audit events.
    page.get_by_role("button", name="Connect model").first.click()
    dlg = page.get_by_role("dialog", name="Connect model")
    dlg.get_by_label("Provider").select_option("openai")
    dlg.get_by_label("Display name").fill("Audit Trail Model")
    dlg.get_by_label("Model ID").fill("gpt-4o")
    dlg.get_by_label("Slug (optional, auto-generated if blank)").fill("audit-trail-model")
    dlg.get_by_label("API key").fill("sk-audit-key-5555")
    dlg.get_by_role("button", name="Save and connect").click()
    expect(dlg).to_have_count(0)

    card = page.locator("article.admin-model-card", has_text="Audit Trail Model")
    card.get_by_role("button", name="Disable").click()
    expect(card.get_by_text("disabled", exact=True)).to_be_visible()
    card.get_by_role("button", name="Disconnect").click()
    card.get_by_role("button", name="Confirm disconnect").click()
    expect(page.get_by_text("No models registered")).to_be_visible()

    page.get_by_role("tab", name="Audit log").click()
    expect(page.get_by_text("admin.model.create").first).to_be_visible()
    expect(page.get_by_text("admin.model.toggle").first).to_be_visible()
    expect(page.get_by_text("admin.model.delete").first).to_be_visible()

    # Category and search filters work cleanly.
    page.get_by_label("Category").select_option("models")
    expect(page.get_by_text("auth.login")).to_have_count(0)
    page.get_by_label("Category").select_option("accounts")
    expect(page.get_by_text("auth.login").first).to_be_visible()
    expect(page.get_by_text("admin.model.create")).to_have_count(0)

    page.get_by_label("Category").select_option("all")
    page.get_by_label("Filter events").fill("audit-trail-model")
    expect(page.get_by_role("tabpanel").locator("tbody tr")).to_have_count(3)
    assert "sk-audit-key-5555" not in page.content()
    collector.assert_clean()


@pytest.mark.tier3
def test_account_password_rotation_revokes_other_browser_context_session(e2e_workspace, e2e_browser):
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN1_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN1_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)

    ctx_a, page_a, collector_a = _open_context(e2e_browser)
    ctx_b, page_b, collector_b = _open_context(e2e_browser)
    try:
        _sign_in_on_account(page_a, e2e_workspace.base_url, ADMIN1_EMAIL, ADMIN_PASS)
        _sign_in_on_account(page_b, e2e_workspace.base_url, ADMIN1_EMAIL, ADMIN_PASS)

        # Rotate password in context A.
        pw_form = page_a.get_by_role("form", name="Change password")
        pw_form.get_by_label("Current password").fill(ADMIN_PASS)
        pw_form.get_by_label("New password", exact=True).fill(NEW_ADMIN_PASS)
        pw_form.get_by_label("Confirm new password").fill(NEW_ADMIN_PASS)
        pw_form.get_by_role("button", name="Update password").click()
        expect(pw_form.get_by_role("status")).to_contain_text("Password updated and session rotated.")

        # Context A keeps an active rotated session.
        page_a.get_by_role("button", name="Refresh access").click()
        expect(page_a.get_by_text(ADMIN1_EMAIL)).to_be_visible()
        collector_a.assert_clean()

        # Context B's old session cookie was revoked.
        page_b.goto(e2e_workspace.base_url + "/account/", wait_until="networkidle")
        expect(page_b.get_by_role("button", name="Sign in", exact=True)).to_be_visible()
        collector_b.reset()

        # Old password fails in context B; new password succeeds.
        page_b.get_by_label("Operator email").fill(ADMIN1_EMAIL)
        page_b.get_by_label("Password", exact=True).fill(ADMIN_PASS)
        with page_b.expect_console_message(lambda m: m.type == "error" and "401" in m.text):
            page_b.get_by_role("button", name="Sign in", exact=True).click()
        expect(page_b.locator("main").get_by_role("alert")).to_be_visible()
        assert collector_b.console_errors and all("401" in msg for msg in collector_b.console_errors), collector_b.console_errors
        collector_b.reset()

        page_b.get_by_label("Password", exact=True).fill(NEW_ADMIN_PASS)
        page_b.get_by_role("button", name="Sign in", exact=True).click()
        expect(page_b.get_by_text(ADMIN1_EMAIL)).to_be_visible()
        collector_b.assert_clean()
    finally:
        ctx_a.close()
        ctx_b.close()
