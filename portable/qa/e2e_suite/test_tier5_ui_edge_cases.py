"""Tier 5 adversarial Playwright UI tests: T5-12 429 rate-limit, T5-13 Admin UI edges, and T5-16."""
import re

from playwright.sync_api import expect
import pytest

from e2e_suite.harness import (
    ConsoleErrorCollector,
    DESKTOP_VIEWPORT,
    MOBILE_VIEWPORT,
    assert_no_horizontal_overflow,
    signup_user,
)

ADMIN_EMAIL = "admin-edge-t5@example.test"
BOOTSTRAP_SECRET = "t5-edge-bootstrap-1234"
ADMIN_PASS = "Synthetic-T5-Edge-Pass-1"

LEGACY_HASH_TARGETS = (
    ("overview", "/", "Interview workspace"),
    ("interviews", "/interviews/", "Interviews"),
    ("roles", "/roles/", "Role library"),
    ("connections", "/connections/", "Connections"),
    ("new", "/interviews/new/", "New interview"),
    ("sample", "/sample/", "Sample review"),
)


def _open_context(browser, *, mobile: bool = False):
    viewport = MOBILE_VIEWPORT if mobile else DESKTOP_VIEWPORT
    ctx = browser.new_context(viewport=viewport, reduced_motion="reduce", is_mobile=mobile, has_touch=mobile)
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    page.set_default_navigation_timeout(30_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    return ctx, page, collector


def _sign_in_admin(page, base_url: str) -> None:
    page.goto(base_url + "/admin/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Administrator sign in required")).to_be_visible()
    page.get_by_label("Operator email").fill(ADMIN_EMAIL)
    page.get_by_label("Password", exact=True).fill(ADMIN_PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_role("heading", name="Model administration")).to_be_visible()


def test_t5_12_probe_rate_limit_429_banner(e2e_workspace, desktop_page):
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    missing_id = "00000000-0000-4000-8000-000000000000"
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
        for _ in range(15):
            assert c.post(f"/api/admin/models/{missing_id}/probe").status_code == 404

    page, collector = desktop_page
    _sign_in_admin(page, e2e_workspace.base_url)
    page.get_by_role("button", name="Connect model").first.click()
    dlg = page.get_by_role("dialog", name="Connect model")
    dlg.get_by_label("Provider").select_option("openai")
    dlg.get_by_label("Display name").fill("Rate Limit Model")
    dlg.get_by_label("Model ID").fill("gpt-4o")
    dlg.get_by_label("Slug (optional, auto-generated if blank)").fill("rate-limit-model")
    dlg.get_by_label("API key").fill("sk-ratelimit-1111")
    dlg.get_by_role("button", name="Save and connect").click()
    expect(dlg).to_have_count(0)

    card = page.locator("article.admin-model-card", has_text="Rate Limit Model")
    card.get_by_role("button", name="Test connection").click()
    expect(page.locator(".admin-console > p[role='alert']")).to_contain_text(
        "Too many requests. Try again in a minute."
    )
    assert not collector.page_errors and not collector.server_errors
    page.wait_for_timeout(150)
    assert all("429" in msg for msg in collector.console_errors), collector.console_errors
    collector.reset()
    e2e_workspace.restart()
    collector.assert_clean()


def test_t5_13_azure_openai_lifecycle_provider_switch_validation_and_duplicate_slug(e2e_workspace, desktop_page):
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)

    page, collector = desktop_page
    _sign_in_admin(page, e2e_workspace.base_url)

    page.get_by_role("button", name="Connect model").first.click()
    dlg = page.get_by_role("dialog", name="Connect model")

    # Provider switch clears stale endpoint and api_version fields.
    dlg.get_by_label("Provider").select_option("azure_openai")
    dlg.get_by_label("Endpoint URL (HTTPS)").fill("https://docs.openai.azure.com")
    dlg.get_by_label("Azure API version").fill("2024-10-21")
    dlg.get_by_label("Provider").select_option("openai_compatible")
    expect(dlg.get_by_label("Azure API version")).to_have_count(0)
    dlg.get_by_label("Provider").select_option("azure_openai")
    expect(dlg.get_by_label("Azure API version")).to_have_value("")

    dlg.get_by_label("Azure API version").fill("2024-10-21")
    dlg.get_by_label("Provider").select_option("openai")
    expect(dlg.get_by_label("Endpoint URL (HTTPS)")).to_have_count(0)
    expect(dlg.get_by_label("Azure API version")).to_have_count(0)
    dlg.get_by_label("Provider").select_option("azure_openai")
    expect(dlg.get_by_label("Endpoint URL (HTTPS)")).to_have_value("")
    expect(dlg.get_by_label("Azure API version")).to_have_value("")

    # Client-side validation catches non-integer scientific notation in Max tokens before API call.
    dlg.get_by_label("Display name").fill("Azure Primary")
    dlg.get_by_label("Model ID").fill("gpt-4o-deploy")
    dlg.get_by_label("Slug (optional, auto-generated if blank)").fill("azure-primary")
    dlg.get_by_label("Endpoint URL (HTTPS)").fill("https://docs.openai.azure.com")
    dlg.get_by_label("Azure API version").fill("2024-10-21")
    dlg.get_by_label("API key").fill("sk-azure-secret-1111")
    dlg.get_by_label("Max tokens (1 to 128000)").fill("1e2")
    dlg.get_by_role("button", name="Save and connect").click()
    expect(dlg.locator("p[role='alert']")).to_contain_text("Max tokens must be a whole integer between 1 and 128000.")

    # Fix Max tokens and create Azure OpenAI model.
    dlg.get_by_label("Max tokens (1 to 128000)").fill("1024")
    dlg.get_by_role("button", name="Save and connect").click()
    expect(dlg).to_have_count(0)

    azure_card = page.locator("article.admin-model-card", has_text="Azure Primary")
    expect(azure_card.get_by_text("https://docs.openai.azure.com")).to_be_visible()
    expect(azure_card.get_by_text("Azure OpenAI")).to_be_visible()

    # Edit Azure OpenAI endpoint and api_version, then verify persistence across reload.
    azure_card.get_by_role("button", name="Configure").click()
    edit_dlg = page.get_by_role("dialog")
    expect(edit_dlg.get_by_label("Endpoint URL (HTTPS)")).to_have_value("https://docs.openai.azure.com")
    expect(edit_dlg.get_by_label("Azure API version")).to_have_value("2024-10-21")
    edit_dlg.get_by_label("Endpoint URL (HTTPS)").fill("https://api.cognitiveservices.azure.com")
    edit_dlg.get_by_label("Azure API version").fill("2025-01-01-preview")
    edit_dlg.get_by_role("button", name="Save configuration").click()
    expect(edit_dlg).to_have_count(0)
    expect(azure_card.get_by_text("https://api.cognitiveservices.azure.com")).to_be_visible()

    page.reload(wait_until="domcontentloaded")
    azure_card = page.locator("article.admin-model-card", has_text="Azure Primary")
    azure_card.get_by_role("button", name="Configure").click()
    edit_dlg = page.get_by_role("dialog")
    expect(edit_dlg.get_by_label("Endpoint URL (HTTPS)")).to_have_value("https://api.cognitiveservices.azure.com")
    expect(edit_dlg.get_by_label("Azure API version")).to_have_value("2025-01-01-preview")
    edit_dlg.get_by_role("button", name="Cancel").click()
    expect(edit_dlg).to_have_count(0)

    # Duplicate slug returns 409 alert inside modal without closing or crashing.
    page.get_by_role("button", name="Connect model").first.click()
    dup_dlg = page.get_by_role("dialog", name="Connect model")
    dup_dlg.get_by_label("Provider").select_option("openai")
    dup_dlg.get_by_label("Display name").fill("Duplicate Slug Test")
    dup_dlg.get_by_label("Model ID").fill("gpt-4o")
    dup_dlg.get_by_label("Slug (optional, auto-generated if blank)").fill("azure-primary")
    dup_dlg.get_by_label("API key").fill("sk-dup-slug-2222")
    dup_dlg.get_by_role("button", name="Save and connect").click()
    expect(dup_dlg.locator("p[role='alert']")).to_contain_text("A model with that slug already exists.")
    dup_dlg.get_by_role("button", name="Cancel").click()

    assert not collector.page_errors and not collector.server_errors
    page.wait_for_timeout(150)
    assert all("409" in msg for msg in collector.console_errors), collector.console_errors
    collector.reset()
    collector.assert_clean()


def test_t5_13_status_filter_empty_state_disconnect_cancel_and_env_fallbacks(e2e_workspace, desktop_page):
    e2e_workspace.monkeypatch.setenv("OPENAI_API_KEY", "sk-env-fallback-demo-9999")
    e2e_workspace.monkeypatch.setenv("INTERVIEWCHECK_REFERENCE_MODEL", "gpt-4o-mini")
    e2e_workspace.monkeypatch.setenv("INTERVIEWCHECK_EMBEDDING_MODEL", "text-embedding-3-small")
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
        c.post(
            "/api/admin/models",
            json={
                "slug": "filter-unverified", "display_name": "Filter Unverified Model",
                "provider": "openai", "capability": "reference", "model_id": "gpt-4o",
                "apiKey": "sk-filter-1111", "parameters": {"timeout_s": 2},
            },
        ).raise_for_status()
        c.post(
            "/api/admin/models",
            json={
                "slug": "filter-disabled", "display_name": "Filter Disabled Model",
                "provider": "anthropic", "capability": "judge", "model_id": "claude-sonnet-4-6",
                "apiKey": "sk-filter-2222", "enabled": False,
            },
        ).raise_for_status()
        c.post(
            "/api/admin/models",
            json={
                "slug": "filter-error", "display_name": "Filter Error Model",
                "provider": "deepgram", "capability": "transcription", "model_id": "nova-2",
                "apiKey": "sk-filter-3333", "parameters": {"timeout_s": 1},
            },
        ).raise_for_status()

    page, collector = desktop_page
    _sign_in_admin(page, e2e_workspace.base_url)

    # Probe Deepgram model to place it into status="error".
    collector.ignore_server_5xx = True
    err_card = page.locator("article.admin-model-card", has_text="Filter Error Model")
    err_card.get_by_role("button", name="Test connection").click()
    expect(err_card.get_by_text("error", exact=True)).to_be_visible(timeout=12_000)
    page.wait_for_timeout(150)
    collector.ignore_server_5xx = False
    collector.reset()

    status_select = page.get_by_label("Status filter")
    for status_val, expected_name in (
        ("unverified", "Filter Unverified Model"),
        ("disabled", "Filter Disabled Model"),
        ("error", "Filter Error Model"),
    ):
        status_select.select_option(status_val)
        expect(page.locator("article.admin-model-card")).to_have_count(1)
        expect(page.get_by_text(expected_name, exact=True)).to_be_visible()

    status_select.select_option("connected")
    expect(page.locator("article.admin-model-card")).to_have_count(0)
    expect(page.get_by_text("No models match the active filters", exact=True)).to_be_visible()
    status_select.select_option("")
    expect(page.locator("article.admin-model-card")).to_have_count(3)

    # Disconnect -> Cancel abort flow keeps model intact across reload.
    unverified_card = page.locator("article.admin-model-card", has_text="Filter Unverified Model")
    unverified_card.get_by_role("button", name="Disconnect").click()
    confirm_region = unverified_card.get_by_role("region", name="Confirm disconnect Filter Unverified Model")
    expect(confirm_region).to_be_visible()
    confirm_region.get_by_role("button", name="Cancel").click()
    expect(confirm_region).to_have_count(0)
    page.reload(wait_until="domcontentloaded")
    expect(page.locator("article.admin-model-card", has_text="Filter Unverified Model")).to_be_visible()

    # Expand Environment fallbacks <details> table and verify Configured / Overridden vs Fallback eligible.
    details = page.locator("details", has_text="Environment fallbacks")
    details.locator("summary").click()
    expect(details).to_have_attribute("open", "")
    ref_row = details.locator("tbody tr").filter(has_text="OpenAI").filter(has_text="Reference answers")
    expect(ref_row.get_by_text("Configured", exact=True)).to_be_visible()
    expect(ref_row.get_by_text("Overridden by registry", exact=True)).to_be_visible()
    emb_row = details.locator("tbody tr").filter(has_text="OpenAI").filter(has_text="Embeddings")
    expect(emb_row.get_by_text("Configured", exact=True)).to_be_visible()
    expect(emb_row.get_by_text("Fallback eligible", exact=True)).to_be_visible()
    anth_row = details.locator("tbody tr").filter(has_text="Anthropic").filter(has_text="Reference answers")
    expect(anth_row.get_by_text("Not configured", exact=True)).to_be_visible()
    expect(anth_row.get_by_text("Fallback eligible", exact=True)).to_be_visible()
    assert "sk-env-fallback-demo-9999" not in page.content()
    collector.assert_clean()


def test_t5_16_password_change_form_validation_and_wrong_current_password(e2e_workspace, desktop_page):
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)

    page, collector = desktop_page
    page.goto(e2e_workspace.base_url + "/account/", wait_until="domcontentloaded")
    page.get_by_label("Operator email").fill(ADMIN_EMAIL)
    page.get_by_label("Password", exact=True).fill(ADMIN_PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(ADMIN_EMAIL)).to_be_visible()

    pw_form = page.get_by_role("form", name="Change password")
    cur = pw_form.get_by_label("Current password")
    new_pw = pw_form.get_by_label("New password", exact=True)
    confirm_pw = pw_form.get_by_label("Confirm new password")
    submit_btn = pw_form.get_by_role("button", name="Update password")

    # 1. < 10 characters: verify client-side rejection (native minLength tooShort OR custom alert).
    cur.fill(ADMIN_PASS)
    new_pw.fill("short")
    confirm_pw.fill("short")
    submit_btn.click()
    too_short = new_pw.evaluate("el => el.validity.tooShort")
    has_alert = pw_form.locator("p[role='alert']").count() > 0
    assert too_short or has_alert

    # 2. Confirmation mismatch >= 10 chars triggers PasswordChangeForm custom alert.
    cur.fill(ADMIN_PASS)
    new_pw.fill("Valid-New-Pass-1")
    confirm_pw.fill("Valid-New-Pass-2")
    submit_btn.click()
    expect(pw_form.locator("p[role='alert']")).to_contain_text("New password and confirmation do not match.")

    # 3. Wrong current password triggers backend 401 alert.
    cur.fill("Wrong-Current-Pass-1")
    new_pw.fill("Valid-New-Pass-1")
    confirm_pw.fill("Valid-New-Pass-1")
    submit_btn.click()
    expect(pw_form.locator("p[role='alert']")).to_contain_text("Current password is incorrect.")

    assert not collector.page_errors and not collector.server_errors
    page.wait_for_timeout(150)
    assert all("401" in msg for msg in collector.console_errors), collector.console_errors
    collector.reset()
    collector.assert_clean()


@pytest.mark.parametrize("mobile", [False, True], ids=["desktop-1440", "mobile-390"])
def test_t5_16_legacy_hash_bookmark_redirects(e2e_workspace, e2e_browser, mobile):
    with e2e_workspace.client() as c:
        sess = c.post(
            "/api/sessions",
            json={"candidate": "Bookmark Candidate", "role": "Staff", "policy": "Rubric", "consent": True},
        )
        assert sess.status_code == 201
        sid = sess.json()["id"]

    ctx, page, collector = _open_context(e2e_browser, mobile=mobile)
    try:
        for hash_name, expected_path, expected_heading in LEGACY_HASH_TARGETS:
            page.goto(f"{e2e_workspace.base_url}/#{hash_name}", wait_until="domcontentloaded")
            expect(page).to_have_url(re.compile(re.escape(expected_path) + r"$"))
            expect(page.get_by_role("heading", name=expected_heading).first).to_be_visible()
            assert_no_horizontal_overflow(page)

        page.goto(f"{e2e_workspace.base_url}/#session/{sid}", wait_until="domcontentloaded")
        expect(page).to_have_url(re.compile(rf"/interviews/review/\?id={re.escape(sid)}$"))
        expect(page.get_by_text("Bookmark Candidate").first).to_be_visible()
        assert_no_horizontal_overflow(page)
        collector.assert_clean()
    finally:
        ctx.close()
