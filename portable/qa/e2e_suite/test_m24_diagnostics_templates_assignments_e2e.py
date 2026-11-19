"""Playwright E2E tests for M24 diagnostics export, rubric templates/cloning, session assignment, and mobile tabs."""
import json

from playwright.sync_api import expect
import pytest

from api import ssrf_guard
from e2e_suite.harness import (
    ConsoleErrorCollector,
    assert_no_horizontal_overflow,
    login_user,
    signup_user,
)

ADMIN_EMAIL = "admin-m24@example.test"
ALICE_EMAIL = "alice-m24@example.test"
BOB_EMAIL = "bob-m24@example.test"
PASS = "Synthetic-M24-Pass-9876"
BOOTSTRAP_SECRET = "m24-bootstrap-secret-1234"
MODEL_API_KEY = "sk-m24-super-secret-api-key-9999"
ALERT_SIGNING_SECRET = "whsec-m24-super-secret-signing-8888"
VIEWPORTS = [(1440, 900, "desktop-1440"), (390, 844, "mobile-390")]
ADMIN_TABS = ("Models", "Accounts", "Audit log", "Diagnostics", "Playground", "Security", "Prompts & SLA", "Compliance")
FORBIDDEN_SECRET_KEYS = frozenset({
    "encrypted_api_key", "encrypted_signing_secret", "token_hash",
    "api_key", "signing_secret", "totp_secret", "password_hash",
})


def _open_page(e2e_browser, width: int, height: int):
    mobile = width <= 480
    ctx = e2e_browser.new_context(
        viewport={"width": width, "height": height}, reduced_motion="reduce", is_mobile=mobile, has_touch=mobile,
    )
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    page.set_default_navigation_timeout(30_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    return ctx, page, collector


def _setup_users(e2e_workspace, *, emails: tuple[str, ...], admin_emails: tuple[str, ...] = ()) -> None:
    e2e_workspace.configure_embedded_auth(admin_emails=admin_emails, bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    with e2e_workspace.client() as c:
        for email in emails:
            secret = BOOTSTRAP_SECRET if email in admin_emails else None
            signup_user(c, email=email, password=PASS, admin_secret=secret)


def _sign_in_browser(page, base_url: str, email: str) -> None:
    page.goto(base_url + "/account/", wait_until="domcontentloaded")
    page.get_by_label("Operator email").fill(email)
    page.get_by_label("Password", exact=True).fill(PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(f"{email} · Access active")).to_be_visible()


def _assert_no_secret_keys(obj) -> None:
    if isinstance(obj, dict):
        for k, v in obj.items():
            assert k not in FORBIDDEN_SECRET_KEYS, f"Secret key leaked in bundle: {k}"
            _assert_no_secret_keys(v)
    elif isinstance(obj, list):
        for item in obj:
            _assert_no_secret_keys(item)


def _assert_tab_visible_in_strip(page, index: int) -> None:
    metrics = page.evaluate(
        """(idx) => {
          const strip = document.querySelector('.admin-tabs');
          const tabs = strip ? Array.from(strip.querySelectorAll('[role="tab"]')) : [];
          const tab = tabs[idx];
          if (!strip || !tab) return null;
          const s = strip.getBoundingClientRect();
          const t = tab.getBoundingClientRect();
          return {
            sLeft: s.left, sRight: s.right, scrollLeft: strip.scrollLeft,
            tLeft: t.left, tRight: t.right, tHeight: t.height,
            tScrollW: tab.scrollWidth, tClientW: tab.clientWidth,
          };
        }""",
        index,
    )
    assert metrics is not None
    assert metrics["tHeight"] >= 44, f"Tab {index} height {metrics['tHeight']} < 44"
    assert metrics["tScrollW"] <= metrics["tClientW"] + 1, f"Tab {index} clipped: {metrics}"
    assert metrics["tLeft"] >= metrics["sLeft"] - 2, f"Tab {index} clipped left: {metrics}"
    assert metrics["tLeft"] < metrics["sRight"] - 40, f"Tab {index} not scrolled into view: {metrics}"
    if index in (0, len(ADMIN_TABS) - 1):
        assert metrics["tRight"] <= metrics["sRight"] + 2, f"Edge tab {index} clipped right: {metrics}"
    return metrics["scrollLeft"]


def test_m24_admin_diagnostics_bundle_secret_free_and_mobile_tabs(e2e_workspace, e2e_browser, monkeypatch):
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])
    _setup_users(e2e_workspace, emails=(ADMIN_EMAIL,), admin_emails=(ADMIN_EMAIL,))
    with e2e_workspace.client() as c:
        login_user(c, email=ADMIN_EMAIL, password=PASS)
        c.post("/api/admin/models", json={
            "slug": "m24-diag-model", "display_name": "M24 Diag Model", "provider": "openai",
            "capability": "reference", "model_id": "gpt-4o", "apiKey": MODEL_API_KEY,
        }).raise_for_status()
        c.post("/api/admin/alerts", json={
            "name": "M24 Error Rule", "trigger_type": "model_error_streak", "threshold_value": 3,
            "capability_filter": "reference", "webhook_url": "https://hooks.example.com/m24",
            "signing_secret": ALERT_SIGNING_SECRET, "enabled": True, "cooldown_minutes": 15,
        }).raise_for_status()
        tok = c.post("/api/integrations/security/tokens", json={"name": "m24-ci", "scopes": ["read:interviews"]})
        tok.raise_for_status()
        raw_api_token = tok.json()["token"]

    ctx, page, collector = _open_page(e2e_browser, 1440, 900)
    try:
        _sign_in_browser(page, e2e_workspace.base_url, ADMIN_EMAIL)
        page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
        expect(page.get_by_role("heading", name="Model administration")).to_be_visible()
        expect(page.get_by_role("button", name="Search workspace")).to_have_attribute(
            "aria-keyshortcuts", "Meta+k Control+k"
        )
        assert_no_horizontal_overflow(page)

        page.get_by_role("tab", name="Diagnostics").click()
        export_btn = page.get_by_role("button", name="Export diagnostic bundle")
        expect(export_btn).to_be_visible()
        with page.expect_download() as dl:
            export_btn.click()
        expect(page.locator("#panel-diagnostics [role='status']").filter(has_text="Downloaded diagnostic bundle")).to_be_visible()

        raw_json = dl.value.path().read_text(encoding="utf-8")
        bundle = json.loads(raw_json)
        assert bundle["probes"]["ok"] is True
        assert len(bundle["models"]) == 1 and bundle["models"][0]["slug"] == "m24-diag-model"
        assert bundle["alerts"]["rule_count"] == 1
        assert "prompt_templates" in bundle and "csp_summary" in bundle
        _assert_no_secret_keys(bundle)
        for secret_val in (
            "encrypted_api_key", "encrypted_signing_secret", "token_hash",
            MODEL_API_KEY, ALERT_SIGNING_SECRET, BOOTSTRAP_SECRET,
            "e2e-deterministic-test-secret-key", raw_api_token,
        ):
            assert secret_val not in raw_json, f"Secret material leaked in bundle: {secret_val}"
        collector.assert_clean()
    finally:
        ctx.close()

    m_ctx, m_page, m_collector = _open_page(e2e_browser, 390, 844)
    try:
        _sign_in_browser(m_page, e2e_workspace.base_url, ADMIN_EMAIL)
        m_page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
        expect(m_page.get_by_role("heading", name="Model administration")).to_be_visible()
        assert_no_horizontal_overflow(m_page)

        tablist = m_page.get_by_role("tablist", name="Admin sections")
        tabs = tablist.get_by_role("tab")
        expect(tabs).to_have_count(len(ADMIN_TABS))
        for idx, label in enumerate(ADMIN_TABS):
            expect(tabs.nth(idx)).to_contain_text(label)
            assert tabs.nth(idx).bounding_box()["height"] >= 44

        tabs.nth(0).focus()
        _assert_tab_visible_in_strip(m_page, 0)
        for idx in range(1, len(ADMIN_TABS)):
            m_page.keyboard.press("ArrowRight")
            cur = tabs.nth(idx)
            expect(cur).to_be_focused()
            expect(cur).to_have_attribute("aria-selected", "true")
            panel_id = cur.get_attribute("aria-controls")
            assert panel_id
            expect(m_page.locator(f"#{panel_id}[role='tabpanel']")).to_be_visible()
            _assert_tab_visible_in_strip(m_page, idx)
            assert_no_horizontal_overflow(m_page)

        m_page.keyboard.press("Home")
        expect(tabs.nth(0)).to_be_focused()
        expect(tabs.nth(0)).to_have_attribute("aria-selected", "true")
        _assert_tab_visible_in_strip(m_page, 0)

        m_page.keyboard.press("End")
        expect(tabs.nth(len(ADMIN_TABS) - 1)).to_be_focused()
        expect(tabs.nth(len(ADMIN_TABS) - 1)).to_have_attribute("aria-selected", "true")
        expect(m_page.locator("#panel-compliance[role='tabpanel']")).to_be_visible()
        _assert_tab_visible_in_strip(m_page, len(ADMIN_TABS) - 1)
        assert m_page.evaluate("() => document.querySelector('.admin-tabs').scrollLeft") > 0
        assert_no_horizontal_overflow(m_page)
        m_collector.assert_clean()
    finally:
        m_ctx.close()


@pytest.mark.parametrize("viewport", VIEWPORTS, ids=lambda v: v[2])
def test_m24_roles_rubric_templates_and_clone_persistence(e2e_workspace, e2e_browser, viewport):
    width, height, _ = viewport
    _setup_users(e2e_workspace, emails=(ALICE_EMAIL,))
    ctx, page, collector = _open_page(e2e_browser, width, height)
    try:
        _sign_in_browser(page, e2e_workspace.base_url, ALICE_EMAIL)
        page.goto(e2e_workspace.base_url + "/roles/", wait_until="domcontentloaded")
        expect(page.get_by_role("heading", name="Role library")).to_be_visible()
        assert_no_horizontal_overflow(page)

        page.get_by_role("button", name="Add role").click()
        page.get_by_label("Role name").fill("Staff Security Architect")
        page.get_by_label("Description").fill("Distributed security and reliability reviews")
        page.get_by_label("Planned questions, one per line").fill("Walk through SSRF validation.")

        picker = page.get_by_label("Rubric template picker")
        expect(picker.get_by_text("Rubric template library")).to_be_visible()
        picker.get_by_label("Rubric template", exact=True).select_option("backend-systems")
        expect(picker).to_contain_text("Total weight 100")
        picker.get_by_role("button", name="Replace criteria").click()
        expect(picker.get_by_role("status")).to_contain_text("Replaced rubric with Backend Systems & Storage (4 criteria).")
        expect(page.get_by_text("4 / 25 criteria")).to_be_visible()

        picker.get_by_label("Rubric template", exact=True).select_option("security-threat-modeling")
        picker.get_by_role("button", name="Append criteria").click()
        expect(picker.get_by_role("status")).to_contain_text("Appended 4 criteria from Application Security & Threat Modeling.")
        expect(page.get_by_text("8 / 25 criteria")).to_be_visible()

        page.get_by_role("button", name="Save role").click()
        src_row = page.locator(".role-row", has_text="Staff Security Architect").first
        expect(src_row).to_contain_text("v1 | 8 rubric criteria")

        page.get_by_role("button", name="Clone role Staff Security Architect").click()
        expect(page.locator("[role='status']").filter(has_text="Cloned role Staff Security Architect as Staff Security Architect (Copy).")).to_be_visible()
        copy_row = page.locator(".role-row", has_text="Staff Security Architect (Copy)")
        expect(copy_row).to_contain_text("v1 | 8 rubric criteria")
        assert_no_horizontal_overflow(page)

        page.reload(wait_until="domcontentloaded")
        expect(page.locator(".role-row", has_text="Staff Security Architect (Copy)")).to_contain_text("v1 | 8 rubric criteria")
        expect(page.locator(".role-row", has_text="Distributed security and reliability reviews").first).to_contain_text("v1 | 8 rubric criteria")
        assert_no_horizontal_overflow(page)
        collector.assert_clean()
    finally:
        ctx.close()


@pytest.mark.parametrize("viewport", VIEWPORTS, ids=lambda v: v[2])
def test_m24_session_assignment_and_archive_queue_filtering(e2e_workspace, e2e_browser, viewport):
    width, height, _ = viewport
    _setup_users(e2e_workspace, emails=(ALICE_EMAIL, BOB_EMAIL))
    with e2e_workspace.client() as c:
        login_user(c, email=ALICE_EMAIL, password=PASS)
        sids = []
        for cand in ("Alice Assigned Candidate", "Bob High Priority Candidate", "Unassigned Candidate"):
            s = c.post("/api/sessions", json={"candidate": cand, "role": "Platform Lead", "policy": "No AI", "consent": True})
            s.raise_for_status()
            sid = s.json()["id"]
            c.post(f"/api/sessions/{sid}/answers", json={
                "question": "Explain circuit breakers.", "answer": "Open after threshold failures.", "references": [],
            }).raise_for_status()
            sids.append(sid)
    sid_alice, sid_bob, _sid_free = sids

    ctx, page, collector = _open_page(e2e_browser, width, height)
    try:
        _sign_in_browser(page, e2e_workspace.base_url, ALICE_EMAIL)

        page.goto(f"{e2e_workspace.base_url}/interviews/review/?id={sid_alice}", wait_until="domcontentloaded")
        bar = page.get_by_label("Session assignment")
        expect(bar).to_contain_text("Unassigned")
        expect(bar.get_by_role("button", name="Clear assignment")).to_be_disabled()
        bar.get_by_label("Assignee email").fill(ALICE_EMAIL)
        bar.get_by_label("Priority").select_option("normal")
        bar.get_by_label("Due date").fill("2026-12-15")
        bar.get_by_role("button", name="Save assignment").click()
        expect(bar.get_by_role("status")).to_contain_text(f"Assigned to {ALICE_EMAIL} (normal priority).")
        expect(bar).to_contain_text("Normal priority")
        assert_no_horizontal_overflow(page)

        page.reload(wait_until="domcontentloaded")
        bar = page.get_by_label("Session assignment")
        expect(bar).to_contain_text(ALICE_EMAIL)
        expect(bar).to_contain_text("Normal priority")

        bar.get_by_role("button", name="Clear assignment").click()
        expect(bar.get_by_role("status")).to_contain_text("Session assignment cleared.")
        expect(bar).to_contain_text("Unassigned")
        expect(bar.get_by_role("button", name="Clear assignment")).to_be_disabled()

        bar.get_by_label("Assignee email").fill(ALICE_EMAIL)
        bar.get_by_label("Priority").select_option("normal")
        bar.get_by_label("Due date").fill("2026-12-15")
        bar.get_by_role("button", name="Save assignment").click()
        expect(bar.get_by_role("status")).to_contain_text(f"Assigned to {ALICE_EMAIL} (normal priority).")

        page.goto(f"{e2e_workspace.base_url}/interviews/review/?id={sid_bob}", wait_until="domcontentloaded")
        bar_bob = page.get_by_label("Session assignment")
        bar_bob.get_by_label("Assignee email").fill(BOB_EMAIL)
        bar_bob.get_by_label("Priority").select_option("high")
        bar_bob.get_by_label("Due date").fill("2026-12-10")
        bar_bob.get_by_role("button", name="Save assignment").click()
        expect(bar_bob.get_by_role("status")).to_contain_text(f"Assigned to {BOB_EMAIL} (high priority).")

        page.goto(e2e_workspace.base_url + "/interviews/", wait_until="domcontentloaded")
        strip = page.get_by_label("Assignment queues")
        me_pill = strip.get_by_role("button", name=r"Assigned to me")
        high_pill = strip.get_by_role("button", name=r"High priority")
        free_pill = strip.get_by_role("button", name=r"Unassigned")
        expect(me_pill).to_contain_text("1")
        expect(high_pill).to_contain_text("1")
        expect(free_pill).to_contain_text("1")
        expect(me_pill).to_have_attribute("aria-pressed", "true")
        expect(strip).to_contain_text("Alice Assigned Candidate")
        expect(strip).not_to_contain_text("Bob High Priority Candidate")
        expect(strip).not_to_contain_text("Unassigned Candidate")
        assert_no_horizontal_overflow(page)

        high_pill.click()
        expect(high_pill).to_have_attribute("aria-pressed", "true")
        expect(strip).to_contain_text("Bob High Priority Candidate")
        expect(strip).not_to_contain_text("Alice Assigned Candidate")

        free_pill.click()
        expect(free_pill).to_have_attribute("aria-pressed", "true")
        expect(strip).to_contain_text("Unassigned Candidate")
        expect(strip).not_to_contain_text("Bob High Priority Candidate")

        me_pill.click()
        strip.get_by_role("link", name="Alice Assigned Candidate").click()
        expect(page).to_have_url(f"{e2e_workspace.base_url}/interviews/review/?id={sid_alice}")
        expect(page.get_by_label("Session assignment")).to_contain_text(ALICE_EMAIL)
        assert_no_horizontal_overflow(page)
        collector.assert_clean()
    finally:
        ctx.close()
