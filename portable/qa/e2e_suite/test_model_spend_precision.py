"""The model list, diagnostic meter and request router use the same monthly estimate."""
import re

from playwright.sync_api import expect

from api import integrations
from e2e_suite.harness import login_user, signup_user
from e2e_suite.test_m11_budgets_simulator_diagnostics import (
    ADMIN_EMAIL, ADMIN_PASS, BOOTSTRAP_SECRET, _create_model_api, _sign_in_admin,
)


def refresh_usage(page, button, diagnostics_url, model):
    with page.expect_response(diagnostics_url) as read:
        button.click()
    assert read.value.ok
    return read.value.json()["usage"]["models"][model["id"]]


def test_diagnostics_and_model_badge_agree_with_monthly_routing_boundary(e2e_workspace, desktop_page, monkeypatch):
    other_email = "second-spend-admin@example.test"
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL, other_email), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    page, collector = desktop_page
    diagnostics_url = e2e_workspace.base_url + "/api/admin/models/diagnostics"
    calls = []
    inputs = iter((99_996, 4, 1))

    async def measured_request(name, method, url, **kwargs):
        calls.append(kwargs["json"]["model"])
        return {"status": "completed", "output": [{"type": "message", "content": [
            {"type": "output_text", "text": "Fixture reading."}]}],
            "usage": {"input_tokens": next(inputs), "output_tokens": 0}}

    monkeypatch.setattr(integrations, "fetch_json", measured_request)
    with e2e_workspace.client() as client, e2e_workspace.client() as other:
        for account, email in ((client, ADMIN_EMAIL), (other, other_email)):
            signup_user(account, email=email, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
            login_user(account, email=email, password=ADMIN_PASS)
        model = _create_model_api(client, slug="spend-boundary", display_name="Spend boundary fixture",
                                  model_id="spend-boundary-model", is_default=True, parameters={
                                      "monthly_cost_limit_usd": 0.01, "input_cost_per_1m_usd": 0.1})
        request_path = "/api/integrations/reference"
        request = {"role": "Engineer", "question": "What did the meter record?"}
        assert client.post(request_path, json=request).raise_for_status().json()["text"] == "Fixture reading."
        _sign_in_admin(page, e2e_workspace.base_url)
        models_tab = page.get_by_role("tab", name="Models", exact=True)
        diagnostics_tab = page.get_by_role("tab", name="Diagnostics", exact=True)
        badge = page.locator("[data-model-slug='spend-boundary'] .admin-budget-badge")
        panel = page.locator("#panel-diagnostics")
        meter_label = "Monthly estimated spend (spend-boundary)"
        monthly = panel.locator(".admin-diag-bar").filter(has_text=meter_label)
        meter = monthly.get_by_role("progressbar", name=meter_label, exact=True)
        refresh_meter = panel.get_by_role("button", name="Refresh diagnostics")

        for amount, variant, reached in (("0.0099996", "outline", False), ("0.01", "destructive", True)):
            models_tab.click()
            usage = refresh_usage(page, page.get_by_role("button", name="Refresh", exact=True), diagnostics_url, model)
            assert usage["monthly_cost_usd"] == float(amount) and usage["monthly_cost_limit_usd"] == 0.01
            assert usage["budget_status"] == ("monthly_cost_limit_exceeded" if reached else "ok")
            ratio = re.compile(re.escape("$" + amount) + r"\s*/\s*\$0\.01\b")
            expect(badge).to_contain_text(ratio)
            expect(badge).to_have_attribute("data-variant", variant)
            diagnostics_tab.click()
            expect(refresh_meter).to_be_enabled()
            refresh_usage(page, refresh_meter, diagnostics_url, model)
            expect(monthly).to_contain_text(ratio)
            expect(meter).to_have_attribute("aria-valuenow", amount)
            expect(meter).to_have_attribute("aria-valuemax", "0.01")
            expect(meter).to_have_attribute("aria-valuetext", ratio)
            expect(meter.locator(".admin-meter-fill.over")).to_have_count(int(reached))
            if not reached:
                expect(meter.locator(".admin-meter-fill.warn")).to_have_count(1)
                assert client.post(request_path, json=request).raise_for_status().json()["text"] == "Fixture reading."
        refused = client.post(request_path, json=request)
        assert refused.status_code == 429 and refused.headers["X-InterviewCheck-Limit"] == "model-budget"
        assert calls == [model["model_id"]] * 2

        # The Models refresh reads its roster and diagnostics independently. Let the roster finish first.
        models_tab.click()
        roster_url = e2e_workspace.base_url + "/api/admin/models"
        held = []

        def hold_diagnostics(route):
            held.append(route)
            page.evaluate("document.documentElement.dataset.budgetReadHeld = 'yes'")

        page.route(diagnostics_url, hold_diagnostics)
        with page.expect_response(roster_url) as roster:
            page.get_by_role("button", name="Refresh", exact=True).click()
        cached_model, = roster.value.json()["models"]
        assert cached_model["parameters"]["monthly_cost_limit_usd"] == 0.01
        page.wait_for_function("() => document.documentElement.dataset.budgetReadHeld === 'yes'")
        changed = other.patch("/api/admin/models/" + model["id"], json={"parameters": {"monthly_cost_limit_usd": None}})
        assert changed.raise_for_status().json()["model"]["parameters"]["monthly_cost_limit_usd"] is None
        pending, = held
        with page.expect_response(diagnostics_url) as updated:
            pending.continue_()
        assert updated.value.json()["usage"]["models"][model["id"]]["monthly_cost_limit_usd"] is None
        page.unroute(diagnostics_url, hold_diagnostics)
        expect(badge).to_have_attribute("data-variant", "outline")
        expect(badge).to_contain_text("$0.01")
        expect(badge).not_to_contain_text("/")
        # Keep the first administrator's model list cached. Only diagnostics reloads the cleared threshold.
        diagnostics_tab.click()
        roster_reads = []
        page.on("request", lambda req: roster_reads.append(req.url) if req.url == roster_url else None)
        usage = refresh_usage(page, refresh_meter, diagnostics_url, model)
        assert usage["monthly_cost_usd"] == 0.01 and usage["monthly_cost_limit_usd"] is None and usage["budget_status"] == "ok"
        expect(monthly).to_contain_text("$0.01 (No threshold)")
        expect(meter).to_have_attribute("aria-valuetext", "$0.01 (No threshold)")
        expect(monthly.locator(".admin-meter-fill.over")).to_have_count(0)
        assert not roster_reads
        assert client.post(request_path, json=request).raise_for_status().json()["text"] == "Fixture reading."
        assert calls == [model["model_id"]] * 3
    collector.assert_clean()
