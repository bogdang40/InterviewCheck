"""Playwright E2E tests for M6 model telemetry, fallback routing chains, and retry/RPM quotas."""
from datetime import datetime, timezone
import re
from uuid import uuid4

from fastapi import HTTPException
from playwright.sync_api import expect
import pytest

from api import integrations, model_probe, model_resolver
from e2e_suite.harness import (
    ConsoleErrorCollector,
    assert_no_horizontal_overflow,
    login_user,
    signup_user,
)

ADMIN_EMAIL = "admin-m6@example.test"
MEMBER_EMAIL = "member-m6@example.test"
BOOTSTRAP_SECRET = "m6-bootstrap-secret-1234"
ADMIN_PASS = "Synthetic-M6-Admin-Pass-1"
MEMBER_PASS = "Synthetic-M6-Member-Pass-1"


def _setup_auth(e2e_workspace, *, include_member: bool = False) -> None:
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
    if include_member:
        with e2e_workspace.client() as c:
            signup_user(c, email=MEMBER_EMAIL, password=MEMBER_PASS)


def _sign_in_admin(page, base_url: str) -> None:
    page.goto(base_url + "/admin/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Administrator sign in required")).to_be_visible()
    page.get_by_label("Operator email").fill(ADMIN_EMAIL)
    page.get_by_label("Password", exact=True).fill(ADMIN_PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_role("heading", name="Model administration")).to_be_visible()


def _connect_model_ui(
    page, *, provider: str, capability: str, display_name: str, model_id: str, slug: str,
    api_key: str, fallback_priority: str = "100", max_retries: str = "0", rpm_limit: str = "", is_default: bool = False,
) -> None:
    page.get_by_role("button", name="Connect model").first.click()
    dlg = page.get_by_role("dialog", name="Connect model")
    dlg.get_by_label("Provider").select_option(provider)
    dlg.get_by_role("combobox", name=re.compile(r"^Capability")).select_option(capability)
    dlg.get_by_label("Display name").fill(display_name)
    dlg.get_by_label("Model ID").fill(model_id)
    dlg.get_by_label("Slug (optional, auto-generated if blank)").fill(slug)
    dlg.get_by_label("API key").fill(api_key)
    dlg.get_by_label("Fallback priority (0 to 10000)").fill(fallback_priority)
    dlg.get_by_label("Max retries (0 to 3)").fill(max_retries)
    dlg.get_by_label("RPM limit (1 to 10000)").fill(rpm_limit)
    if is_default:
        dlg.get_by_label("Default for capability").check()
    dlg.get_by_role("button", name="Save and connect").click()
    expect(dlg).to_have_count(0)


def _create_model_api(
    client, *, slug: str, display_name: str, provider: str = "openai", capability: str = "reference",
    model_id: str = "gpt-4o", api_key: str = "sk-m6-api-1234", is_default: bool = False, parameters: dict | None = None,
) -> dict:
    res = client.post(
        "/api/admin/models",
        json={
            "slug": slug, "display_name": display_name, "provider": provider, "capability": capability,
            "model_id": model_id, "apiKey": api_key, "is_default": is_default, "parameters": parameters or {},
        },
    )
    res.raise_for_status()
    return res.json()["model"]


async def _async_probe_ok(latency_ms: int = 33):
    return model_probe.ProbeOutcome(
        ok=True, status="connected", http_status=200, latency_ms=latency_ms,
        last_error=None, checked_at=datetime.now(timezone.utc).isoformat(),
    )


def test_m6_telemetry_and_health_auth_and_validation(e2e_workspace):
    _setup_auth(e2e_workspace, include_member=True)
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        mid = _create_model_api(admin_api, slug="auth-probe-target", display_name="Auth Target")["id"]

    protected = (
        "/api/admin/models/telemetry",
        f"/api/admin/models/{mid}/health",
        "/api/admin/models/not-a-uuid/health?limit=999",
    )
    with e2e_workspace.client() as anon:
        for path in protected:
            assert anon.get(path).status_code == 401
    with e2e_workspace.client() as member_api:
        login_user(member_api, email=MEMBER_EMAIL, password=MEMBER_PASS)
        for path in protected:
            assert member_api.get(path).status_code == 403

    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        fleet = admin_api.get("/api/admin/models/telemetry")
        assert fleet.status_code == 200
        assert fleet.json()["summary"]["total_models"] == 1
        assert fleet.json()["summary"]["total_checks"] == 0
        assert fleet.json()["summary"]["uptime_pct"] is None

        health_ok = admin_api.get(f"/api/admin/models/{mid}/health?limit=25")
        assert health_ok.status_code == 200 and health_ok.json()["history"] == []
        assert admin_api.get(f"/api/admin/models/{uuid4()}/health").status_code == 404
        assert admin_api.get("/api/admin/models/not-a-uuid/health").status_code == 422
        assert admin_api.get(f"/api/admin/models/{mid}/health?limit=0").status_code == 422
        assert admin_api.get(f"/api/admin/models/{mid}/health?limit=51").status_code == 422
        for bad_params in ({"max_retries": -1}, {"max_retries": 4}, {"rpm_limit": 0}, {"rpm_limit": 10001}):
            bad = admin_api.post(
                "/api/admin/models",
                json={
                    "slug": f"bad-{uuid4().hex[:6]}", "display_name": "Bad Params", "provider": "openai",
                    "capability": "reference", "model_id": "gpt-4o", "apiKey": "sk-bad-1111", "parameters": bad_params,
                },
            )
            assert bad.status_code == 422


def test_m6_retries_rpm_validation_and_fallback_rank_badges(e2e_workspace, desktop_page):
    _setup_auth(e2e_workspace)
    page, collector = desktop_page
    _sign_in_admin(page, e2e_workspace.base_url)

    # Validate Max retries (0 to 3) and RPM limit (1 to 10000) error handling in modal.
    page.get_by_role("button", name="Connect model").first.click()
    dlg = page.get_by_role("dialog", name="Connect model")
    dlg.get_by_label("Provider").select_option("openai")
    dlg.get_by_label("Display name").fill("Chain Ref Alpha")
    dlg.get_by_label("Model ID").fill("gpt-4o")
    dlg.get_by_label("Slug (optional, auto-generated if blank)").fill("chain-ref-alpha")
    dlg.get_by_label("API key").fill("sk-m6-alpha-1111")

    retries_input = dlg.get_by_label("Max retries (0 to 3)")
    rpm_input = dlg.get_by_label("RPM limit (1 to 10000)")
    retries_input.fill("4")
    dlg.get_by_role("button", name="Save and connect").click()
    assert retries_input.evaluate("el => el.validity.rangeOverflow") is True
    expect(dlg).to_be_visible()

    retries_input.fill("2")
    rpm_input.fill("0")
    dlg.get_by_role("button", name="Save and connect").click()
    assert rpm_input.evaluate("el => el.validity.rangeUnderflow") is True
    expect(dlg).to_be_visible()

    rpm_input.fill("1e2")
    dlg.get_by_role("button", name="Save and connect").click()
    expect(dlg.get_by_role("alert")).to_contain_text("RPM limit must be a whole integer between 1 and 10000.")

    # Save Alpha (max_retries=2, rpm_limit=45, fallback_priority=50, is_default=True).
    dlg.get_by_label("Fallback priority (0 to 10000)").fill("50")
    retries_input.fill("2")
    rpm_input.fill("45")
    dlg.get_by_label("Default for capability").check()
    dlg.get_by_role("button", name="Save and connect").click()
    expect(dlg).to_have_count(0)

    alpha_card = page.locator("article.admin-model-card", has_text="Chain Ref Alpha")
    expect(alpha_card.get_by_text("Max retries 2 · RPM 45")).to_be_visible()
    expect(alpha_card.get_by_text("Default", exact=True)).to_be_visible()
    expect(alpha_card.get_by_text("#1 Primary", exact=True)).to_be_visible()

    # Edit Alpha: set Max retries=3 and clear RPM limit -> RPM Unlimited across reload.
    alpha_card.get_by_role("button", name="Configure").click()
    edit_dlg = page.get_by_role("dialog")
    expect(edit_dlg.get_by_label("Max retries (0 to 3)")).to_have_value("2")
    expect(edit_dlg.get_by_label("RPM limit (1 to 10000)")).to_have_value("45")
    edit_dlg.get_by_label("Max retries (0 to 3)").fill("3")
    edit_dlg.get_by_label("RPM limit (1 to 10000)").fill("")
    edit_dlg.get_by_role("button", name="Save configuration").click()
    expect(edit_dlg).to_have_count(0)
    expect(alpha_card.get_by_text("Max retries 3 · RPM Unlimited")).to_be_visible()

    page.reload(wait_until="domcontentloaded")
    alpha_card = page.locator("article.admin-model-card", has_text="Chain Ref Alpha")
    expect(alpha_card.get_by_text("Max retries 3 · RPM Unlimited")).to_be_visible()
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        alpha_row = admin_api.get("/api/admin/models").json()["models"][0]
        assert alpha_row["parameters"]["max_retries"] == 3 and alpha_row["parameters"]["rpm_limit"] is None

    # Add Beta (priority 10), Gamma (priority 20), and Judge (independent capability).
    _connect_model_ui(
        page, provider="anthropic", capability="reference", display_name="Chain Ref Beta",
        model_id="claude-sonnet-4-6", slug="chain-ref-beta", api_key="sk-m6-beta-2222", fallback_priority="10",
    )
    _connect_model_ui(
        page, provider="openai", capability="reference", display_name="Chain Ref Gamma",
        model_id="gpt-4o-mini", slug="chain-ref-gamma", api_key="sk-m6-gamma-3333", fallback_priority="20",
    )
    _connect_model_ui(
        page, provider="openai", capability="judge", display_name="Chain Judge One",
        model_id="gpt-4o", slug="chain-judge-one", api_key="sk-m6-judge-4444", is_default=True,
    )

    beta_card = page.locator("article.admin-model-card", has_text="Chain Ref Beta")
    gamma_card = page.locator("article.admin-model-card", has_text="Chain Ref Gamma")
    judge_card = page.locator("article.admin-model-card", has_text="Chain Judge One")
    expect(alpha_card.get_by_text("#1 Primary", exact=True)).to_be_visible()
    expect(beta_card.get_by_text("#2 Fallback", exact=True)).to_be_visible()
    expect(gamma_card.get_by_text("#3 Fallback", exact=True)).to_be_visible()
    expect(judge_card.get_by_text("#1 Primary", exact=True)).to_be_visible()

    # T5-01: Promoting Beta to Default clears Alpha Default and re-ranks WITHOUT page reload.
    beta_card.get_by_role("button", name="Configure").click()
    edit_beta = page.get_by_role("dialog")
    edit_beta.get_by_label("Default for capability").check()
    edit_beta.get_by_role("button", name="Save configuration").click()
    expect(edit_beta).to_have_count(0)

    expect(beta_card.get_by_text("Default", exact=True)).to_be_visible()
    expect(beta_card.get_by_text("#1 Primary", exact=True)).to_be_visible()
    expect(alpha_card.get_by_text("Default", exact=True)).to_have_count(0)
    expect(alpha_card.get_by_text("#3 Fallback", exact=True)).to_be_visible()
    expect(gamma_card.get_by_text("#2 Fallback", exact=True)).to_be_visible()
    expect(judge_card.get_by_text("Default", exact=True)).to_be_visible()
    expect(page.get_by_text("2 default slots")).to_be_visible()

    # Disabling Beta moves it to Inactive in chain and promotes Gamma -> #1, Alpha -> #2.
    beta_card.get_by_role("button", name="Disable").click()
    expect(beta_card.get_by_text("Inactive in chain", exact=True)).to_be_visible()
    expect(gamma_card.get_by_text("#1 Primary", exact=True)).to_be_visible()
    expect(alpha_card.get_by_text("#2 Fallback", exact=True)).to_be_visible()
    assert [m.slug for m in model_resolver.resolve_chain("reference")] == ["chain-ref-gamma", "chain-ref-alpha"]

    beta_card.get_by_role("button", name="Enable").click()
    expect(beta_card.get_by_text("#1 Primary", exact=True)).to_be_visible()
    assert [m.slug for m in model_resolver.resolve_chain("reference")] == [
        "chain-ref-beta", "chain-ref-gamma", "chain-ref-alpha",
    ]
    collector.assert_clean()


def test_m6_probe_live_failover_telemetry_drawer_and_restart_persistence(e2e_workspace, desktop_page, monkeypatch):
    _setup_auth(e2e_workspace)
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        primary = _create_model_api(
            admin_api, slug="live-primary", display_name="Live Primary", provider="openai", model_id="gpt-4o",
            api_key="sk-live-prim-1111", is_default=True, parameters={"fallback_priority": 10, "max_retries": 1},
        )
        _create_model_api(
            admin_api, slug="live-backup", display_name="Live Backup", provider="anthropic", model_id="claude-sonnet-4-6",
            api_key="sk-live-back-2222", is_default=False, parameters={"fallback_priority": 20, "max_retries": 0},
        )

        async def fake_live_fetch(name, method, url, **kwargs):
            if name == "OpenAI":
                raise HTTPException(503, "Primary overloaded")
            return {"stop_reason": "end_turn", "content": [{"type": "text", "text": "Fallback answer"}]}

        monkeypatch.setattr(integrations, "fetch_json", fake_live_fetch)
        live_res = admin_api.post("/api/integrations/reference", json={"role": "SRE", "question": "Explain backpressure."})
        assert live_res.status_code == 200 and live_res.json()["text"] == "Fallback answer"

    probe_latencies = iter([42, 28])
    monkeypatch.setattr(model_probe, "probe_model", lambda row, *, api_key: _async_probe_ok(next(probe_latencies)))

    page, collector = desktop_page
    _sign_in_admin(page, e2e_workspace.base_url)

    fleet_strip = page.get_by_label("Fleet telemetry summary")
    expect(fleet_strip.get_by_text("33.3%")).to_be_visible()
    expect(fleet_strip.get_by_text("1 / 3 checks passed")).to_be_visible()
    expect(fleet_strip.get_by_text("3 checks recorded")).to_be_visible()

    primary_card = page.locator("article.admin-model-card", has_text="Live Primary")
    backup_card = page.locator("article.admin-model-card", has_text="Live Backup")
    expect(backup_card.get_by_text(re.compile(r"Uptime 100\.0%"))).to_be_visible()

    primary_card.get_by_role("button", name="Test connection").click()
    expect(primary_card.get_by_text("connected", exact=True)).to_be_visible()
    expect(fleet_strip.get_by_text("50.0%")).to_be_visible()
    expect(fleet_strip.get_by_text("2 / 4 checks passed")).to_be_visible()
    expect(fleet_strip.get_by_text(re.compile(r"\d+ ms"))).to_be_visible()
    expect(primary_card.get_by_text(re.compile(r"Uptime 33\.3% · Avg \d+ ms · P95 \d+ ms"))).to_be_visible()

    # Open ModelHealthDrawer and inspect probe + live telemetry history.
    health_btn = primary_card.get_by_role("button", name="Health history")
    health_btn.click()
    drawer = page.get_by_role("dialog", name="Health history: Live Primary")
    expect(drawer).to_be_visible()
    summary_section = drawer.get_by_label("Model health summary")
    expect(summary_section.get_by_text("33.3%")).to_be_visible()
    expect(summary_section.get_by_text("1 / 3 ok")).to_be_visible()
    expect(summary_section.get_by_text("Admin probe")).to_be_visible()
    expect(drawer.locator("tbody tr")).to_have_count(3)
    expect(drawer.locator("tbody").get_by_text("probe", exact=True)).to_have_count(1)
    expect(drawer.locator("tbody").get_by_text("live", exact=True)).to_have_count(2)
    expect(drawer.locator("tbody").get_by_text("HTTP 503").first).to_be_visible()
    expect(drawer.locator("tbody").get_by_text("Primary overloaded").first).to_be_visible()

    # Record another probe check via API, then click Refresh inside drawer.
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        assert admin_api.post(f"/api/admin/models/{primary['id']}/probe").status_code == 200
    drawer.get_by_role("button", name="Refresh").click()
    expect(drawer.locator("tbody tr")).to_have_count(4)
    expect(summary_section.get_by_text("50.0%")).to_be_visible()
    expect(summary_section.get_by_text("2 / 4 ok")).to_be_visible()

    # Escape closes drawer and restores focus to the Health history button.
    page.keyboard.press("Escape")
    expect(drawer).to_have_count(0)
    expect(health_btn).to_be_focused()

    # Restart server and verify telemetry strip & health history persist from SQLite.
    page.goto("about:blank")
    e2e_workspace.restart()
    page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Model administration")).to_be_visible()
    fleet_strip = page.get_by_label("Fleet telemetry summary")
    expect(fleet_strip.get_by_text("60.0%")).to_be_visible()
    expect(fleet_strip.get_by_text("3 / 5 checks passed")).to_be_visible()

    primary_card = page.locator("article.admin-model-card", has_text="Live Primary")
    primary_card.get_by_role("button", name="Health history").click()
    drawer = page.get_by_role("dialog", name="Health history: Live Primary")
    expect(drawer.locator("tbody tr")).to_have_count(4)
    expect(drawer.locator("tbody").get_by_text("live", exact=True)).to_have_count(2)
    page.keyboard.press("Escape")
    expect(drawer).to_have_count(0)
    assert "sk-live-" not in page.content()
    collector.assert_clean()


@pytest.mark.parametrize(
    "viewport",
    [(1440, 900, "desktop-1440"), (390, 844, "mobile-390"), (320, 780, "mobile-320")],
    ids=lambda v: v[2],
)
def test_m6_telemetry_admin_responsive_viewports(e2e_workspace, e2e_browser, monkeypatch, viewport):
    width, height, _ = viewport
    _setup_auth(e2e_workspace)
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        m1 = _create_model_api(
            admin_api, slug="resp-primary", display_name="Responsive Primary",
            is_default=True, parameters={"fallback_priority": 10, "max_retries": 2, "rpm_limit": 60},
        )
        _create_model_api(
            admin_api, slug="resp-backup", display_name="Responsive Backup",
            provider="anthropic", model_id="claude-sonnet-4-6", is_default=False, parameters={"fallback_priority": 20},
        )
        monkeypatch.setattr(model_probe, "probe_model", lambda row, *, api_key: _async_probe_ok())
        assert admin_api.post(f"/api/admin/models/{m1['id']}/probe").status_code == 200

    mobile = width <= 480
    ctx = e2e_browser.new_context(
        viewport={"width": width, "height": height}, reduced_motion="reduce", is_mobile=mobile, has_touch=mobile,
    )
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    try:
        _sign_in_admin(page, e2e_workspace.base_url)
        expect(page.get_by_label("Fleet telemetry summary")).to_be_visible()
        expect(page.locator("article.admin-model-card", has_text="Responsive Primary").get_by_text("#1 Primary")).to_be_visible()
        assert_no_horizontal_overflow(page)

        page.locator("article.admin-model-card", has_text="Responsive Primary").get_by_role("button", name="Health history").click()
        drawer = page.get_by_role("dialog", name="Health history: Responsive Primary")
        expect(drawer).to_be_visible()
        expect(drawer.locator("tbody tr")).to_have_count(1)
        assert_no_horizontal_overflow(page)

        page.keyboard.press("Escape")
        expect(drawer).to_have_count(0)
        collector.assert_clean()
    finally:
        ctx.close()
