"""Tier 5 adversarial Playwright UI tests: T5-01 default sync, T5-13 focus trap, and T5-12 revocation/accounts."""
import re
import sqlite3
import time
from uuid import uuid4

from playwright.sync_api import expect
import pytest

from e2e_suite.harness import (
    ConsoleErrorCollector,
    DESKTOP_VIEWPORT,
    MOBILE_VIEWPORT,
    assert_no_horizontal_overflow,
    signup_user,
)

ADMIN1_EMAIL = "admin1-t5@example.test"
ADMIN2_EMAIL = "admin2-t5@example.test"
ADMIN3_EMAIL = "admin3-t5@example.test"
MEMBER_EMAIL = "member-t5@example.test"
BOOTSTRAP_SECRET = "t5-bootstrap-secret-1234"
ADMIN1_PASS = "Synthetic-T5-Admin1-Pass"
ADMIN2_PASS = "Synthetic-T5-Admin2-Pass"
ADMIN3_PASS = "Synthetic-T5-Admin3-Pass"
ADMIN3_NEW_PASS = "Synthetic-T5-Admin3-NewPass"
MEMBER_PASS = "Synthetic-T5-Member-Pass"


def _open_context(browser, *, mobile: bool = False):
    viewport = MOBILE_VIEWPORT if mobile else DESKTOP_VIEWPORT
    ctx = browser.new_context(viewport=viewport, reduced_motion="reduce", is_mobile=mobile, has_touch=mobile)
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    page.set_default_navigation_timeout(30_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    return ctx, page, collector


def _sign_in_admin(page, base_url: str, email: str, password: str) -> None:
    page.goto(base_url + "/admin/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Administrator sign in required")).to_be_visible()
    page.get_by_label("Operator email").fill(email)
    page.get_by_label("Password", exact=True).fill(password)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_role("heading", name="Model administration")).to_be_visible()


def _connect_model(
    page,
    *,
    provider: str,
    capability: str,
    display_name: str,
    model_id: str,
    slug: str,
    api_key: str,
    is_default: bool = False,
) -> None:
    page.get_by_role("button", name="Connect model").first.click()
    dlg = page.get_by_role("dialog", name="Connect model")
    dlg.get_by_label("Provider").select_option(provider)
    dlg.get_by_role("combobox", name=re.compile(r"^Capability")).select_option(capability)
    dlg.get_by_label("Display name").fill(display_name)
    dlg.get_by_label("Model ID").fill(model_id)
    dlg.get_by_label("Slug (optional, auto-generated if blank)").fill(slug)
    dlg.get_by_label("API key").fill(api_key)
    if is_default:
        dlg.get_by_label("Default for capability").check()
    dlg.get_by_role("button", name="Save and connect").click()
    expect(dlg).to_have_count(0)


def _active_in_dialog(page) -> dict:
    return page.evaluate(
        """() => {
          const dlg = document.querySelector('[role="dialog"]');
          const el = document.activeElement;
          return {
            inDialog: Boolean(dlg && el && dlg.contains(el)),
            label: el ? (el.getAttribute('aria-label') || el.textContent || el.getAttribute('type') || '').trim() : '',
          };
        }"""
    )


def _seed_member_rows(access_db, count: int) -> None:
    now_ms = int(time.time() * 1000) - 60_000
    with sqlite3.connect(access_db) as conn:
        for i in range(count):
            ts = now_ms - i * 1000
            conn.execute(
                """INSERT INTO users(id,email,password_hash,role,disabled,trial_ends_at,
                   complimentary_until,created_at,updated_at,last_login_at)
                   VALUES(?,?,?,'user',0,NULL,NULL,?,?,NULL)""",
                (str(uuid4()), f"paged-user-{i:02d}@example.test", "scrypt$32768$8$1$x$y", ts, ts),
            )
        conn.commit()


def test_t5_01_admin_is_default_sibling_badge_sync_without_reload(e2e_workspace, desktop_page):
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN1_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN1_EMAIL, password=ADMIN1_PASS, admin_secret=BOOTSTRAP_SECRET)

    page, collector = desktop_page
    _sign_in_admin(page, e2e_workspace.base_url, ADMIN1_EMAIL, ADMIN1_PASS)

    _connect_model(
        page, provider="openai", capability="reference", display_name="Default Sync A",
        model_id="gpt-4o", slug="default-sync-a", api_key="sk-t501-aaa-1111", is_default=True,
    )
    card_a = page.locator("article.admin-model-card", has_text="Default Sync A")
    expect(card_a.get_by_text("Default", exact=True)).to_be_visible()
    expect(page.get_by_text("1 default slots")).to_be_visible()

    # Create model B with is_default=True for same capability; verify sync WITHOUT page reload.
    _connect_model(
        page, provider="anthropic", capability="reference", display_name="Default Sync B",
        model_id="claude-sonnet-4-6", slug="default-sync-b", api_key="sk-t501-bbb-2222", is_default=True,
    )
    card_b = page.locator("article.admin-model-card", has_text="Default Sync B")
    expect(card_b.get_by_text("Default", exact=True)).to_be_visible()
    expect(card_a.get_by_text("Default", exact=True)).to_have_count(0)
    expect(page.get_by_text("1 default slots")).to_be_visible()

    # Connect default for a different capability (judge) to verify sibling clearing is capability-scoped.
    _connect_model(
        page, provider="openai", capability="judge", display_name="Judge Default C",
        model_id="gpt-4o-mini", slug="default-sync-c", api_key="sk-t501-ccc-3333", is_default=True,
    )
    card_c = page.locator("article.admin-model-card", has_text="Judge Default C")
    expect(card_c.get_by_text("Default", exact=True)).to_be_visible()
    expect(page.get_by_text("2 default slots")).to_be_visible()

    # Edit model A back to is_default=True; verify model B clears WITHOUT page reload.
    card_a.get_by_role("button", name="Configure").click()
    edit_dlg = page.get_by_role("dialog")
    edit_dlg.get_by_label("Default for capability").check()
    edit_dlg.get_by_role("button", name="Save configuration").click()
    expect(edit_dlg).to_have_count(0)
    expect(card_a.get_by_text("Default", exact=True)).to_be_visible()
    expect(card_b.get_by_text("Default", exact=True)).to_have_count(0)
    expect(card_c.get_by_text("Default", exact=True)).to_be_visible()
    expect(page.get_by_text("2 default slots")).to_be_visible()

    # Confirm persistence after reload.
    page.reload(wait_until="domcontentloaded")
    expect(card_a.get_by_text("Default", exact=True)).to_be_visible()
    expect(card_b.get_by_text("Default", exact=True)).to_have_count(0)
    expect(card_c.get_by_text("Default", exact=True)).to_be_visible()
    expect(page.get_by_text("2 default slots")).to_be_visible()
    collector.assert_clean()


@pytest.mark.parametrize("mobile", [False, True], ids=["desktop-1440", "mobile-390"])
def test_t5_13_modal_focus_trap_and_trigger_restoration(e2e_workspace, e2e_browser, mobile):
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN1_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN1_EMAIL, password=ADMIN1_PASS, admin_secret=BOOTSTRAP_SECRET)

    ctx, page, collector = _open_context(e2e_browser, mobile=mobile)
    try:
        _sign_in_admin(page, e2e_workspace.base_url, ADMIN1_EMAIL, ADMIN1_PASS)
        assert_no_horizontal_overflow(page)

        connect_trigger = page.locator("header.admin-header").get_by_role("button", name="Connect model")
        connect_trigger.focus()
        connect_trigger.click()

        dlg = page.get_by_role("dialog", name="Connect model")
        expect(dlg).to_be_visible()
        assert _active_in_dialog(page)["inDialog"] is True

        seen_labels = []
        for _ in range(25):
            page.keyboard.press("Tab")
            state = _active_in_dialog(page)
            assert state["inDialog"] is True, f"Focus escaped dialog on Tab: {state}"
            seen_labels.append(state["label"])
        assert len(set(seen_labels)) >= 8

        dlg.get_by_role("button", name="Close modal").focus()
        page.keyboard.press("Shift+Tab")
        wrapped = _active_in_dialog(page)
        assert wrapped["inDialog"] is True and "Cancel" in wrapped["label"]

        # Escape, X, and Cancel each restore focus to the triggering button.
        page.keyboard.press("Escape")
        expect(dlg).to_have_count(0)
        assert page.evaluate("() => document.activeElement?.textContent?.includes('Connect model')") is True

        connect_trigger.click()
        dlg.get_by_role("button", name="Close modal").click()
        expect(dlg).to_have_count(0)
        assert page.evaluate("() => document.activeElement?.textContent?.includes('Connect model')") is True

        connect_trigger.click()
        dlg.get_by_role("button", name="Cancel").click()
        expect(dlg).to_have_count(0)
        assert page.evaluate("() => document.activeElement?.textContent?.includes('Connect model')") is True

        # Configure -> backdrop click restores focus to the card's Configure button.
        _connect_model(
            page, provider="openai", capability="reference", display_name="Focus Restore Target",
            model_id="gpt-4o", slug="focus-restore-target", api_key="sk-focus-1111",
        )
        card = page.locator("article.admin-model-card", has_text="Focus Restore Target")
        card.get_by_role("button", name="Configure").click()
        edit_dlg = page.get_by_role("dialog")
        expect(edit_dlg).to_be_visible()
        assert _active_in_dialog(page)["inDialog"] is True

        page.locator(".admin-modal-backdrop").click(position={"x": 4, "y": 4})
        expect(edit_dlg).to_have_count(0)
        focused_cfg = card.evaluate(
            "(el) => document.activeElement === Array.from(el.querySelectorAll('button')).find((b) => b.textContent?.includes('Configure'))"
        )
        assert focused_cfg is True
        collector.assert_clean()
    finally:
        ctx.close()


def _open_tab(ctx):
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    page.set_default_navigation_timeout(30_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    return page, collector


def test_t5_12_mid_session_auth_revocation_transitions_to_admin_gate(e2e_workspace, e2e_browser):
    e2e_workspace.configure_embedded_auth(
        admin_emails=(ADMIN1_EMAIL, ADMIN2_EMAIL, ADMIN3_EMAIL), bootstrap_secret=BOOTSTRAP_SECRET,
    )
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN1_EMAIL, password=ADMIN1_PASS, admin_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN2_EMAIL, password=ADMIN2_PASS, admin_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN3_EMAIL, password=ADMIN3_PASS, admin_secret=BOOTSTRAP_SECRET)

    ctx2, p_probe, col1 = _open_context(e2e_browser)
    ctx3, p_accounts, col4 = _open_context(e2e_browser)
    try:
        # 1 login for admin2 shared across Probe, Toggle, Delete tabs; 1 login for admin3 across Accounts, Audit tabs.
        _sign_in_admin(p_probe, e2e_workspace.base_url, ADMIN2_EMAIL, ADMIN2_PASS)
        p_toggle, col2 = _open_tab(ctx2)
        p_delete, col3 = _open_tab(ctx2)
        _sign_in_admin(p_accounts, e2e_workspace.base_url, ADMIN3_EMAIL, ADMIN3_PASS)
        p_audit, col5 = _open_tab(ctx3)

        with e2e_workspace.client() as admin1_api:
            admin1_api.post("/api/integrations/access/login", json={"email": ADMIN1_EMAIL, "password": ADMIN1_PASS}).raise_for_status()
            admin1_api.post(
                "/api/admin/models",
                json={
                    "slug": "revocation-target", "display_name": "Revocation Target",
                    "provider": "openai", "capability": "reference", "model_id": "gpt-4o", "apiKey": "sk-rev-1111",
                },
            ).raise_for_status()
            admin2_id = admin1_api.get(f"/api/integrations/admin/users?q={ADMIN2_EMAIL}").json()["users"][0]["user"]["id"]

            for p in (p_probe, p_toggle, p_delete):
                p.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
                expect(p.locator("article.admin-model-card", has_text="Revocation Target")).to_be_visible()

            p_accounts.get_by_role("tab", name="Accounts").click()
            expect(p_accounts.get_by_role("heading", name="Account directory")).to_be_visible()
            p_audit.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
            p_audit.get_by_role("tab", name="Audit log").click()
            expect(p_audit.get_by_role("heading", name="Audit log")).to_be_visible()

            # Demote admin2 and rotate admin3 password from separate sessions.
            assert admin1_api.patch(f"/api/integrations/admin/users/{admin2_id}", json={"role": "user"}).status_code == 200
        with e2e_workspace.client() as admin3_api:
            admin3_api.post("/api/integrations/access/login", json={"email": ADMIN3_EMAIL, "password": ADMIN3_PASS}).raise_for_status()
            assert admin3_api.post(
                "/api/integrations/access/password",
                json={"currentPassword": ADMIN3_PASS, "newPassword": ADMIN3_NEW_PASS},
            ).status_code == 200

        p_probe.locator("article.admin-model-card", has_text="Revocation Target").get_by_role("button", name="Test connection").click()
        p_toggle.locator("article.admin-model-card", has_text="Revocation Target").get_by_role("button", name="Disable").click()
        del_card = p_delete.locator("article.admin-model-card", has_text="Revocation Target")
        del_card.get_by_role("button", name="Disconnect").click()
        del_card.get_by_role("button", name="Confirm disconnect").click()
        p_accounts.get_by_role("button", name="Search", exact=True).click()
        p_audit.get_by_role("region", name="Audit log").get_by_role("button", name="Refresh").click()

        for p, col in ((p_probe, col1), (p_toggle, col2), (p_delete, col3), (p_accounts, col4), (p_audit, col5)):
            expect(p.get_by_role("heading", name="Administrator sign in required")).to_be_visible()
            expect(p.locator("p[role='alert']")).to_contain_text("Session expired")
            assert not col.page_errors and not col.server_errors
            p.wait_for_timeout(100)
            assert all("401" in msg for msg in col.console_errors), col.console_errors
    finally:
        ctx2.close()
        ctx3.close()


def test_t5_12_accounts_tab_pagination_complimentary_close_and_last_admin_guard(e2e_workspace, desktop_page):
    e2e_workspace.configure_embedded_auth(
        admin_emails=(ADMIN1_EMAIL, ADMIN2_EMAIL), bootstrap_secret=BOOTSTRAP_SECRET, trial_days="0",
    )
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN1_EMAIL, password=ADMIN1_PASS, admin_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN2_EMAIL, password=ADMIN2_PASS, admin_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as c:
        signup_user(c, email=MEMBER_EMAIL, password=MEMBER_PASS)
    _seed_member_rows(e2e_workspace.access_db, 26)

    page, collector = desktop_page
    _sign_in_admin(page, e2e_workspace.base_url, ADMIN1_EMAIL, ADMIN1_PASS)
    page.get_by_role("tab", name="Accounts").click()

    expect(page.locator("tbody tr")).to_have_count(25)
    load_more = page.get_by_role("button", name="Load more")
    expect(load_more).to_be_visible()
    load_more.click()
    expect(page.locator("tbody tr")).to_have_count(29)
    expect(load_more).to_have_count(0)

    page.get_by_label("Search accounts").fill(MEMBER_EMAIL)
    page.get_by_role("button", name="Search", exact=True).click()
    expect(page.locator("tbody tr")).to_have_count(1)
    member_row = page.get_by_role("row").filter(has_text=MEMBER_EMAIL)
    expect(member_row.get_by_text("Inactive", exact=True)).to_be_visible()

    member_row.get_by_role("button", name="Manage").click()
    expect(page.get_by_role("heading", name=f"Edit {MEMBER_EMAIL}")).to_be_visible()
    page.get_by_label("Complimentary access through (UTC)").fill("2099-12-31")
    page.get_by_label(f"Confirm changes for {MEMBER_EMAIL}").check()
    page.get_by_role("button", name="Apply account changes").click()
    expect(page.get_by_role("status")).to_contain_text(f"Updated account {MEMBER_EMAIL}")
    expect(member_row.get_by_text("Active", exact=True)).to_be_visible()
    expect(member_row.get_by_text("complimentary", exact=True)).to_be_visible()

    page.get_by_label("Complimentary access through (UTC)").fill("")
    page.get_by_label(f"Confirm changes for {MEMBER_EMAIL}").check()
    page.get_by_role("button", name="Apply account changes").click()
    expect(member_row.get_by_text("Inactive", exact=True)).to_be_visible()
    expect(member_row.get_by_text("none", exact=True)).to_be_visible()

    page.get_by_role("button", name="Close", exact=True).click()
    expect(page.get_by_role("heading", name=f"Edit {MEMBER_EMAIL}")).to_have_count(0)

    page.get_by_label("Search accounts").fill("admin")
    page.get_by_role("button", name="Search", exact=True).click()
    admin2_row = page.get_by_role("row").filter(has_text=ADMIN2_EMAIL)
    admin2_row.get_by_role("button", name="Manage").click()
    page.get_by_role("combobox", name=re.compile(r"^Role")).select_option("user")
    page.get_by_label(f"Confirm changes for {ADMIN2_EMAIL}").check()
    page.get_by_role("button", name="Apply account changes").click()
    expect(admin2_row.get_by_text("user", exact=True)).to_be_visible()

    admin1_row = page.get_by_role("row").filter(has_text=ADMIN1_EMAIL)
    admin1_row.get_by_role("button", name="Manage").click()
    page.get_by_role("combobox", name=re.compile(r"^Role")).select_option("user")
    page.get_by_label(f"Confirm changes for {ADMIN1_EMAIL}").check()
    page.get_by_role("button", name="Apply account changes").click()
    expect(page.locator("p[role='alert']")).to_contain_text("Keep at least one active administrator.")
    expect(admin1_row.locator("span[data-slot='badge']", has_text="admin")).to_be_visible()

    assert not collector.page_errors and not collector.server_errors
    page.wait_for_timeout(150)
    assert all("409" in msg for msg in collector.console_errors), collector.console_errors
    collector.reset()
    collector.assert_clean()
