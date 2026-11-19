"""Playwright E2E tests for M7 WCAG AA keyboard navigation, focus traps, and mobile 320/390 layout."""
import re

from playwright.sync_api import expect
import pytest

from e2e_suite.harness import (
    ConsoleErrorCollector,
    assert_no_horizontal_overflow,
    login_user,
    signup_user,
)

ADMIN_EMAIL = "admin-m7-a11y@example.test"
BOOTSTRAP_SECRET = "m7-a11y-bootstrap-secret-1234"
ADMIN_PASS = "Synthetic-M7-A11y-Pass-1"

ALL_ROUTES = (
    "/",
    "/interviews/",
    "/interviews/new/",
    "/interviews/review/",
    "/interviews/brief/",
    "/roles/",
    "/connections/",
    "/data/",
    "/account/",
    "/sample/",
    "/trash/",
    "/admin/",
)


def _setup_admin(e2e_workspace) -> None:
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)


def _sign_in_account(page, base_url: str) -> None:
    page.goto(base_url + "/account/", wait_until="domcontentloaded")
    page.get_by_label("Operator email").fill(ADMIN_EMAIL)
    page.get_by_label("Password", exact=True).fill(ADMIN_PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(ADMIN_EMAIL)).to_be_visible()


def _open_viewport_page(e2e_browser, width: int, height: int):
    mobile = width <= 480
    ctx = e2e_browser.new_context(
        viewport={"width": width, "height": height},
        reduced_motion="reduce",
        is_mobile=mobile,
        has_touch=mobile,
    )
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    page.set_default_navigation_timeout(30_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    return ctx, page, collector


def _active_inside(page, selector: str) -> bool:
    return page.evaluate(
        """(sel) => {
          const root = document.querySelector(sel);
          return Boolean(root && document.activeElement && root.contains(document.activeElement));
        }""",
        selector,
    )


def test_m7_admin_tablist_modal_and_health_drawer_keyboard_focus(e2e_workspace, desktop_page):
    _setup_admin(e2e_workspace)
    with e2e_workspace.client() as c:
        login_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS)
        c.post(
            "/api/admin/models",
            json={
                "slug": "a11y-model",
                "display_name": "A11y Test Model",
                "provider": "openai",
                "capability": "reference",
                "model_id": "gpt-4o",
                "apiKey": "sk-a11y-1111",
            },
        ).raise_for_status()

    page, collector = desktop_page
    _sign_in_account(page, e2e_workspace.base_url)
    page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Model administration")).to_be_visible()

    # AdminConsole WAI-ARIA tablist: aria-controls, id="panel-*", roving tabIndex, Arrow/Home/End keys.
    tablist = page.get_by_role("tablist", name="Admin sections")
    tabs = tablist.get_by_role("tab")
    expect(tabs.first).to_be_visible()
    tab_count = tabs.count()
    assert tab_count >= 3
    for label, panel_id in (
        ("Models", "panel-models"),
        ("Accounts", "panel-accounts"),
        ("Audit log", "panel-audit"),
        ("Diagnostics", "panel-diagnostics"),
    ):
        expect(tablist.get_by_role("tab", name=label)).to_have_attribute("aria-controls", panel_id)

    models_tab = tabs.nth(0)
    last_tab = tabs.nth(tab_count - 1)
    expect(models_tab).to_have_attribute("tabindex", "0")
    for idx in range(1, tab_count):
        expect(tabs.nth(idx)).to_have_attribute("tabindex", "-1")
    expect(page.locator("#panel-models[role='tabpanel']")).to_be_visible()

    models_tab.focus()
    for idx in range(1, tab_count):
        page.keyboard.press("ArrowRight")
        current_tab = tabs.nth(idx)
        expect(current_tab).to_be_focused()
        expect(current_tab).to_have_attribute("aria-selected", "true")
        expect(current_tab).to_have_attribute("tabindex", "0")
        expect(tabs.nth(idx - 1)).to_have_attribute("tabindex", "-1")
        panel_id = current_tab.get_attribute("aria-controls")
        assert panel_id
        expect(page.locator(f"#{panel_id}[role='tabpanel']")).to_be_visible()

    page.keyboard.press("ArrowRight")
    expect(models_tab).to_be_focused()
    expect(models_tab).to_have_attribute("aria-selected", "true")

    page.keyboard.press("End")
    expect(last_tab).to_be_focused()
    expect(last_tab).to_have_attribute("aria-selected", "true")
    page.keyboard.press("Home")
    expect(models_tab).to_be_focused()
    page.keyboard.press("ArrowLeft")
    expect(last_tab).to_be_focused()
    page.keyboard.press("Home")
    expect(page.locator("#panel-models[role='tabpanel']")).to_be_visible()

    # ModelFormModal focus trap (Tab/Shift+Tab) and Escape focus restoration.
    connect_btn = page.locator("header.admin-header").get_by_role("button", name="Connect model")
    connect_btn.focus()
    page.keyboard.press("Enter")
    modal = page.get_by_role("dialog", name="Connect model")
    expect(modal).to_be_visible()
    assert _active_inside(page, '[role="dialog"]') is True
    for _ in range(20):
        page.keyboard.press("Tab")
        assert _active_inside(page, '[role="dialog"]') is True
    modal.get_by_role("button", name="Close modal").focus()
    page.keyboard.press("Shift+Tab")
    assert _active_inside(page, '[role="dialog"]') is True
    assert page.evaluate("() => document.activeElement?.textContent?.trim()") == "Cancel"
    page.keyboard.press("Escape")
    expect(modal).to_have_count(0)
    expect(connect_btn).to_be_focused()

    # ModelHealthDrawer focus trap (Tab/Shift+Tab) and Escape focus restoration.
    health_btn = page.locator("article.admin-model-card", has_text="A11y Test Model").get_by_role(
        "button", name="Health history"
    )
    health_btn.focus()
    page.keyboard.press("Enter")
    drawer = page.get_by_role("dialog", name="Health history: A11y Test Model")
    expect(drawer).to_be_visible()
    assert _active_inside(page, '[role="dialog"]') is True
    for _ in range(6):
        page.keyboard.press("Tab")
        assert _active_inside(page, '[role="dialog"]') is True
    page.keyboard.press("Shift+Tab")
    assert _active_inside(page, '[role="dialog"]') is True
    page.keyboard.press("Escape")
    expect(drawer).to_have_count(0)
    expect(health_btn).to_be_focused()

    collector.assert_clean()


def test_m7_search_question_navigator_and_password_form_accessibility(e2e_workspace, desktop_page):
    _setup_admin(e2e_workspace)
    with e2e_workspace.client() as c:
        login_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS)
        sess = c.post(
            "/api/sessions",
            json={"candidate": "Ada Byron", "role": "Systems Lead", "policy": "Rubric", "consent": True},
        )
        sess.raise_for_status()
        sid = sess.json()["id"]
        a1 = c.post(
            f"/api/sessions/{sid}/answers",
            json={"question": "First question on caching", "answer": "Use bounded TTLs.", "references": []},
        ).json()
        c.post(
            f"/api/sessions/{sid}/answers",
            json={"question": "Second question on sharding", "answer": "Consistent hashing.", "references": []},
        ).raise_for_status()
        c.post(
            f"/api/sessions/{sid}/answers",
            json={"question": "Third question on consensus", "answer": "Quorum majority.", "references": []},
        ).raise_for_status()

    page, collector = desktop_page
    _sign_in_account(page, e2e_workspace.base_url)

    # PasswordChangeForm: noValidate + short current password surfaces React role="alert" without native tooltip block.
    pw_form = page.get_by_role("form", name="Change password")
    expect(pw_form).to_have_attribute("novalidate", "")
    pw_form.get_by_label("New password", exact=True).fill("Valid-New-Pass-123")
    pw_form.get_by_label("Confirm new password").fill("Valid-New-Pass-123")
    pw_form.get_by_role("button", name="Update password").click()
    expect(pw_form.locator("p[role='alert']")).to_contain_text("Current password is required.")

    pw_form.get_by_label("Current password").fill("short")
    pw_form.get_by_role("button", name="Update password").click()
    expect(pw_form.locator("p[role='alert']")).to_contain_text("at least 10")
    assert not collector.page_errors and not collector.server_errors
    page.wait_for_timeout(150)
    assert all("422" in msg for msg in collector.console_errors), collector.console_errors
    collector.reset()

    # Breadcrumb landmark, WorkspaceSearch :focus-within ring, and close focus restoration.
    expect(page.get_by_role("navigation", name="Breadcrumb")).to_be_visible()
    search_trigger = page.get_by_role("button", name="Search workspace")
    search_trigger.focus()
    page.keyboard.press("Enter")
    search_dialog = page.locator("dialog.search-dialog")
    expect(search_dialog).to_be_visible()
    search_input = search_dialog.get_by_role("combobox", name="Search workspace records")
    expect(search_input).to_be_focused()
    ring_style = page.evaluate(
        """() => {
          const row = document.querySelector('.search-input-row');
          const cs = getComputedStyle(row);
          return { style: cs.outlineStyle, width: cs.outlineWidth };
        }"""
    )
    assert ring_style["style"] != "none" and ring_style["width"] != "0px"
    page.keyboard.press("Escape")
    expect(search_dialog).not_to_be_visible()
    expect(search_trigger).to_be_focused()

    # QuestionNavigator ArrowUp/ArrowDown/Home/End + aria-live="polite" announcement.
    page.goto(f"{e2e_workspace.base_url}/interviews/review/?id={sid}&answer={a1['id']}", wait_until="domcontentloaded")
    q_nav = page.get_by_role("navigation", name="Interview questions")
    q_links = q_nav.locator("button.question-link")
    expect(q_links).to_have_count(3)
    live_region = q_nav.locator("[aria-live='polite']")
    expect(live_region).to_contain_text("Question 1 of 3: First question on caching.")

    q_links.nth(0).focus()
    page.keyboard.press("ArrowDown")
    expect(q_links.nth(1)).to_be_focused()
    page.keyboard.press("End")
    expect(q_links.nth(2)).to_be_focused()
    page.keyboard.press("ArrowUp")
    expect(q_links.nth(1)).to_be_focused()
    page.keyboard.press("Home")
    expect(q_links.nth(0)).to_be_focused()
    page.keyboard.press("ArrowDown")
    page.keyboard.press("Enter")
    expect(q_links.nth(1)).to_have_attribute("aria-current", "true")
    expect(live_region).to_contain_text("Question 2 of 3: Second question on sharding.")
    collector.assert_clean()


def test_m7_mobile_drawer_inert_focus_trap_and_escape_restore(e2e_workspace, e2e_browser):
    _setup_admin(e2e_workspace)
    ctx, page, collector = _open_viewport_page(e2e_browser, 390, 844)
    try:
        _sign_in_account(page, e2e_workspace.base_url)
        page.goto(e2e_workspace.base_url + "/", wait_until="domcontentloaded")

        expect(page.get_by_role("navigation", name="Breadcrumb")).to_be_visible()
        sidebar = page.locator("aside.sidebar")
        main = page.locator("main#main-content")
        toggle = page.get_by_role("button", name="Open navigation menu")

        # Closed mobile drawer is inert and aria-hidden; Tab from toggle cannot enter sidebar.
        expect(sidebar).to_have_attribute("aria-hidden", "true")
        expect(sidebar).to_have_attribute("inert", "")
        assert main.get_attribute("inert") is None

        toggle.focus()
        page.keyboard.press("Tab")
        assert _active_inside(page, "aside.sidebar") is False

        # Open drawer via keyboard: <main> and .skip-content become inert; focus moves into drawer and traps Tab.
        toggle.focus()
        page.keyboard.press("Enter")
        expect(sidebar).to_have_class(re.compile(r"\bopen\b"))
        expect(main).to_have_attribute("inert", "")
        expect(page.locator("a.skip-content")).to_have_attribute("inert", "")
        assert sidebar.get_attribute("inert") is None
        expect(sidebar.get_by_role("button", name="Close navigation menu")).to_be_focused()

        for _ in range(15):
            page.keyboard.press("Tab")
            assert _active_inside(page, "aside.sidebar") is True
        page.keyboard.press("Shift+Tab")
        assert _active_inside(page, "aside.sidebar") is True

        # Escape closes drawer, removes inert from <main>, restores inert to <aside>, and restores toggle focus.
        page.keyboard.press("Escape")
        expect(sidebar).not_to_have_class(re.compile(r"\bopen\b"))
        expect(sidebar).to_have_attribute("inert", "")
        assert main.get_attribute("inert") is None
        expect(toggle).to_be_focused()
        collector.assert_clean()
    finally:
        ctx.close()


@pytest.mark.parametrize(
    "viewport",
    [(1440, 900, "desktop-1440"), (390, 844, "mobile-390"), (320, 780, "mobile-320")],
    ids=lambda v: v[2],
)
def test_m7_all_12_routes_zero_overflow_both_themes(e2e_workspace, e2e_browser, viewport):
    width, height, _ = viewport
    _setup_admin(e2e_workspace)
    long_token = "Supercalifragilisticexpialidocious_" + ("x" * 64)
    with e2e_workspace.client() as c:
        login_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS)
        sess = c.post(
            "/api/sessions",
            json={
                "candidate": "Mobile Overflow Check",
                "role": "Principal Infrastructure Architect",
                "policy": "Only official manual.",
                "consent": True,
            },
        )
        sess.raise_for_status()
        sid = sess.json()["id"]
        c.post(
            f"/api/sessions/{sid}/answers",
            json={
                "question": f"How do you handle long tokens like {long_token} in a narrow mobile picker?",
                "answer": f"Token stream {long_token} wrapped across lines cleanly.",
                "references": [{"label": "Manual", "text": f"Reference {long_token} entry."}],
            },
        ).raise_for_status()

    ctx, page, collector = _open_viewport_page(e2e_browser, width, height)
    try:
        _sign_in_account(page, e2e_workspace.base_url)
        routes = ALL_ROUTES + (f"/interviews/review/?id={sid}", f"/interviews/brief/?id={sid}")
        for theme in ("dark", "light"):
            page.goto(e2e_workspace.base_url + "/account/", wait_until="domcontentloaded")
            page.get_by_role("radio", name=theme.capitalize()).check()
            expect(page.locator("html")).to_have_attribute("data-theme", theme)
            for route in routes:
                page.goto(e2e_workspace.base_url + route, wait_until="domcontentloaded")
                expect(page.locator("main#main-content")).to_be_visible()
                assert_no_horizontal_overflow(page)
        collector.assert_clean()
    finally:
        ctx.close()
