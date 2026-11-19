"""Opaque-box Playwright E2E tests for M18 TOTP 2FA, audit hash chaining, and CSP reporting."""
import re
import time

from playwright.sync_api import expect
import pytest

from api import account_db, model_registry, store, totp_service
from e2e_suite.harness import ConsoleErrorCollector, assert_no_horizontal_overflow, login_user, signup_user

ADMIN_EMAIL = "admin-m18@example.test"
MEMBER_EMAIL = "member-m18@example.test"
BOOTSTRAP_SECRET = "m18-bootstrap-secret-1234"
ADMIN_PASS = "Synthetic-M18-Admin-Pass-1"
MEMBER_PASS = "Synthetic-M18-Member-Pass-1"


def _setup_auth(e2e_workspace, *, include_member: bool = True) -> None:
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
        if include_member:
            signup_user(c, email=MEMBER_EMAIL, password=MEMBER_PASS)


def _sign_in_form(page, url: str, email: str, password: str, *, expected_heading: str | None = None) -> None:
    page.goto(url, wait_until="domcontentloaded")
    if expected_heading:
        expect(page.get_by_role("heading", name=expected_heading)).to_be_visible()
    page.get_by_label("Operator email").fill(email)
    page.get_by_label("Password", exact=True).fill(password)
    page.get_by_role("button", name="Sign in", exact=True).click()


def _assert_no_secrets(page, *secrets: str) -> None:
    html = page.content()
    for secret in (*secrets, ADMIN_PASS, MEMBER_PASS, BOOTSTRAP_SECRET, "e2e-deterministic-test-secret-key"):
        if secret:
            assert secret not in html


def _assert_expected_401(collector: ConsoleErrorCollector) -> None:
    assert not collector.page_errors and not collector.server_errors
    assert len(collector.console_errors) == 1 and "401" in collector.console_errors[0]
    collector.reset()


def _wait_security_idle(page) -> None:
    expect(page.get_by_text("Loading active sessions...")).to_have_count(0)
    expect(page.get_by_text("Loading API tokens...")).to_have_count(0)


def test_m18_totp_setup_challenge_backup_and_disable_e2e(e2e_workspace, desktop_page):
    _setup_auth(e2e_workspace, include_member=True)
    with e2e_workspace.client() as anon:
        assert anon.get("/api/integrations/security/totp/status").status_code == 401
        assert anon.post("/api/integrations/security/totp/setup").status_code == 401

    page, collector = desktop_page
    _sign_in_form(page, e2e_workspace.base_url + "/account/", MEMBER_EMAIL, MEMBER_PASS)
    expect(page.get_by_text(MEMBER_EMAIL)).to_be_visible()

    totp_section = page.locator("section[aria-label='Two-factor authentication']")
    expect(totp_section.get_by_text("Disabled", exact=True)).to_be_visible()
    totp_section.get_by_role("button", name="Enable 2FA").click()

    expect(totp_section.get_by_text("Manual secret (InterviewCheck)")).to_be_visible()
    codes = totp_section.locator("code")
    secret = codes.nth(0).inner_text().strip()
    otpauth_uri = codes.nth(1).inner_text().strip()
    assert re.fullmatch(r"[A-Z2-7]{16,}", secret)
    assert otpauth_uri.startswith("otpauth://totp/InterviewCheck:")
    assert f"secret={secret}" in otpauth_uri and "issuer=InterviewCheck" in otpauth_uri

    if (time.time() % 30) > 26.0:
        time.sleep(30.2 - (time.time() % 30))
    totp_section.get_by_label("Verification code (6 digits)").fill(totp_service.generate_totp_code(secret, step_offset=-1))
    totp_section.get_by_role("button", name="Verify and enable").click()

    expect(totp_section.get_by_text("Two-factor authentication is now enabled.")).to_be_visible()
    expect(totp_section.get_by_text("Enabled", exact=True)).to_be_visible()
    backup_banner = totp_section.locator("div.notice", has_text="Save these single-use backup codes now.")
    expect(backup_banner).to_be_visible()
    initial_codes = [backup_banner.locator("code").nth(i).inner_text().strip() for i in range(8)]
    assert all(re.fullmatch(r"[A-Z2-9]{4}-[A-Z2-9]{4}", c) for c in initial_codes)

    totp_section.get_by_role("button", name="Regenerate backup codes").click()
    totp_section.get_by_label("Authenticator code (6 digits)").fill(totp_service.generate_totp_code(secret, step_offset=0))
    totp_section.get_by_role("button", name="Confirm regenerate").click()
    expect(totp_section.get_by_text("Generated 8 new single-use backup codes.")).to_be_visible()
    regen_banner = totp_section.locator("div.notice", has_text="Save these single-use backup codes now.")
    regen_codes = [regen_banner.locator("code").nth(i).inner_text().strip() for i in range(8)]
    assert set(regen_codes) != set(initial_codes)
    assert all(re.fullmatch(r"[A-Z2-9]{4}-[A-Z2-9]{4}", c) for c in regen_codes)
    _assert_no_secrets(page, secret)

    _wait_security_idle(page)
    page.get_by_role("button", name="Sign out").click()
    expect(page.get_by_role("button", name="Sign in", exact=True)).to_be_visible()

    page.get_by_label("Operator email").fill(MEMBER_EMAIL)
    page.get_by_label("Password", exact=True).fill(MEMBER_PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text("Two-factor authentication is required.")).to_be_visible()
    _assert_expected_401(collector)

    login_code = totp_service.generate_totp_code(secret, step_offset=1)
    page.get_by_label("Authenticator or backup code").fill(login_code)
    page.get_by_role("button", name="Verify and sign in").click()
    expect(page.get_by_text(MEMBER_EMAIL)).to_be_visible()
    expect(totp_section.get_by_text("Remaining backup codes: 8.")).to_be_visible()
    with e2e_workspace.client() as replay_totp_api:
        replay_totp = replay_totp_api.post(
            "/api/integrations/access/login",
            json={"email": MEMBER_EMAIL, "password": MEMBER_PASS, "totpCode": login_code},
        )
        assert replay_totp.status_code == 401

    _wait_security_idle(page)
    page.get_by_role("button", name="Sign out").click()
    page.get_by_label("Operator email").fill(MEMBER_EMAIL)
    page.get_by_label("Password", exact=True).fill(MEMBER_PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_label("Authenticator or backup code")).to_be_visible()
    _assert_expected_401(collector)

    used_backup = regen_codes[0]
    page.get_by_label("Authenticator or backup code").fill(used_backup)
    page.get_by_role("button", name="Verify and sign in").click()
    expect(page.get_by_text(MEMBER_EMAIL)).to_be_visible()
    expect(totp_section.get_by_text("Remaining backup codes: 7.")).to_be_visible()

    with e2e_workspace.client() as replay_api:
        replay = replay_api.post(
            "/api/integrations/access/login",
            json={"email": MEMBER_EMAIL, "password": MEMBER_PASS, "totpCode": used_backup},
        )
        assert replay.status_code == 401

    totp_section.get_by_role("button", name="Disable 2FA").click()
    totp_section.get_by_label("Current password").fill(MEMBER_PASS)
    totp_section.get_by_label("Authenticator or backup code").fill(regen_codes[1])
    totp_section.get_by_role("button", name="Confirm disable 2FA").click()
    expect(totp_section.get_by_text("Two-factor authentication has been disabled.")).to_be_visible()
    expect(totp_section.get_by_text("Disabled", exact=True)).to_be_visible()

    _wait_security_idle(page)
    page.get_by_role("button", name="Sign out").click()
    page.get_by_label("Operator email").fill(MEMBER_EMAIL)
    page.get_by_label("Password", exact=True).fill(MEMBER_PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(MEMBER_EMAIL)).to_be_visible()
    expect(totp_section.get_by_text("Disabled", exact=True)).to_be_visible()
    _assert_no_secrets(page, secret, used_backup, regen_codes[1])
    collector.assert_clean()


def test_m18_audit_hash_chain_verify_and_tamper_detection_e2e(e2e_workspace, desktop_page):
    _setup_auth(e2e_workspace, include_member=True)
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        created = admin_api.post("/api/admin/models", json={
            "slug": "m18-audit-model", "display_name": "Audit Chain Model", "provider": "openai",
            "capability": "judge", "model_id": "gpt-4o", "apiKey": "sk-m18-audit-1111", "enabled": True,
        })
        created.raise_for_status()
        model_id = created.json()["model"]["id"]
        with store.connection(write=True) as db:
            model_registry.write_fallback_audit(
                db, actor_user_id=None, action="admin.model.fallback_check",
                model_uuid=model_id, details={"source": "e2e"},
            )
        acc_verify = admin_api.get("/api/integrations/admin/audit/verify")
        assert acc_verify.status_code == 200 and acc_verify.json()["ok"] is True
        mod_verify = admin_api.get("/api/admin/audit/verify")
        assert mod_verify.status_code == 200 and mod_verify.json()["ok"] is True and mod_verify.json()["verifiedCount"] >= 1

    with e2e_workspace.client() as anon:
        assert anon.get("/api/integrations/admin/audit/verify").status_code == 401
        assert anon.get("/api/admin/audit/verify").status_code == 401
    with e2e_workspace.client() as mem:
        login_user(mem, email=MEMBER_EMAIL, password=MEMBER_PASS)
        assert mem.get("/api/integrations/admin/audit/verify").status_code == 403
        assert mem.get("/api/admin/audit/verify").status_code == 403

    page, collector = desktop_page
    _sign_in_form(
        page, e2e_workspace.base_url + "/admin/", ADMIN_EMAIL, ADMIN_PASS,
        expected_heading="Administrator sign in required",
    )
    expect(page.get_by_role("heading", name="Model administration")).to_be_visible()
    page.get_by_role("tab", name="Audit log").click()

    panel = page.locator("#panel-audit")
    chain_region = panel.locator("div[role='region'][aria-label='Audit log hash chain']")
    expect(chain_region).to_be_visible()
    expect(chain_region.get_by_text("Not checked", exact=True)).to_be_visible()

    chain_region.get_by_role("button", name="Verify hash chain").click()
    expect(chain_region.get_by_text("Verified", exact=True)).to_be_visible()
    expect(chain_region).to_contain_text("Head:")

    with account_db.connection(write=True) as db:
        row = db.execute("SELECT id FROM audit_log WHERE entry_hash IS NOT NULL ORDER BY id DESC LIMIT 1").fetchone()
        assert row is not None
        tampered_id = int(row["id"])
        db.execute("UPDATE audit_log SET action='tampered.action' WHERE id=?", (tampered_id,))

    chain_region.get_by_role("button", name="Verify hash chain").click()
    expect(chain_region.get_by_text("Tampered", exact=True)).to_be_visible()
    expect(chain_region).to_contain_text(f"Hash-chain mismatch at entry #{tampered_id}")

    with store.connection(write=True) as db:
        mrow = db.execute("SELECT id FROM model_audit WHERE entry_hash IS NOT NULL ORDER BY id DESC LIMIT 1").fetchone()
        assert mrow is not None
        model_tampered_id = int(mrow["id"])
        db.execute("UPDATE model_audit SET action='tampered.model_action' WHERE id=?", (model_tampered_id,))
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        broken = admin_api.get("/api/admin/audit/verify").json()
        assert broken["ok"] is False and broken["firstBrokenId"] == model_tampered_id

    _assert_no_secrets(page, "sk-m18-audit-1111")
    collector.assert_clean()


def test_m18_csp_reports_collection_gates_view_and_clear_e2e(e2e_workspace, desktop_page, pytestconfig):
    _setup_auth(e2e_workspace, include_member=True)
    with e2e_workspace.client() as raw:
        doc_res = raw.get("/admin/")
        assert doc_res.status_code == 200
        if pytestconfig.getoption("--frontend") != "dev":
            assert "report-uri /api/csp-report" in doc_res.headers.get("content-security-policy", "")

    with e2e_workspace.client() as anon:
        assert anon.get("/api/admin/security/csp-reports").status_code == 401
        assert anon.delete("/api/admin/security/csp-reports").status_code == 401
    with e2e_workspace.client() as mem:
        login_user(mem, email=MEMBER_EMAIL, password=MEMBER_PASS)
        assert mem.get("/api/admin/security/csp-reports").status_code == 403
        assert mem.delete("/api/admin/security/csp-reports").status_code == 403

    with e2e_workspace.client(headers={"X-InterviewCheck": ""}) as browser_like:
        browser_like.headers.pop("X-InterviewCheck", None)
        r1 = browser_like.post(
            "/api/csp-report",
            headers={"Content-Type": "application/csp-report"},
            json={
                "csp-report": {
                    "document-uri": "http://127.0.0.1/admin/?token=secret-query#frag",
                    "violated-directive": "script-src 'self'",
                    "effective-directive": "script-src",
                    "blocked-uri": "https://evil.example/payload.js?apiKey=leaked-key",
                    "source-file": "http://127.0.0.1/app.js?v=1",
                    "line-number": 42,
                    "disposition": "enforce",
                }
            },
        )
        assert r1.status_code == 204

        r2 = browser_like.post(
            "/api/csp-report",
            headers={"Content-Type": "application/reports+json"},
            json=[{
                "type": "csp-violation",
                "url": "http://127.0.0.1/account/?secret=1",
                "body": {
                    "effectiveDirective": "img-src",
                    "blockedURL": "data:image/png;base64,SECRET_BASE64_DATA",
                    "disposition": "report",
                },
            }],
        )
        assert r2.status_code == 204

        oversized = browser_like.post(
            "/api/csp-report",
            headers={"Content-Type": "application/csp-report"},
            content=b'{"csp-report":{"blocked-uri":"' + (b"a" * 9000) + b'"}}',
        )
        assert oversized.status_code == 413

        bad_origin = browser_like.post(
            "/api/csp-report",
            headers={"Content-Type": "application/csp-report", "Origin": "https://evil.example"},
            json={"csp-report": {"blocked-uri": "https://evil.example/a.js"}},
        )
        assert bad_origin.status_code == 403

    page, collector = desktop_page
    _sign_in_form(
        page, e2e_workspace.base_url + "/admin/", ADMIN_EMAIL, ADMIN_PASS,
        expected_heading="Administrator sign in required",
    )
    expect(page.get_by_role("heading", name="Model administration")).to_be_visible()
    page.get_by_role("tab", name="Security").click()

    panel = page.locator("#panel-security")
    csp_section = panel.locator("section[aria-label='CSP violation reports']")
    expect(csp_section).to_be_visible()
    expect(csp_section.get_by_text("2 recorded")).to_be_visible()
    expect(csp_section).to_contain_text("script-src")
    expect(csp_section).to_contain_text("http://127.0.0.1/admin/")
    expect(csp_section).to_contain_text("https://evil.example/payload.js")
    expect(csp_section).to_contain_text("http://127.0.0.1/app.js:42")
    expect(csp_section).to_contain_text("img-src")
    expect(csp_section).to_contain_text("data:image/png")

    rendered_text = csp_section.inner_text()
    for stripped in ("secret-query", "#frag", "leaked-key", "SECRET_BASE64_DATA"):
        assert stripped not in rendered_text

    csp_section.get_by_role("button", name="Clear reports").click()
    expect(csp_section.get_by_text("Cleared 2 CSP violation report(s).")).to_be_visible()
    expect(csp_section.get_by_text("0 recorded")).to_be_visible()
    expect(csp_section.get_by_text("No CSP violation reports recorded.")).to_be_visible()

    page.reload(wait_until="domcontentloaded")
    page.get_by_role("tab", name="Security").click()
    expect(csp_section.get_by_text("0 recorded")).to_be_visible()
    expect(csp_section.get_by_text("No CSP violation reports recorded.")).to_be_visible()
    _assert_no_secrets(page)
    collector.assert_clean()


@pytest.mark.parametrize("viewport", [(1440, 900, "desktop-1440"), (390, 844, "mobile-390")], ids=lambda v: v[2])
def test_m18_responsive_account_totp_and_admin_security_viewports(e2e_workspace, e2e_browser, viewport):
    width, height, _ = viewport
    _setup_auth(e2e_workspace, include_member=False)
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        setup_res = admin_api.post("/api/integrations/security/totp/setup")
        setup_res.raise_for_status()
        secret = setup_res.json()["secret"]
        verify_res = admin_api.post(
            "/api/integrations/security/totp/verify",
            json={"code": totp_service.generate_totp_code(secret, step_offset=0)},
        )
        verify_res.raise_for_status()
        csp_res = admin_api.post(
            "/api/csp-report",
            headers={"Content-Type": "application/csp-report"},
            json={"csp-report": {
                "document-uri": "http://127.0.0.1/admin/?secret=drop",
                "effective-directive": "style-src",
                "blocked-uri": "https://cdn.example/s.css?tok=hide",
                "disposition": "enforce",
            }},
        )
        assert csp_res.status_code == 204

    mobile = width <= 480
    ctx = e2e_browser.new_context(
        viewport={"width": width, "height": height}, reduced_motion="reduce", is_mobile=mobile, has_touch=mobile,
    )
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    try:
        _sign_in_form(page, e2e_workspace.base_url + "/account/", ADMIN_EMAIL, ADMIN_PASS)
        expect(page.get_by_label("Authenticator or backup code")).to_be_visible()
        _assert_expected_401(collector)
        assert_no_horizontal_overflow(page)

        page.get_by_label("Authenticator or backup code").fill(totp_service.generate_totp_code(secret, step_offset=1))
        page.get_by_role("button", name="Verify and sign in").click()
        expect(page.get_by_text(ADMIN_EMAIL)).to_be_visible()
        totp_section = page.locator("section[aria-label='Two-factor authentication']")
        expect(totp_section.get_by_text("Enabled", exact=True)).to_be_visible()
        assert_no_horizontal_overflow(page)
        _wait_security_idle(page)

        page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
        expect(page.get_by_role("heading", name="Model administration")).to_be_visible()

        page.get_by_role("tab", name="Audit log").click()
        chain_region = page.locator("#panel-audit div[role='region'][aria-label='Audit log hash chain']")
        chain_region.get_by_role("button", name="Verify hash chain").click()
        expect(chain_region.get_by_text("Verified", exact=True)).to_be_visible()
        assert_no_horizontal_overflow(page)

        page.get_by_role("tab", name="Security").click()
        csp_section = page.locator("#panel-security section[aria-label='CSP violation reports']")
        expect(csp_section).to_contain_text("style-src")
        expect(csp_section).to_contain_text("https://cdn.example/s.css")
        assert_no_horizontal_overflow(page)

        _assert_no_secrets(page, secret)
        collector.assert_clean()
    finally:
        ctx.close()
