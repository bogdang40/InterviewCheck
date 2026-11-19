"""Tier 3 opaque-box reload, server restart, and workspace backup persistence tests."""
import json
import re

import pytest
from playwright.sync_api import expect

from e2e_suite.harness import (
    DESKTOP_VIEWPORT,
    IsolatedWorkspace,
    signup_user,
)

ADMIN_EMAIL = "admin-t3-persist@example.test"
BOOTSTRAP_SECRET = "t3-persist-bootstrap-1234"
ADMIN_PASS = "Synthetic-T3-Persist-1"


def _sign_in_admin_browser(page, base_url: str) -> None:
    page.goto(base_url + "/account/", wait_until="domcontentloaded")
    page.get_by_label("Operator email").fill(ADMIN_EMAIL)
    page.get_by_label("Password", exact=True).fill(ADMIN_PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(ADMIN_EMAIL)).to_be_visible()


def _create_role_and_session(page, base_url: str, *, role_name: str, candidate: str) -> str:
    page.goto(base_url + "/roles/", wait_until="domcontentloaded")
    page.get_by_role("button", name="Add role").click()
    page.get_by_label("Role name").fill(role_name)
    page.get_by_label("Description").fill("Distributed systems design and operational readiness.")
    page.get_by_label("Planned questions, one per line").fill("How do you design idempotent retries?")
    page.get_by_role("button", name="Save role").click()
    expect(page.locator(".role-row").get_by_text(role_name, exact=True)).to_be_visible()

    role_row = page.locator(".role-row").filter(has_text=role_name)
    role_row.get_by_role("button", name="Prepare").click()
    expect(page).to_have_url(re.compile(r"/interviews/new/?$"))

    page.get_by_label("Candidate", exact=True).fill(candidate)
    page.get_by_label("Assistance policy").fill("Closed-book live technical discussion.")
    page.get_by_label(re.compile(r"confirmed that the candidate knows")).check()
    page.get_by_role("button", name="Start interview").click()
    expect(page).to_have_url(re.compile(r"/interviews/review/\?id=[0-9a-f-]+"))
    return page.url


@pytest.mark.tier3
def test_role_template_interview_and_answer_review_persist_across_reload_and_restart(e2e_workspace, desktop_page):
    page, collector = desktop_page
    review_url = _create_role_and_session(
        page,
        e2e_workspace.base_url,
        role_name="Staff Platform Engineer",
        candidate="Jordan Rivera",
    )

    page.get_by_role("textbox", name="Question").fill("Explain consensus leader leases.")
    page.get_by_label("Candidate answer").fill(
        "A leader holds a bounded lease using monotonic clocks to serve linearizable reads safely."
    )
    page.get_by_role("button", name="Add source").click()
    page.get_by_label("Source name").fill("Raft Thesis Excerpt")
    page.get_by_label("Source passage").fill("Leaders rely on bounded clock drift for read leases.")
    page.get_by_role("button", name="Save and compare").click()

    expect(page.get_by_role("heading", name="Explain consensus leader leases.")).to_be_visible()
    page.get_by_role("combobox", name=re.compile(r"^Review outcome")).select_option("explained")
    page.get_by_label("Interviewer note").fill("Candidate explained clock drift assumptions accurately.")
    page.get_by_role("button", name="Save review").click()
    expect(page.get_by_text("Review saved")).to_be_visible()

    # Browser reload preserves role, interview, answer, outcome, and note.
    page.reload(wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Jordan Rivera")).to_be_visible()
    expect(page.get_by_text("Staff Platform Engineer")).to_be_visible()
    expect(page.get_by_role("combobox", name=re.compile(r"^Review outcome"))).to_have_value("explained")
    expect(page.get_by_label("Interviewer note")).to_have_value(
        "Candidate explained clock drift assumptions accurately."
    )
    page.wait_for_load_state("networkidle")

    # Full server restart preserves all workspace SQLite records.
    page.goto("about:blank")
    e2e_workspace.restart()
    page.goto(review_url, wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Jordan Rivera")).to_be_visible()
    expect(page.get_by_role("heading", name="Explain consensus leader leases.")).to_be_visible()
    expect(page.get_by_role("combobox", name=re.compile(r"^Review outcome"))).to_have_value("explained")
    expect(page.get_by_label("Interviewer note")).to_have_value(
        "Candidate explained clock drift assumptions accurately."
    )

    page.goto(e2e_workspace.base_url + "/roles/", wait_until="domcontentloaded")
    expect(page.locator(".role-row").get_by_text("Staff Platform Engineer", exact=True)).to_be_visible()
    collector.assert_clean()


@pytest.mark.tier3
def test_connected_models_persist_across_browser_reload_and_server_restart(e2e_workspace, desktop_page):
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)

    page, collector = desktop_page
    _sign_in_admin_browser(page, e2e_workspace.base_url)
    page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Model administration")).to_be_visible()

    secret_one = "sk-tier3-persist-1111"
    secret_two = "sk-tier3-persist-2222"

    # Register OpenAI reference model.
    page.get_by_role("button", name="Connect model").first.click()
    dlg = page.get_by_role("dialog", name="Connect model")
    dlg.get_by_label("Provider").select_option("openai")
    dlg.get_by_label("Display name").fill("Persist OpenAI Ref")
    dlg.get_by_label("Model ID").fill("gpt-4o")
    dlg.get_by_label("API key").fill(secret_one)
    dlg.get_by_role("button", name="Save and connect").click()
    expect(dlg).to_have_count(0)

    # Register Anthropic judge model and disable it.
    page.get_by_role("button", name="Connect model").first.click()
    dlg = page.get_by_role("dialog", name="Connect model")
    dlg.get_by_label("Provider").select_option("anthropic")
    dlg.get_by_role("combobox", name=re.compile(r"^Capability")).select_option("judge")
    dlg.get_by_label("Display name").fill("Persist Claude Judge")
    dlg.get_by_label("Model ID").fill("claude-sonnet-4-6")
    dlg.get_by_label("API key").fill(secret_two)
    dlg.get_by_role("button", name="Save and connect").click()
    expect(dlg).to_have_count(0)

    claude_card = page.locator("article.admin-model-card", has_text="Persist Claude Judge")
    claude_card.get_by_role("button", name="Disable").click()
    expect(claude_card.get_by_text("disabled", exact=True)).to_be_visible()

    # Reload browser page.
    page.reload(wait_until="domcontentloaded")
    expect(page.get_by_text("Persist OpenAI Ref", exact=True)).to_be_visible()
    expect(page.get_by_text("...1111")).to_be_visible()
    expect(page.locator("article.admin-model-card", has_text="Persist Claude Judge").get_by_text("disabled", exact=True)).to_be_visible()
    expect(page.get_by_text("...2222")).to_be_visible()
    page.wait_for_load_state("networkidle")

    # Restart server and verify browser session + encrypted model records persist.
    e2e_workspace.restart()
    page.reload(wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Model administration")).to_be_visible()
    expect(page.get_by_text("Persist OpenAI Ref", exact=True)).to_be_visible()
    expect(page.get_by_text("Persist Claude Judge", exact=True)).to_be_visible()
    expect(page.get_by_text("...1111")).to_be_visible()
    expect(page.get_by_text("...2222")).to_be_visible()
    html_dump = page.content()
    assert secret_one not in html_dump
    assert secret_two not in html_dump
    collector.assert_clean()


@pytest.mark.tier3
def test_workspace_backup_download_excludes_model_secrets_and_restores_into_fresh_workspace(
    tmp_path, monkeypatch, frontend, e2e_browser
):
    ws1 = IsolatedWorkspace(tmp_path / "source", monkeypatch, frontend)
    ws1.prepare_env()
    ws1.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    ws1.start()

    ctx1 = e2e_browser.new_context(viewport=DESKTOP_VIEWPORT, reduced_motion="reduce", accept_downloads=True)
    page1 = ctx1.new_page()
    secret_key = "sk-tier3-backup-exclusion-9999"
    backup_path = tmp_path / "exported-workspace.json"
    try:
        with ws1.client() as c:
            signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
        _sign_in_admin_browser(page1, ws1.base_url)

        # Register connected model with secret key.
        page1.goto(ws1.base_url + "/admin/", wait_until="domcontentloaded")
        page1.get_by_role("button", name="Connect model").first.click()
        dlg = page1.get_by_role("dialog", name="Connect model")
        dlg.get_by_label("Provider").select_option("openai")
        dlg.get_by_label("Display name").fill("Backup Secret Model")
        dlg.get_by_label("Model ID").fill("gpt-4o")
        dlg.get_by_label("Slug (optional, auto-generated if blank)").fill("backup-secret-slug")
        dlg.get_by_label("API key").fill(secret_key)
        dlg.get_by_role("button", name="Save and connect").click()
        expect(dlg).to_have_count(0)

        # Create role and interview session via UI.
        _create_role_and_session(
            page1,
            ws1.base_url,
            role_name="Backup Verify Role",
            candidate="Backup Candidate",
        )
        page1.get_by_role("textbox", name="Question").fill("Describe write-ahead logging.")
        page1.get_by_label("Candidate answer").fill("Mutations append sequentially before page flushes.")
        page1.get_by_role("button", name="Save and compare").click()
        expect(page1.get_by_role("heading", name="Describe write-ahead logging.")).to_be_visible()

        # Download workspace backup from /data/ UI.
        page1.goto(ws1.base_url + "/data/", wait_until="domcontentloaded")
        with page1.expect_download() as dl_info:
            page1.get_by_role("link", name="Download backup").click()
        dl_info.value.save_as(str(backup_path))

        raw_backup = backup_path.read_text(encoding="utf-8")
        parsed = json.loads(raw_backup)
        assert parsed["format"] == "interviewcheck.workspace"
        assert len(parsed["roles"]) == 1
        assert len(parsed["sessions"]) == 1
        for forbidden in (
            "connected_models",
            "encrypted_api_key",
            "key_hint",
            secret_key,
            "9999",
            "backup-secret-slug",
            "Backup Secret Model",
            "e2e-deterministic-test-secret-key",
        ):
            assert forbidden not in raw_backup
    finally:
        ctx1.close()
        ws1.stop()

    # Restore exported JSON into a completely fresh workspace via /data/ UI.
    ws2 = IsolatedWorkspace(tmp_path / "target", monkeypatch, frontend)
    ws2.prepare_env()
    ws2.start()
    ctx2 = e2e_browser.new_context(viewport=DESKTOP_VIEWPORT, reduced_motion="reduce")
    page2 = ctx2.new_page()
    try:
        page2.goto(ws2.base_url + "/data/", wait_until="networkidle")
        backup_input = page2.get_by_label("Workspace backup file")
        expect(backup_input).to_have_attribute("data-hydrated", "true")
        backup_input.set_input_files(str(backup_path))
        preview_btn = page2.get_by_role("button", name="Preview restore")
        expect(preview_btn).to_be_enabled()
        preview_btn.click()
        expect(page2.get_by_role("heading", name="Restore preview")).to_be_visible()
        expect(page2.get_by_text("1 captured exchanges")).to_be_visible()

        page2.get_by_role("button", name="Restore new records").click()
        expect(page2.get_by_role("status").filter(has_text="Restored 1 interviews and 1 roles")).to_be_visible()

        page2.goto(ws2.base_url + "/interviews/", wait_until="domcontentloaded")
        expect(page2.get_by_text("Backup Candidate")).to_be_visible()
        page2.goto(ws2.base_url + "/roles/", wait_until="domcontentloaded")
        expect(page2.locator(".role-row").get_by_text("Backup Verify Role", exact=True)).to_be_visible()
    finally:
        ctx2.close()
        ws2.stop()


@pytest.mark.tier3
def test_saved_draft_persists_across_reload_and_server_restart(e2e_workspace, desktop_page):
    page, collector = desktop_page
    page.goto(e2e_workspace.base_url + "/interviews/new/", wait_until="domcontentloaded")
    page.get_by_label("Candidate", exact=True).fill("Draft Candidate")
    page.get_by_role("textbox", name="Role").fill("Security Reviewer")
    page.get_by_label("Assistance policy").fill("Standard review notes permitted.")
    page.get_by_label(re.compile(r"confirmed that the candidate knows")).check()
    page.get_by_role("button", name="Start interview").click()
    expect(page).to_have_url(re.compile(r"/interviews/review/\?id=[0-9a-f-]+"))
    review_url = page.url

    page.get_by_role("textbox", name="Question").fill("How do you rotate session keys?")
    page.get_by_label("Candidate answer").fill("Issue a new token and revoke active tokens in SQLite.")
    page.get_by_role("button", name="Save draft").click()
    expect(page.get_by_text("Saved exchange draft")).to_be_visible()

    page.reload(wait_until="domcontentloaded")
    expect(page.get_by_text("Saved exchange draft")).to_be_visible()
    page.wait_for_load_state("networkidle")

    page.goto("about:blank")
    e2e_workspace.restart()
    page.goto(review_url, wait_until="domcontentloaded")
    expect(page.get_by_text("Saved exchange draft")).to_be_visible()
    page.get_by_role("button", name="Resume draft").click()
    expect(page.get_by_role("textbox", name="Question")).to_have_value("How do you rotate session keys?")
    expect(page.get_by_label("Candidate answer")).to_have_value(
        "Issue a new token and revoke active tokens in SQLite."
    )
    collector.assert_clean()
