"""The model list, diagnostic meter and request router use the same monthly estimate."""
import re

from playwright.sync_api import expect

from api import integrations
from e2e_suite.harness import login_user, signup_user
from e2e_suite.test_m11_budgets_simulator_diagnostics import (
    ADMIN_EMAIL, ADMIN_PASS, BOOTSTRAP_SECRET, MONTHLY_THRESHOLD, _create_model_api, _setup_auth, _sign_in_admin,
)


def refresh_usage(page, button, diagnostics_url, model):
    expect(button).to_be_enabled()
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


def test_local_threshold_save_reaches_mounted_diagnostics_before_an_older_read(e2e_workspace, desktop_page):
    _setup_auth(e2e_workspace)
    page, collector = desktop_page
    base = e2e_workspace.base_url
    diagnostics_url = base + "/api/admin/models/diagnostics"
    with e2e_workspace.client() as admin:
        login_user(admin, email=ADMIN_EMAIL, password=ADMIN_PASS)
        model = _create_model_api(admin, slug="local-threshold", display_name="Local threshold fixture")
    _sign_in_admin(page, base)
    models_tab = page.get_by_role("tab", name="Models", exact=True)
    diagnostics_tab = page.get_by_role("tab", name="Diagnostics", exact=True)
    diagnostics_tab.click()
    panel = page.locator("#panel-diagnostics")
    refresh = panel.get_by_role("button", name="Refresh diagnostics")
    meter = panel.get_by_role("progressbar", name="Monthly estimated spend (local-threshold)", exact=True)
    initial = refresh_usage(page, refresh, diagnostics_url, model)
    assert initial["monthly_cost_limit_usd"] is None
    expect(meter).to_have_attribute("aria-valuetext", "$0.00 (No threshold)")
    held = []

    def delay_current_response(route):
        response = route.fetch()
        assert response.ok and response.json()["usage"]["models"][model["id"]]["monthly_cost_limit_usd"] is None
        held.append((route, response))
        page.evaluate("document.documentElement.dataset.oldEstimateHeld = 'yes'")

    page.route(diagnostics_url, delay_current_response, times=1)
    with page.expect_request(diagnostics_url):
        refresh.click()
    page.wait_for_function("() => document.documentElement.dataset.oldEstimateHeld === 'yes'")
    models_tab.click()
    card = page.locator("[data-model-slug='local-threshold']")
    card.get_by_role("button", name="Configure").click()
    editor = page.get_by_role("dialog", name="Configure Local threshold fixture")
    editor.get_by_role("spinbutton", name=MONTHLY_THRESHOLD, exact=True).fill("0.01")
    model_url = base + "/api/admin/models/" + model["id"]
    with (
        page.expect_response(lambda res: res.url == model_url and res.request.method == "PATCH") as saved,
        page.expect_response(diagnostics_url) as latest,
    ):
        editor.get_by_role("button", name="Save configuration").click()
    assert saved.value.ok and saved.value.json()["model"]["parameters"]["monthly_cost_limit_usd"] == 0.01
    assert latest.value.ok and latest.value.json()["usage"]["models"][model["id"]]["monthly_cost_limit_usd"] == 0.01
    expect(card.locator(".admin-budget-badge")).to_contain_text("$0.00/$0.01")
    diagnostics_tab.click()
    expect(meter).to_have_attribute("aria-valuetext", "$0.00 / $0.01")
    (old_read, old_response), = held
    with page.expect_request_finished(lambda req: req.url == diagnostics_url):
        old_read.fulfill(response=old_response)
    # Let the late fetch continuation and React commit before checking both views.
    page.evaluate("() => new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done)))")
    expect(meter).to_have_attribute("aria-valuemax", "0.01")
    expect(meter).to_have_attribute("aria-valuetext", "$0.00 / $0.01")
    models_tab.click()
    expect(card.locator(".admin-budget-badge")).to_contain_text("$0.00/$0.01")
    collector.assert_clean()


def test_api_threshold_keeps_its_configured_digits_in_models_and_diagnostics(e2e_workspace, desktop_page):
    _setup_auth(e2e_workspace)
    page, collector = desktop_page
    with e2e_workspace.client() as admin:
        login_user(admin, email=ADMIN_EMAIL, password=ADMIN_PASS)
        model = _create_model_api(admin, slug="fine-threshold", display_name="Fine threshold fixture")
        _sign_in_admin(page, e2e_workspace.base_url)
        diagnostics_tab = page.get_by_role("tab", name="Diagnostics", exact=True)
        diagnostics_tab.click()
        panel = page.locator("#panel-diagnostics")
        meter = panel.get_by_role("progressbar", name="Monthly estimated spend (fine-threshold)", exact=True)
        expect(meter).to_have_attribute("aria-valuetext", "$0.00 (No threshold)")
        threshold = 0.010000001
        updated = admin.patch("/api/admin/models/" + model["id"], json={"parameters": {"monthly_cost_limit_usd": threshold}})
        assert updated.raise_for_status().json()["model"]["parameters"]["monthly_cost_limit_usd"] == threshold
        usage = refresh_usage(page, panel.get_by_role("button", name="Refresh diagnostics"),
                              e2e_workspace.base_url + "/api/admin/models/diagnostics", model)
        assert usage["monthly_cost_usd"] == 0 and usage["monthly_cost_limit_usd"] == threshold
    expect(meter).to_have_attribute("aria-valuenow", "0")
    expect(meter).to_have_attribute("aria-valuemax", "0.010000001")
    expect(meter).to_have_attribute("aria-valuetext", "$0.00 / $0.010000001")
    expect(panel.get_by_text("$0.00 / $0.010000001", exact=True)).to_be_visible()
    page.get_by_role("tab", name="Models", exact=True).click()
    expect(page.locator("[data-model-slug='fine-threshold'] .admin-budget-badge")).to_contain_text("$0.00/$0.010000001")
    collector.assert_clean()
