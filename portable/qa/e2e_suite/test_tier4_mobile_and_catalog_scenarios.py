"""Tier 4 scenarios: Mobile Field Review & Backup Restore, Role Import & Connection Catalog."""
import json
import re

import pytest
from playwright.sync_api import expect

from e2e_suite.harness import (
    ConsoleErrorCollector,
    DESKTOP_VIEWPORT,
    IsolatedWorkspace,
    MOBILE_VIEWPORT,
    assert_no_horizontal_overflow,
    capture_screenshot,
    signup_user,
)

ADMIN_EMAIL = "admin-t4-mob@example.test"
BOOTSTRAP_SECRET = "t4-mob-bootstrap-1234"
ADMIN_PASS = "Synthetic-T4-Mob-Pass"


def _open_mobile_context(browser, *, accept_downloads: bool = False):
    ctx = browser.new_context(
        viewport=MOBILE_VIEWPORT,
        reduced_motion="reduce",
        is_mobile=True,
        has_touch=True,
        accept_downloads=accept_downloads,
    )
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    page.set_default_navigation_timeout(30_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    return ctx, page, collector


def _sign_in_account(page, base_url: str) -> None:
    page.goto(base_url + "/account/", wait_until="domcontentloaded")
    page.get_by_label("Operator email").fill(ADMIN_EMAIL)
    page.get_by_label("Password", exact=True).fill(ADMIN_PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(ADMIN_EMAIL)).to_be_visible()


@pytest.mark.tier4
def test_scenario_d_mobile_field_review_backup_restore_and_multi_route_audit(
    tmp_path, monkeypatch, frontend, e2e_browser
):
    ws1 = IsolatedWorkspace(tmp_path / "mobile_src", monkeypatch, frontend)
    ws1.prepare_env()
    ws1.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    ws1.start()

    secret_key = "sk-t4-mobile-secret-8899"
    backup_path = tmp_path / "mobile-workspace-backup.json"
    ctx1, page1, col1 = _open_mobile_context(e2e_browser, accept_downloads=True)
    try:
        with ws1.client() as admin:
            signup_user(admin, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
            m = admin.post(
                "/api/admin/models",
                json={
                    "slug": "t4-mobile-model",
                    "display_name": "T4 Mobile Secret Model",
                    "provider": "openai",
                    "capability": "reference",
                    "model_id": "gpt-4o",
                    "apiKey": secret_key,
                },
            )
            assert m.status_code == 201
            role = admin.post(
                "/api/roles",
                json={
                    "name": "Mobile Field Role",
                    "description": "Mobile audit readiness.",
                    "questions": ["How do you verify field backups?"],
                },
            )
            assert role.status_code == 201
            sess = admin.post(
                "/api/sessions",
                json={
                    "candidate": "Mobile Candidate",
                    "role": "Mobile Field Role",
                    "role_id": role.json()["id"],
                    "policy": "Field notes allowed.",
                    "consent": True,
                },
            )
            assert sess.status_code == 201
            sid = sess.json()["id"]
            ans = admin.post(
                f"/api/sessions/{sid}/answers",
                json={
                    "question": "How do you verify field backups?",
                    "answer": "Restore into a clean workspace and verify record counts.",
                },
            )
            assert ans.status_code == 201

        _sign_in_account(page1, ws1.base_url)
        assert_no_horizontal_overflow(page1)
        capture_screenshot(page1, ws1.screenshot_dir, "tier4_mobile_account", "390x844")

        # Navigate across all workspace and admin routes via the mobile drawer.
        page1.goto(ws1.base_url + "/", wait_until="domcontentloaded")
        toggle = page1.get_by_role("button", name="Open navigation menu")
        nav = page1.get_by_role("navigation", name="Workspace")
        sidebar = page1.locator("aside.sidebar")

        routes = (
            ("Interviews", r"/interviews/?$", "Interviews", "interviews"),
            ("Role library", r"/roles/?$", "Role library", "roles"),
            ("Connections", r"/connections/?$", "Connections", "connections"),
            ("Admin", r"/admin/?$", "Model administration", "admin"),
            ("Overview", r"/$", "Interview workspace", "overview"),
            ("Data", r"/data/?$", "Workspace data", "data"),
        )
        for label, url_pat, heading, slug in routes:
            toggle.click()
            nav.get_by_role("link", name=label, exact=True).click()
            expect(page1).to_have_url(re.compile(url_pat))
            expect(page1.get_by_role("heading", name=heading).first).to_be_visible()
            expect(sidebar).not_to_have_class(re.compile(r"\bopen\b"))
            assert_no_horizontal_overflow(page1)
            capture_screenshot(page1, ws1.screenshot_dir, f"tier4_mobile_{slug}", "390x844")

        # Create workspace backup on /data/ from mobile viewport and confirm key exclusion.
        with page1.expect_download() as dl:
            page1.get_by_role("link", name="Download backup").click()
        dl.value.save_as(str(backup_path))

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
            "8899",
            "t4-mobile-model",
            "e2e-deterministic-test-secret-key",
        ):
            assert forbidden not in raw_backup
        col1.assert_clean()
    finally:
        ctx1.close()
        ws1.stop()

    # Restore backup into a clean IsolatedWorkspace on mobile viewport.
    ws2 = IsolatedWorkspace(tmp_path / "mobile_dst", monkeypatch, frontend)
    ws2.prepare_env()
    ws2.start()
    ctx2, page2, col2 = _open_mobile_context(e2e_browser)
    try:
        page2.goto(ws2.base_url + "/data/", wait_until="networkidle")
        assert_no_horizontal_overflow(page2)
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

        toggle2 = page2.get_by_role("button", name="Open navigation menu")
        nav2 = page2.get_by_role("navigation", name="Workspace")
        for label, url_pat, expected_text in (
            ("Interviews", r"/interviews/?$", "Mobile Candidate"),
            ("Role library", r"/roles/?$", "Mobile Field Role"),
        ):
            toggle2.click()
            nav2.get_by_role("link", name=label, exact=True).click()
            expect(page2).to_have_url(re.compile(url_pat))
            expect(page2.get_by_text(expected_text, exact=True)).to_be_visible()
            assert_no_horizontal_overflow(page2)
        col2.assert_clean()
    finally:
        ctx2.close()
        ws2.stop()


@pytest.mark.tier4
def test_scenario_f_role_import_export_and_connection_catalog_setup_flow(e2e_workspace, e2e_browser, monkeypatch):
    workable_secret = "wk-t4-secret-9988"
    monkeypatch.setenv("WORKABLE_API_KEY", workable_secret)
    monkeypatch.setenv("WORKABLE_SUBDOMAIN", "t4-fixture-tenant")
    monkeypatch.delenv("WORKABLE_MEMBER_ID", raising=False)
    e2e_workspace.restart()

    ctx = e2e_browser.new_context(viewport=DESKTOP_VIEWPORT, reduced_motion="reduce")
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    page.set_default_navigation_timeout(30_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)

    role_template = {
        "format": "interviewcheck.role",
        "version": 1,
        "role": {
            "workspaceID": "t4-role-template-01",
            "name": "Staff Security Engineer",
            "company": "StarkTech",
            "jobDescription": "Threat modeling and workload isolation.",
            "plannedQuestions": [
                {"text": "How do you isolate untrusted workloads?"},
                {"text": "How do you audit secret rotation?"},
            ],
        },
    }
    role_fixture = {
        "name": "staff-security.json",
        "mimeType": "application/json",
        "buffer": json.dumps(role_template).encode("utf-8"),
    }
    expected_role_title = "Staff Security Engineer at StarkTech"

    try:
        # 1. Import role template on /roles/, verify duplicate guard and export snapshot.
        page.goto(e2e_workspace.base_url + "/roles/", wait_until="domcontentloaded")
        page.get_by_text("Import a role file", exact=True).click()
        upload = page.get_by_label("Native role export")
        upload.set_input_files(role_fixture)
        expect(page.get_by_text("2 planned questions.", exact=True)).to_be_visible()
        page.get_by_role("button", name="Import role", exact=True).click()
        expect(page.get_by_text("Role available in the library.")).to_be_visible()
        expect(page.locator(".role-row", has_text=expected_role_title)).to_be_visible()

        upload.set_input_files(role_fixture)
        expect(page.get_by_text("This role is already in the library.")).to_be_visible()

        with e2e_workspace.client() as c:
            roles_list = c.get("/api/roles").json()
            imported_role = next(r for r in roles_list if r["name"] == expected_role_title)
            backup_doc = c.get("/api/backups/workspace").json()
            assert any(r["id"] == imported_role["id"] for r in backup_doc["roles"])

        # Prepare directly from the imported role card and confirm prefilled setup.
        page.locator(".role-row", has_text=expected_role_title).get_by_role("button", name="Prepare").click()
        expect(page).to_have_url(re.compile(r"/interviews/new/?$"))
        expect(page.get_by_label("Saved role template")).to_have_value(imported_role["id"])
        expect(page.get_by_text("Planned questions (2)")).to_be_visible()

        # 2. Inspect ConnectionCatalog setup states and import ATS candidate on /connections/.
        page.goto(e2e_workspace.base_url + "/connections/", wait_until="domcontentloaded")
        page.get_by_label("Search provider or task").fill("Workable")
        expect(page.get_by_label("Setup provider")).to_have_value("workable")
        lookup_op = page.locator("summary").filter(has_text="Find a candidate by email")
        expect(lookup_op).to_contain_text("Configured")
        note_op = page.locator("summary").filter(has_text="Send a reviewed private note")
        expect(note_op).to_contain_text("Needs setup")
        note_op.click()
        expect(note_op.locator("..").get_by_text("WORKABLE_MEMBER_ID", exact=True)).to_be_visible()
        assert workable_secret not in page.content()

        ats_csv = "candidate,role\nMaya Patel,Staff Security Engineer at StarkTech\n".encode("utf-8")
        page.get_by_label("Import candidates from CSV").set_input_files(
            {"name": "candidates.csv", "mimeType": "text/csv", "buffer": ats_csv}
        )
        expect(page.get_by_text("Maya Patel", exact=True)).to_be_visible()
        page.get_by_role("button", name="Select", exact=True).click()
        page.get_by_role("button", name="Prepare interview", exact=True).click()

        # 3. Link imported role template with imported candidate and verify session linkage.
        expect(page).to_have_url(re.compile(r"/interviews/new/?$"))
        expect(page.get_by_label("Candidate", exact=True)).to_have_value("Maya Patel")
        page.get_by_label("Saved role template").select_option(imported_role["id"])
        expect(page.get_by_label("Candidate", exact=True)).to_have_value("Maya Patel")
        page.get_by_label("Assistance policy").fill("Approved reference docs only.")
        page.get_by_label(re.compile(r"confirmed that the candidate knows")).check()
        page.get_by_role("button", name="Start interview").click()
        expect(page).to_have_url(re.compile(r"/interviews/review/\?id=[0-9a-f-]+"))
        sid = page.url.split("id=")[-1].split("&")[0]

        page.get_by_role("combobox", name="Planned question", exact=True).select_option("1")
        page.get_by_label("Candidate answer").fill("Run workloads in microVMs with strict seccomp filters.")
        page.get_by_role("button", name="Save and compare").click()
        expect(page.get_by_role("heading", name="How do you isolate untrusted workloads?")).to_be_visible()

        with e2e_workspace.client() as c:
            session_data = c.get(f"/api/sessions/{sid}").json()
            assert session_data["candidate"] == "Maya Patel"
            assert session_data["role"] == expected_role_title
            assert session_data["role_id"] == imported_role["id"]
            assert session_data["planned_questions"] == [
                "How do you isolate untrusted workloads?",
                "How do you audit secret rotation?",
            ]
            assert session_data["answers"][0]["planned_slot"] == 1
        collector.assert_clean()
    finally:
        ctx.close()
