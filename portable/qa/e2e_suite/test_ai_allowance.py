"""Edit a workspace spending control through the authenticated Usage tab."""
import re

import pytest
from playwright.sync_api import expect

from e2e_suite.harness import assert_no_horizontal_overflow, login_user, signup_user

EMAIL = "owner@allowance.example"
PASS = "Synthetic-Allowance-Pass-9876"
BOOTSTRAP = "synthetic-allowance-bootstrap"
ALLOWANCE = "/api/admin/usage/ai-allowance"


def open_card(page, workspace):
    page.goto(workspace.base_url + "/account/")
    page.get_by_label("Operator email").fill(EMAIL)
    page.get_by_label("Password", exact=True).fill(PASS)
    login_url = workspace.base_url + "/api/integrations/access/login"
    with page.expect_response(lambda res: res.request.method == "POST" and res.url == login_url) as login:
        page.get_by_role("button", name="Sign in", exact=True).click()
    assert login.value.status == 200
    expect(page.get_by_text(f"{EMAIL} · Access active")).to_be_visible()
    page.goto(workspace.base_url + "/admin/")
    page.get_by_role("tab", name="Usage", exact=True).click()
    card = page.get_by_role("region", name="Monthly AI attempt allowance")
    expect(card.get_by_label("Monthly attempt limit")).to_be_visible()
    return card


@pytest.mark.tier3
def test_allowance_edit_conflict_and_uncertain_ack(e2e_workspace, desktop_page, mobile_page):
    e2e_workspace.configure_embedded_auth(admin_emails=(EMAIL,), bootstrap_secret=BOOTSTRAP)
    e2e_workspace.restart()
    with e2e_workspace.client() as other:
        signup_user(other, email=EMAIL, password=PASS, admin_secret=BOOTSTRAP)
        login_user(other, email=EMAIL, password=PASS)
        page, collector = desktop_page
        card = open_card(page, e2e_workspace)
        field = card.get_by_label("Monthly attempt limit")
        save = card.get_by_role("button", name="Save allowance")
        reload_policy = card.get_by_role("button", name="Reload saved policy")
        expect(card).to_contain_text("0 used · Unlimited")
        field.fill("1.5")
        expect(save).to_be_disabled()
        expect(field).to_have_attribute("aria-invalid", "true")
        field.fill("0")
        field.press("Tab")
        expect(save).to_be_focused()
        save.press("Enter")
        expect(card).to_contain_text("0 remaining · Saved limit 0")
        expect(card).to_contain_text("Allowance saved.")

        # A simultaneous admin edit advances the revision but doesn't overwrite the input.
        field.fill("5")
        current = other.get(ALLOWANCE).json()
        other.put(ALLOWANCE, json={"monthly_limit": 6, "expected_revision": current["revision"]}).raise_for_status()
        save.click()
        expect(card.get_by_role("alert")).to_contain_text("Another administrator")
        assert all("409" in message for message in collector.console_errors)
        collector.console_errors.clear()
        page.get_by_role("button", name="Refresh usage").click()
        expect(card).to_contain_text("Saved limit 6")
        expect(field).to_have_value("5")
        expect(save).to_be_disabled()
        reload_policy.click()
        expect(field).to_have_value("5")
        expect(save).to_be_enabled()
        save.click()
        expect(card).to_contain_text("Saved limit 5")

        # The server commits. The browser receives an unusable success acknowledgment.
        writes = []

        def lose_ack(route):
            if route.request.method != "PUT":
                route.continue_()
                return
            actual = route.fetch()
            assert actual.ok
            writes.append(route.request.post_data_json)
            route.fulfill(status=200, content_type="application/json", body="{}")

        page.route("**" + ALLOWANCE, lose_ack)
        field.fill("")
        save.click()
        expect(card.get_by_role("alert")).to_contain_text("save was not confirmed")
        expect(save).to_be_disabled()
        expect(field).to_have_value("")
        reload_policy.click()
        expect(card).to_contain_text("0 used · Unlimited")
        expect(save).to_be_disabled()
        assert len(writes) == 1 and writes[0]["monthly_limit"] is None

        # A confirmed lost reply clears the draft. A later administrator can change the limit.
        confirmed = other.get(ALLOWANCE).raise_for_status().json()
        other.put(ALLOWANCE, json={"expected_revision": confirmed["revision"], "monthly_limit": 8}).raise_for_status()
        page.get_by_role("button", name="Refresh usage").click()
        expect(field).to_have_value("8")
        expect(save).to_be_disabled()
        assert len(writes) == 1

    phone, _ = mobile_page
    card = open_card(phone, e2e_workspace)
    field = card.get_by_label("Monthly attempt limit")
    expect(field).to_have_value("8")
    expect(card).to_contain_text("Saved limit 8")
    field.fill("12")
    card.get_by_role("button", name="Save allowance").click()
    expect(card).to_contain_text("12 remaining · Saved limit 12")
    assert_no_horizontal_overflow(phone)
    card.screenshot(path=e2e_workspace.screenshot_dir / "monthly-ai-allowance-phone.png")
    phone.reload()
    phone.get_by_role("tab", name="Usage", exact=True).click()
    expect(card.get_by_label("Monthly attempt limit")).to_have_value("12")


@pytest.mark.tier3
def test_allowance_navigation_protects_each_admin_editor(e2e_workspace, desktop_page):
    e2e_workspace.configure_embedded_auth(admin_emails=(EMAIL,), bootstrap_secret=BOOTSTRAP)
    e2e_workspace.restart()
    with e2e_workspace.client() as other:
        signup_user(other, email=EMAIL, password=PASS, admin_secret=BOOTSTRAP)
    page, collector = desktop_page
    card = open_card(page, e2e_workspace)
    field = card.get_by_label("Monthly attempt limit")
    field.fill("7")
    overview = page.get_by_role("navigation", name="Workspace").get_by_role("link", name="Overview", exact=True)

    def verify_guard():
        prompts = []
        page.once("dialog", lambda dialog: (prompts.append(dialog.message), dialog.dismiss()))
        overview.click()
        assert prompts == ["Discard unsaved admin changes and leave this page?"]

    verify_guard()
    expect(field).to_have_value("7")
    page.get_by_role("tab", name="Prompts & SLA").click()
    prompt = page.get_by_role("tabpanel").get_by_label("System prompt")
    prompt.fill("Independent unsaved review prompt")
    page.get_by_role("tab", name="Usage", exact=True).click()
    expect(field).to_have_value("7")
    allowance_url = e2e_workspace.base_url + ALLOWANCE
    with page.expect_response(lambda res: res.request.method == "PUT" and res.url == allowance_url) as saved:
        card.get_by_role("button", name="Save allowance").click()
    assert saved.value.status == 200 and saved.value.json()["monthly_limit"] == 7
    expect(card).to_contain_text("Allowance saved.")
    verify_guard()
    page.get_by_role("tab", name="Prompts & SLA").click()
    expect(prompt).to_have_value("Independent unsaved review prompt")
    page.get_by_role("button", name="Discard edits").click()
    overview.click()
    expect(page).to_have_url(re.compile(r"^" + re.escape(e2e_workspace.base_url.rstrip("/")) + r"/?$"), timeout=15_000)
    collector.assert_clean()


@pytest.mark.tier3
def test_reverting_allowance_edit_follows_later_policy_refresh(e2e_workspace, desktop_page):
    e2e_workspace.configure_embedded_auth(admin_emails=(EMAIL,), bootstrap_secret=BOOTSTRAP)
    e2e_workspace.restart()
    with e2e_workspace.client() as other:
        signup_user(other, email=EMAIL, password=PASS, admin_secret=BOOTSTRAP)
        login_user(other, email=EMAIL, password=PASS)
        page, collector = desktop_page
        card = open_card(page, e2e_workspace)
        field = card.get_by_label("Monthly attempt limit")
        expect(field).to_have_value("")
        for before, edited, newer in (("", "5", 6), ("6", "0", 10)):
            field.fill(edited)
            expect(card.get_by_role("button", name="Save allowance")).to_be_enabled()
            field.fill("0" + before if before else before)
            expect(card.get_by_role("button", name="Save allowance")).to_be_disabled()
            policy = other.get(ALLOWANCE).raise_for_status().json()
            other.put(ALLOWANCE, json={"expected_revision": policy["revision"], "monthly_limit": newer}).raise_for_status()
            page.get_by_role("button", name="Refresh usage").click()
            expect(field).to_have_value(str(newer))
            expect(card.get_by_text("Reload the saved policy to keep editing.", exact=False)).to_have_count(0)
        collector.assert_clean()
