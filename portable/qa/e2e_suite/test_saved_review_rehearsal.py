"""Exercise the fictional saved-review cases without submitting a live Playground benchmark."""
import json
from urllib.parse import urlsplit

from playwright.sync_api import expect
import pytest

from e2e_suite.harness import assert_no_horizontal_overflow, login_user
from e2e_suite.test_m14_compare_playground import ADMIN_EMAIL, ADMIN_PASS, _setup_auth, _sign_in_admin

CATALOGUE = "/api/admin/models/playground/saved-review-rehearsal"
LIVE_BENCHMARK = "/api/admin/models/playground/run"


def keyboard_toggle(summary):
    summary.focus()
    expect(summary).to_be_focused()
    summary.press("Enter")


@pytest.mark.tier3
def test_admin_rehearsal_uses_local_cases_and_keeps_the_live_draft(e2e_workspace, desktop_page, mobile_page):
    _setup_auth(e2e_workspace)
    with e2e_workspace.client() as api:
        login_user(api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        examples = {row["id"]: row for row in api.get(CATALOGUE).raise_for_status().json()["cases"]}
        before_usage = api.get("/api/admin/usage/ai-allowance").raise_for_status().json()
        before_cost = api.get("/api/admin/usage/ai-costs").raise_for_status().json()["totals"]

    for fixture, phone in ((desktop_page, False), (mobile_page, True)):
        page, collector = fixture
        _sign_in_admin(page, e2e_workspace.base_url)
        requests = []
        def track(request):
            path = urlsplit(request.url).path
            if path.startswith("/api/"):
                requests.append((request.method, path))

        page.on("request", track)
        page.get_by_role("tab", name="Playground", exact=True).click()
        playground = page.get_by_role("region", name="Model playground")
        launcher = playground.get_by_text("Rehearse saved review", exact=True)
        expect(launcher).to_be_visible()
        system_prompt = playground.get_by_role("textbox", name="System prompt")
        user_input = playground.get_by_role("textbox", name="User input")
        system_prompt.fill("Separate live benchmark instructions.")
        user_input.fill("Separate live benchmark data.")
        assert all(path != CATALOGUE for _, path in requests)
        keyboard_toggle(launcher)
        control = playground.get_by_label("Fictional case", exact=True)
        script = playground.get_by_label("Scripted reply", exact=True)
        result = playground.get_by_role("region", name="Reviewer result")
        card = launcher.locator("..")
        expect(control).to_have_value("brief")
        expect(result).to_contain_text(examples["brief"]["local_question"])
        expect(result).to_contain_text("Local follow up")
        expect(script).to_have_count(0)
        expect(card.get_by_text("Show transfer payload", exact=True)).to_have_count(0)
        expect(card.get_by_text("Show scripted reply", exact=True)).to_have_count(0)

        control.select_option("match")
        expect(script).to_have_value("anchored")
        expected = {s["id"]: s for s in examples["match"]["scripts"]}
        expect(result.get_by_role("listitem")).to_have_text(expected["anchored"]["questions"])
        expect(result).not_to_contain_text("92")
        payload = card.get_by_text("Show transfer payload", exact=True)
        blob = payload.locator("..").locator("pre")
        expect(blob).to_be_hidden()
        keyboard_toggle(payload)
        assert json.loads(blob.inner_text()) == examples["match"]["payload"]
        keyboard_toggle(payload)
        raw = card.get_by_text("Show scripted reply", exact=True)
        scripted = raw.locator("..").locator("pre")
        expect(scripted).to_be_hidden()
        keyboard_toggle(raw)
        assert json.loads(scripted.inner_text()) == expected["anchored"]["reply"]
        for choice in ("score_only", "outside_excerpt"):
            script.select_option(choice)
            expect(result).to_contain_text("Unusable model suggestion")
            expect(result).to_contain_text(examples["match"]["local_question"])
            expect(result.get_by_role("listitem")).to_have_count(0)
            expect(result).not_to_contain_text("92")
            expect(scripted).to_be_hidden()
            keyboard_toggle(raw)
            assert json.loads(scripted.inner_text()) == expected[choice]["reply"]
            expect(result).not_to_contain_text("a different clock source")
        for case_id in ("permitted", "no_source", "no_notice"):
            control.select_option(case_id)
            expect(result).to_contain_text("Local follow up")
            expect(result).to_contain_text(examples[case_id]["local_question"])
            expect(script).to_have_count(0)
            expect(payload).to_have_count(0)
            expect(raw).to_have_count(0)
        control.select_option("match")
        expect(script).to_have_value("anchored")
        expect(result).to_contain_text(expected["anchored"]["questions"][0])
        assert_no_horizontal_overflow(page)
        if phone:
            card.screenshot(path=e2e_workspace.screenshot_dir / "saved-review-rehearsal-phone.png")
        keyboard_toggle(launcher)
        expect(result).to_have_count(0)
        expect(system_prompt).to_have_value("Separate live benchmark instructions.")
        expect(user_input).to_have_value("Separate live benchmark data.")
        assert ("GET", CATALOGUE) in requests
        assert all(method == "GET" and path != LIVE_BENCHMARK for method, path in requests), requests
        page.remove_listener("request", track)
        collector.assert_clean()

    with e2e_workspace.client() as api:
        login_user(api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        assert api.get("/api/admin/usage/ai-allowance").json() == before_usage
        assert api.get("/api/admin/usage/ai-costs").json()["totals"] == before_cost
        assert api.get("/api/sessions").json() == []
