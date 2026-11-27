"""An unavailable diagnostics read must not turn recorded model spend into zero."""
from playwright.sync_api import expect

from api import integrations
from e2e_suite.harness import login_user
from e2e_suite.test_m11_budgets_simulator_diagnostics import (
    ADMIN_EMAIL, ADMIN_PASS, _create_model_api, _setup_auth, _sign_in_admin,
)


def test_failed_refresh_after_another_model_save_preserves_unknown_budget_usage(e2e_workspace, desktop_page, monkeypatch):
    _setup_auth(e2e_workspace)
    page, collector = desktop_page
    base = e2e_workspace.base_url
    diagnostics_url = base + "/api/admin/models/diagnostics"
    calls = []

    async def recorded_usage(name, method, url, **kwargs):
        calls.append(kwargs["json"]["model"])
        return {"status": "completed", "output": [{"type": "message", "content": [
            {"type": "output_text", "text": "Fixture response."}]}],
            "usage": {"input_tokens": 2000, "output_tokens": 0}}

    monkeypatch.setattr(integrations, "fetch_json", recorded_usage)
    with e2e_workspace.client() as client:
        login_user(client, email=ADMIN_EMAIL, password=ADMIN_PASS)
        spent = _create_model_api(client, slug="metered-fixture", display_name="Metered fixture",
                                  model_id="metered-fixture", is_default=True,
                                  parameters={"input_cost_per_1m_usd": 10, "monthly_cost_limit_usd": 0.01})
        other = _create_model_api(client, slug="separate-fixture", display_name="Separate fixture",
                                  model_id="separate-fixture", capability="judge")
        client.post("/api/integrations/reference", json={"role": "Engineer", "question": "Which measurement?"}).raise_for_status()
        assert calls == [spent["model_id"]]
        before = client.get("/api/admin/models/diagnostics").raise_for_status().json()["usage"]["models"][spent["id"]]
        assert (before["monthly_requests"], before["monthly_cost_usd"], before["budget_status"]) == (
            1, 0.02, "monthly_cost_limit_exceeded")

        _sign_in_admin(page, base)
        models_tab = page.get_by_role("tab", name="Models", exact=True)
        diagnostics_tab = page.get_by_role("tab", name="Diagnostics", exact=True)
        badge = page.locator("[data-model-slug='metered-fixture'] .admin-budget-badge")
        expect(badge).to_contain_text("$0.02/$0.01")
        expect(badge).to_have_attribute("data-variant", "destructive")
        diagnostics_tab.click()
        panel = page.locator("#panel-diagnostics")
        fleet = panel.get_by_label("Fleet diagnostic summary")
        meter = panel.get_by_role("progressbar", name="Monthly estimated spend (metered-fixture)", exact=True)
        expect(meter).to_have_attribute("aria-valuetext", "$0.02 / $0.01")
        refresh = panel.get_by_role("button", name="Refresh diagnostics")
        expect(refresh).to_be_enabled()
        models_tab.click()
        page.locator("[data-model-slug='separate-fixture']").get_by_role("button", name="Configure").click()
        editor = page.get_by_role("dialog", name="Configure Separate fixture")
        editor.get_by_label("Display name").fill("Renamed separate fixture")
        held = []

        def hold_refresh(route):
            response = route.fetch()
            assert response.ok and response.json()["usage"]["models"][spent["id"]] == before
            held.append(route)
            page.evaluate("document.documentElement.dataset.usageReplyHeld = 'yes'")

        page.route(diagnostics_url, hold_refresh, times=1)
        with page.expect_response(base + "/api/admin/models/" + other["id"]) as changed:
            editor.get_by_role("button", name="Save configuration").click()
        assert changed.value.ok and changed.value.json()["model"]["display_name"] == "Renamed separate fixture"
        page.wait_for_function("() => document.documentElement.dataset.usageReplyHeld === 'yes'")
        expect(badge).to_have_text("Budget usage unavailable")
        expect(badge).not_to_have_attribute("data-variant", "destructive")
        diagnostics_tab.click()
        expect(meter).to_have_count(0)
        expect(fleet).to_have_count(0)

        pending, = held
        failure = "Fixture diagnostics read unavailable."
        with page.expect_response(diagnostics_url) as failed:
            pending.fulfill(status=503, json={"detail": failure})
        assert failed.value.status == 503
        expect(page.get_by_role("alert").filter(has_text=failure)).to_be_visible()
        expect(panel.get_by_text("Recorded usage is unavailable.", exact=True)).to_be_visible()
        expect(meter).to_have_count(0)
        expect(fleet).to_have_count(0)
        models_tab.click()
        expect(badge).to_have_text("Budget usage unavailable")

        diagnostics_tab.click()
        with page.expect_response(diagnostics_url) as retried:
            refresh.click()
        assert retried.value.ok and retried.value.json()["usage"]["models"][spent["id"]] == before
        expect(meter).to_have_attribute("aria-valuetext", "$0.02 / $0.01")
        expect(meter.locator(".admin-meter-fill.over")).to_have_count(1)
        expect(fleet).to_contain_text("Estimated monthly spend $0.02")
        expect(panel.get_by_text("Recorded usage is unavailable.", exact=True)).to_have_count(0)
        expect(page.get_by_role("alert").filter(has_text=failure)).to_have_count(0)
        models_tab.click()
        expect(badge).to_contain_text("$0.02/$0.01")
        expect(badge).to_have_attribute("data-variant", "destructive")
        ledger = client.get("/api/admin/usage/ai-costs?days=7").raise_for_status().json()
        assert (ledger["totals"]["requests"], ledger["totals"]["cost_usd"], calls) == (1, 0.02, [spent["model_id"]])
    assert collector.server_errors == ["503 " + diagnostics_url]
    assert all("503" in message for message in collector.console_errors)
    collector.server_errors.clear()
    collector.console_errors.clear()
    collector.assert_clean()
