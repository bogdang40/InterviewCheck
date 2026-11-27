"""Opaque-box Playwright E2E tests for M11 model budgets, routing simulator, and diagnostics."""
import csv
from datetime import datetime, timezone
import re

from playwright.sync_api import expect
import pytest

from api import integrations, model_probe
from e2e_suite.harness import (
    ConsoleErrorCollector,
    assert_no_horizontal_overflow,
    install_audio_mock,
    login_user,
    signup_user,
)

ADMIN_EMAIL = "admin-m11@example.test"
MEMBER_EMAIL = "member-m11@example.test"
BOOTSTRAP_SECRET = "m11-bootstrap-secret-1234"
ADMIN_PASS = "Synthetic-M11-Admin-Pass-1"
MEMBER_PASS = "Synthetic-M11-Member-Pass-1"
MONTHLY_THRESHOLD = "Monthly estimated spend threshold (USD)"


def _setup_auth(e2e_workspace, *, include_member: bool = False) -> None:
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
        if include_member:
            signup_user(c, email=MEMBER_EMAIL, password=MEMBER_PASS)


def _sign_in_admin(page, base_url: str) -> None:
    page.goto(base_url + "/admin/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Administrator sign in required")).to_be_visible(timeout=15_000)
    page.get_by_label("Operator email").fill(ADMIN_EMAIL)
    page.get_by_label("Password", exact=True).fill(ADMIN_PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_role("heading", name="Model administration")).to_be_visible(timeout=15_000)


def _create_model_api(
    client, *, slug: str, display_name: str, provider: str = "openai", capability: str = "reference",
    model_id: str = "gpt-4o", api_key: str = "sk-m11-api-1234",
    enabled: bool = True, is_default: bool = False, parameters: dict | None = None,
) -> dict:
    res = client.post("/api/admin/models", json={
        "slug": slug, "display_name": display_name, "provider": provider, "capability": capability,
        "model_id": model_id, "apiKey": api_key, "enabled": enabled, "is_default": is_default,
        "parameters": parameters or {},
    })
    res.raise_for_status()
    return res.json()["model"]


async def _async_probe_ok(latency_ms: int = 45):
    return model_probe.ProbeOutcome(
        ok=True, status="connected", http_status=200, latency_ms=latency_ms,
        last_error=None, checked_at=datetime.now(timezone.utc).isoformat(),
    )


def _assert_no_secrets(page, *secrets: str) -> None:
    html = page.content()
    for secret in (*secrets, "e2e-deterministic-test-secret-key"):
        assert secret not in html


def test_m11_budget_configuration_persistence_and_security_gates(e2e_workspace, desktop_page):
    _setup_auth(e2e_workspace, include_member=True)
    with e2e_workspace.client() as anon:
        assert anon.get("/api/admin/models/diagnostics").status_code == 401
        assert anon.post("/api/admin/models/simulate-chain", json={"capability": "reference"}).status_code == 401
    with e2e_workspace.client() as member_api:
        login_user(member_api, email=MEMBER_EMAIL, password=MEMBER_PASS)
        assert member_api.get("/api/admin/models/diagnostics").status_code == 403
        assert member_api.post("/api/admin/models/simulate-chain", json={"capability": "reference"}).status_code == 403
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        admin_api.headers.pop("X-InterviewCheck", None)
        assert admin_api.post("/api/admin/models/simulate-chain", json={"capability": "reference"}).status_code == 403

    page, collector = desktop_page
    _sign_in_admin(page, e2e_workspace.base_url)
    page.get_by_role("button", name="Connect model").first.click()
    dlg = page.get_by_role("dialog", name="Connect model")
    dlg.get_by_label("Provider").select_option("openai")
    dlg.get_by_label("Display name").fill("Budget Primary")
    dlg.get_by_label("Model ID").fill("gpt-4o")
    dlg.get_by_label("Slug (optional, auto-generated if blank)").fill("budget-primary")
    dlg.get_by_label("API key").fill("sk-m11-secret-alpha-9999")
    dlg.get_by_label("Fallback priority (0 to 10000)").fill("10")
    dlg.get_by_label("Default for capability").check()

    daily_input = dlg.get_by_label("Daily token limit (1 to 100M)")
    daily_input.fill("0")
    dlg.get_by_role("button", name="Save and connect").click()
    assert daily_input.evaluate("el => el.validity.rangeUnderflow") is True and dlg.is_visible()

    daily_input.fill("50000")
    dlg.get_by_label(MONTHLY_THRESHOLD, exact=True).fill("25.5")
    dlg.get_by_label("Input USD per 1M tokens").fill("2.5")
    dlg.get_by_label("Output USD per 1M tokens").fill("10")
    dlg.get_by_role("button", name="Save and connect").click()
    expect(dlg).to_have_count(0)

    badge = page.locator("article.admin-model-card", has_text="Budget Primary").locator(".admin-budget-badge")
    expect(badge).to_contain_text("0/50.0k tok")
    expect(badge).to_contain_text("$0.00/$25.50")

    page.reload(wait_until="domcontentloaded")
    expect(page.locator("article.admin-model-card", has_text="Budget Primary").locator(".admin-budget-badge")).to_contain_text("0/50.0k tok", timeout=15_000)

    page.goto("about:blank")
    e2e_workspace.restart()
    page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
    card = page.locator("article.admin-model-card", has_text="Budget Primary")
    expect(card.locator(".admin-budget-badge")).to_contain_text("$0.00/$25.50", timeout=15_000)

    card.get_by_role("button", name="Configure").click()
    edit_dlg = page.get_by_role("dialog")
    expect(edit_dlg.get_by_label("Daily token limit (1 to 100M)")).to_have_value("50000")
    expect(edit_dlg.get_by_label(MONTHLY_THRESHOLD, exact=True)).to_have_value("25.5")
    expect(edit_dlg.get_by_label("Input USD per 1M tokens")).to_have_value("2.5")
    expect(edit_dlg.get_by_label("Output USD per 1M tokens")).to_have_value("10")
    edit_dlg.get_by_label("Daily token limit (1 to 100M)").fill("75000")
    edit_dlg.get_by_label(MONTHLY_THRESHOLD, exact=True).fill("")
    edit_dlg.get_by_role("button", name="Save configuration").click()
    expect(edit_dlg).to_have_count(0)

    page.reload(wait_until="domcontentloaded")
    reloaded_badge = page.locator("article.admin-model-card", has_text="Budget Primary").locator(".admin-budget-badge")
    expect(reloaded_badge).to_contain_text("0/75.0k tok", timeout=15_000)
    assert "$25.50" not in reloaded_badge.inner_text()
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        models_res = admin_api.get("/api/admin/models")
        assert models_res.status_code == 200 and "sk-m11-secret-alpha-9999" not in models_res.text
        params = models_res.json()["models"][0]["parameters"]
        assert params["daily_token_limit"] == 75000 and params["monthly_cost_limit_usd"] is None
    _assert_no_secrets(page, "sk-m11-secret-alpha-9999")
    collector.assert_clean()


def test_monthly_estimated_spend_threshold_skips_later_request(e2e_workspace, desktop_page, monkeypatch):
    _setup_auth(e2e_workspace)
    page, collector = desktop_page
    model_id = "threshold-fixture-v1"
    calls = []

    async def recorded_usage(name, method, url, **kwargs):
        calls.append((name, method, kwargs["json"]["model"]))
        return {"status": "completed", "output": [{"type": "message", "content": [
            {"type": "output_text", "text": "Recorded fixture response."}]}],
            "usage": {"input_tokens": 1500, "output_tokens": 500}}

    monkeypatch.setattr(integrations, "fetch_json", recorded_usage)
    with e2e_workspace.client() as client:
        login_user(client, email=ADMIN_EMAIL, password=ADMIN_PASS)
        _create_model_api(client, slug="threshold-fixture", display_name="Spend threshold fixture",
                          model_id=model_id, is_default=True)
        _sign_in_admin(page, e2e_workspace.base_url)
        card = page.locator("article.admin-model-card", has_text="Spend threshold fixture")
        configure = card.get_by_role("button", name="Configure")
        configure.click()
        editor = page.get_by_role("dialog", name="Configure Spend threshold fixture")
        threshold = editor.get_by_role("spinbutton", name=MONTHLY_THRESHOLD, exact=True)
        threshold.fill("0.02")
        editor.get_by_label("Input USD per 1M tokens").fill("10")
        editor.get_by_label("Output USD per 1M tokens").fill("20")
        editor.get_by_role("button", name="Save configuration").click()
        expect(editor).to_have_count(0)

        request = {"role": "Engineer", "question": "Which measurement?"}
        result = client.post("/api/integrations/reference", json=request).raise_for_status()
        assert result.json()["text"] == "Recorded fixture response."
        assert calls == [("OpenAI", "POST", model_id)]
        refused = client.post("/api/integrations/reference", json=request)
        assert refused.status_code == 429 and refused.headers["X-InterviewCheck-Limit"] == "model-budget"
        assert calls == [("OpenAI", "POST", model_id)]

    page.get_by_role("tab", name="Usage", exact=True).click()
    ledger = page.get_by_role("region", name="AI cost log")
    recorded = ledger.get_by_role("listitem")
    expect(recorded).to_have_count(1)
    expect(recorded).to_contain_text("Spend threshold fixture")
    expect(recorded).to_contain_text("$0.03 · Estimated")
    with page.expect_download() as download:
        ledger.get_by_role("link", name="Download CSV").click()
    with download.value.path().open(encoding="utf-8-sig", newline="") as exported:
        row, = csv.DictReader(exported)
    assert (row["model_id"], row["estimate_status"], float(row["cost_usd"])) == (model_id, "estimated", 0.025)
    assert (int(row["input_tokens"]), int(row["output_tokens"])) == (1500, 500)

    page.reload(wait_until="domcontentloaded")
    page.get_by_role("tab", name="Models", exact=True).click()
    simulator = page.get_by_role("region", name="Routing chain simulator")
    simulator.get_by_role("button", name="Test capability chain").click()
    expect(simulator.get_by_role("listitem")).to_contain_text("Monthly estimated spend threshold reached")
    configure.click()
    expect(threshold).to_have_value("0.02")
    help_text = re.compile(r"recorded estimate.*later budget checks\. Provider charges can exceed this amount\.")
    expect(threshold).to_have_accessible_description(help_text)
    field = editor.locator("div.field").filter(has_text=MONTHLY_THRESHOLD)
    for width, height in ((1440, 900), (390, 844)):
        page.set_viewport_size({"width": width, "height": height})
        expect(field.get_by_text(help_text)).to_be_visible()
        assert_no_horizontal_overflow(page)
        field.screenshot(path=e2e_workspace.screenshot_dir / f"model-spend-threshold-{width}.png")
    collector.assert_clean()


def test_m11_routing_simulator_chain_budget_skip_and_readonly(e2e_workspace, desktop_page, monkeypatch):
    _setup_auth(e2e_workspace)
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        _create_model_api(
            admin_api, slug="sim-primary", display_name="Sim Primary", provider="openai", model_id="gpt-4o",
            api_key="sk-m11-sim-prim-1111", is_default=True,
            parameters={"fallback_priority": 10, "daily_token_limit": 1000, "input_cost_per_1m_usd": 5.0, "output_cost_per_1m_usd": 15.0},
        )
        _create_model_api(
            admin_api, slug="sim-backup", display_name="Sim Backup", provider="anthropic", model_id="claude-sonnet-4-6",
            api_key="sk-m11-sim-back-2222",
            parameters={"fallback_priority": 20, "monthly_cost_limit_usd": 50.0, "input_cost_per_1m_usd": 3.0, "output_cost_per_1m_usd": 15.0},
        )
        _create_model_api(
            admin_api, slug="sim-disabled", display_name="Sim Disabled", provider="openai",
            model_id="gpt-4o-mini", api_key="sk-m11-sim-dis-3333", enabled=False, parameters={"fallback_priority": 5},
        )

    page, collector = desktop_page
    _sign_in_admin(page, e2e_workspace.base_url)
    sim = page.get_by_label("Routing chain simulator")
    sim.get_by_role("button", name="Test capability chain").click()
    expect(sim.get_by_text("Chain ready (2 active)")).to_be_visible()
    active_items = sim.locator("ol.admin-sim-list > li")
    expect(active_items).to_have_count(2)
    expect(active_items.nth(0)).to_contain_text("#1 Primary")
    expect(active_items.nth(0)).to_contain_text("Sim Primary")
    expect(active_items.nth(1)).to_contain_text("#2 Fallback")
    expect(active_items.nth(1)).to_contain_text("Sim Backup")
    expect(sim.locator("ul.admin-sim-list > li")).to_have_count(1)
    expect(sim.locator("ul.admin-sim-list")).to_contain_text("Sim Disabled")
    expect(sim.locator("ul.admin-sim-list")).to_contain_text("disabled")

    async def fake_ref_fetch(name, method, url, **kwargs):
        if name == "OpenAI":
            return {"status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": "Primary answer"}]}], "usage": {"input_tokens": 700, "output_tokens": 500}}
        return {"stop_reason": "end_turn", "content": [{"type": "text", "text": "Backup answer"}], "usage": {"input_tokens": 200, "output_tokens": 100}}

    monkeypatch.setattr(integrations, "fetch_json", fake_ref_fetch)
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        assert admin_api.post("/api/integrations/reference", json={"role": "SRE", "question": "Q1"}).json()["text"] == "Primary answer"
        assert admin_api.post("/api/integrations/reference", json={"role": "SRE", "question": "Q2"}).json()["text"] == "Backup answer"
        before_models = admin_api.get("/api/admin/models").json()["models"]
        before_diag = admin_api.get("/api/admin/models/diagnostics").json()["usage"]

    sim.get_by_role("button", name="Test capability chain").click()
    expect(sim.get_by_text("Chain ready (1 active)")).to_be_visible()
    expect(sim.locator("ol.admin-sim-list > li")).to_have_count(1)
    expect(sim.locator("ol.admin-sim-list > li").first).to_contain_text("Sim Backup")
    expect(sim.locator("ul.admin-sim-list > li")).to_have_count(2)
    expect(sim.locator("ul.admin-sim-list")).to_contain_text("Daily token limit exceeded")
    expect(sim.locator("ul.admin-sim-list")).to_contain_text("daily_token_limit_exceeded")

    sim.get_by_label("Simulator provider or slug (optional)").fill("openai")
    sim.get_by_role("button", name="Test capability chain").click()
    expect(sim.get_by_text("Would fail 429 (model budget reached)")).to_be_visible()

    sim.get_by_label("Simulator provider or slug (optional)").fill("")
    sim.get_by_label("Capability").select_option("question_planning")
    sim.get_by_label("Allow reference fallback").check()
    sim.get_by_role("button", name="Test capability chain").click()
    expect(sim.get_by_text("Chain ready (1 active)")).to_be_visible()
    expect(sim.locator("ol.admin-sim-list > li").first).to_contain_text("Sim Backup")

    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        assert admin_api.get("/api/admin/models").json()["models"] == before_models
        assert admin_api.get("/api/admin/models/diagnostics").json()["usage"] == before_diag
    _assert_no_secrets(page, "sk-m11-sim-prim-1111", "sk-m11-sim-back-2222", "sk-m11-sim-dis-3333")
    collector.assert_clean()


def test_m11_lazy_diagnostics_tab_usage_transcription_and_audio_check(e2e_workspace, desktop_page, monkeypatch):
    _setup_auth(e2e_workspace)
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        diag_model = _create_model_api(
            admin_api, slug="diag-primary", display_name="Diag Primary", provider="openai", model_id="gpt-4o",
            api_key="sk-m11-diag-1111", is_default=True,
            parameters={"daily_token_limit": 2000, "monthly_cost_limit_usd": 10.0, "input_cost_per_1m_usd": 10.0, "output_cost_per_1m_usd": 20.0},
        )
        monkeypatch.setattr(model_probe, "probe_model", lambda row, *, api_key: _async_probe_ok(45))
        assert admin_api.post(f"/api/admin/models/{diag_model['id']}/probe").status_code == 200

        async def fake_diag_fetch(name, method, url, **kwargs):
            return {"status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": "Diag answer"}]}], "usage": {"input_tokens": 1500, "output_tokens": 500}}

        monkeypatch.setattr(integrations, "fetch_json", fake_diag_fetch)
        assert admin_api.post("/api/integrations/reference", json={"role": "Backend", "question": "Q"}).status_code == 200
        history = admin_api.get(f"/api/admin/models/{diag_model['id']}/health").raise_for_status().json()["history"]
        assert sorted(check["source"] for check in history) == ["live", "probe"]
        latencies = {check["source"]: check["latency_ms"] for check in history}
        assert latencies["probe"] == 45 and latencies["live"] >= 0

    page, collector = desktop_page
    install_audio_mock(page)
    _sign_in_admin(page, e2e_workspace.base_url)

    expect(page.locator("#panel-diagnostics")).to_have_count(0)
    page.get_by_role("tab", name="Diagnostics").click()
    diag_panel = page.locator("#panel-diagnostics")
    expect(diag_panel.get_by_role("heading", name="Diagnostics & usage")).to_be_visible()

    summary = diag_panel.get_by_label("Fleet diagnostic summary")
    latency = summary.get_by_role("article").filter(has_text="Fleet P95 latency")
    # With two observations the nearest-rank P95 is the slower one.
    expect(latency.locator("strong")).to_have_text(f"{max(latencies.values())} ms")
    expect(latency).to_contain_text(f"Avg {round(sum(latencies.values()) / 2)} ms · Uptime 100.0%")
    expect(summary).to_contain_text("2.0k")
    expect(summary).to_contain_text("Not ready")

    tok_bar = diag_panel.get_by_role("progressbar", name="Daily tokens (diag-primary)")
    expect(tok_bar).to_have_attribute("aria-valuenow", "2000")
    expect(tok_bar).to_have_attribute("aria-valuemax", "2000")
    expect(tok_bar.locator(".admin-meter-fill.over")).to_have_count(1)
    expect(diag_panel.get_by_role("progressbar", name="Monthly estimated spend (diag-primary)")).to_have_attribute("aria-valuemax", "10")

    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        _create_model_api(admin_api, slug="diag-dg", display_name="Diag Deepgram", provider="deepgram", capability="transcription", model_id="nova-2", api_key="sk-m11-dg-2222")
    diag_panel.get_by_role("button", name="Refresh diagnostics").click()
    expect(summary).to_contain_text("Ready")
    expect(summary).to_contain_text("1 candidates")
    expect(summary).to_contain_text("deepgram · nova-2")

    diag_panel.get_by_role("button", name="Run audio input check").click()
    expect(diag_panel.get_by_role("meter", name="Diagnostic audio input level in dBFS")).to_be_visible()
    diag_panel.get_by_role("button", name="Stop audio check").click()
    expect(diag_panel.get_by_text("Audio diagnostic stopped.")).to_be_visible()

    diag_panel.get_by_role("button", name="Run audio input check").click()
    expect(diag_panel.get_by_text(re.compile(r"Audio input verified\. Peak -?\d+ dBFS\."))).to_be_visible(timeout=7000)
    _assert_no_secrets(page, "sk-m11-diag-1111", "sk-m11-dg-2222")
    collector.assert_clean()


@pytest.mark.parametrize("viewport", [(1440, 900, "desktop-1440"), (390, 844, "mobile-390")], ids=lambda v: v[2])
def test_m11_responsive_models_and_diagnostics_viewports(e2e_workspace, e2e_browser, monkeypatch, viewport):
    width, height, _ = viewport
    _setup_auth(e2e_workspace)
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        m1 = _create_model_api(
            admin_api, slug="resp-budget", display_name="Responsive Budget Model", provider="openai", model_id="gpt-4o",
            api_key="sk-m11-resp-1111", is_default=True,
            parameters={"daily_token_limit": 10000, "monthly_cost_limit_usd": 20.0, "input_cost_per_1m_usd": 2.0, "output_cost_per_1m_usd": 6.0},
        )
        _create_model_api(admin_api, slug="resp-dg", display_name="Responsive Deepgram", provider="deepgram", capability="transcription", model_id="nova-2", api_key="sk-m11-resp-dg-2222")
        monkeypatch.setattr(model_probe, "probe_model", lambda row, *, api_key: _async_probe_ok(31))
        assert admin_api.post(f"/api/admin/models/{m1['id']}/probe").status_code == 200

    mobile = width <= 480
    ctx = e2e_browser.new_context(viewport={"width": width, "height": height}, reduced_motion="reduce", is_mobile=mobile, has_touch=mobile)
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    try:
        _sign_in_admin(page, e2e_workspace.base_url)
        expect(page.locator("article.admin-model-card", has_text="Responsive Budget Model").locator(".admin-budget-badge")).to_be_visible()
        page.get_by_label("Routing chain simulator").get_by_role("button", name="Test capability chain").click()
        expect(page.get_by_label("Routing chain simulator").get_by_text("Chain ready (1 active)")).to_be_visible()
        assert_no_horizontal_overflow(page)

        page.get_by_role("tab", name="Diagnostics").click()
        diag = page.locator("#panel-diagnostics")
        expect(diag.get_by_role("heading", name="Diagnostics & usage")).to_be_visible()
        expect(diag.get_by_label("Fleet diagnostic summary")).to_contain_text("Ready")
        expect(diag.get_by_role("progressbar", name="Daily tokens (resp-budget)")).to_be_visible()
        assert_no_horizontal_overflow(page)

        _assert_no_secrets(page, "sk-m11-resp-1111", "sk-m11-resp-dg-2222")
        collector.assert_clean()
    finally:
        ctx.close()
