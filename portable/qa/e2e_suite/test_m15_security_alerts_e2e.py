"""Opaque-box Playwright E2E tests for M15 account security, rate-limit unlock, and alert rules."""
import hashlib, hmac, json, re
from uuid import uuid4

from fastapi import HTTPException
from playwright.sync_api import expect
import pytest

from api import account_auth, alert_rules, model_registry, model_telemetry, secret_box, ssrf_guard, store
from e2e_suite.harness import ConsoleErrorCollector, assert_no_horizontal_overflow, login_user, signup_user

ADMIN_EMAIL = "admin-m15@example.test"
MEMBER_EMAIL = "member-m15@example.test"
BOOTSTRAP_SECRET = "m15-bootstrap-secret-1234"
ADMIN_PASS = "Synthetic-M15-Admin-Pass-1"
MEMBER_PASS = "Synthetic-M15-Member-Pass-1"
NEW_MEMBER_PASS = "Synthetic-M15-Member-Pass-2"
WEBHOOK_URL = "https://hooks.example.com/alerts"
WEBHOOK_SECRET = "whsec-e2e-signing-secret-999"


def _setup_auth(e2e_workspace, *, include_member: bool = True) -> dict[str, str]:
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    ids: dict[str, str] = {}
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
        if include_member:
            signup_user(c, email=MEMBER_EMAIL, password=MEMBER_PASS)
        c.cookies.clear()
        login_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS)
        for row in c.get("/api/integrations/admin/users").json()["users"]:
            ids[row["user"]["email"]] = row["user"]["id"]
    return ids


def _sign_in(page, url: str, email: str, password: str, *, heading: str | None = None) -> None:
    page.goto(url, wait_until="domcontentloaded")
    if heading:
        expect(page.get_by_role("heading", name=heading)).to_be_visible()
    page.get_by_label("Operator email").fill(email)
    page.get_by_label("Password", exact=True).fill(password)
    page.get_by_role("button", name="Sign in", exact=True).click()


def _seed_degraded_model() -> None:
    uid = str(uuid4())
    with store.connection(write=True) as db:
        model_registry.create_model(
            db, model_uuid=uid, slug="m15-ref-alert", display_name="M15 Ref Alert",
            provider="openai", capability="reference", model_id="gpt-4o", endpoint=None, api_version=None,
            parameters={"fallback_priority": 10},
            encrypted_api_key=secret_box.encrypt_secret("sk-m15-model-1234", aad=uid),
            key_hint="...1234", enabled=True, is_default=True,
        )
        model_telemetry.record_check(
            db, model_uuid=uid, source="probe", ok=False, http_status=503,
            latency_ms=120, error="Upstream error", checked_at=store.timestamp(),
        )


def test_m15_fail_closed_auth_scopes_and_csrf_gates(e2e_workspace, desktop_page):
    ids = _setup_auth(e2e_workspace)
    mem_uid, rid = ids[MEMBER_EMAIL], str(uuid4())
    alert_body = {"name": "x", "trigger_type": "probe_failed", "threshold_value": 1, "webhook_url": WEBHOOK_URL}
    with e2e_workspace.client() as anon:
        for method, path, body in (
            ("GET", "/api/integrations/security/sessions", None), ("GET", "/api/integrations/security/tokens", None),
            ("POST", "/api/integrations/security/tokens", {"name": "t", "scopes": ["read:interviews"]}),
            ("GET", "/api/integrations/admin/security/rate-limits", None), ("DELETE", "/api/integrations/admin/security/rate-limits", None),
            ("GET", f"/api/integrations/admin/security/users/{mem_uid}/sessions", None),
            ("POST", f"/api/integrations/admin/security/users/{mem_uid}/revoke-sessions", {}),
            ("GET", "/api/admin/alerts", None), ("POST", "/api/admin/alerts", alert_body),
            ("POST", "/api/admin/alerts/evaluate", None), ("GET", "/v1/auth/sessions", None),
            ("GET", "/v1/auth/tokens", None), ("GET", "/v1/admin/rate-limits", None),
        ):
            assert anon.request(method, path, json=body).status_code == 401

    with e2e_workspace.client() as mem:
        login_user(mem, email=MEMBER_EMAIL, password=MEMBER_PASS)
        assert mem.post("/api/integrations/security/tokens", json={"name": "esc", "scopes": ["admin:models"]}).status_code == 403
        for method, path, body in (
            ("GET", "/api/integrations/admin/security/rate-limits", None), ("DELETE", "/api/integrations/admin/security/rate-limits", None),
            ("GET", f"/api/integrations/admin/security/users/{mem_uid}/sessions", None),
            ("POST", f"/api/integrations/admin/security/users/{mem_uid}/revoke-sessions", {}),
            ("GET", "/api/admin/alerts", None), ("POST", "/api/admin/alerts", alert_body), ("POST", f"/api/admin/alerts/{rid}/test", None),
        ):
            assert mem.request(method, path, json=body).status_code == 403
        mem.headers.pop("X-InterviewCheck", None)
        assert mem.post("/api/integrations/security/tokens", json={"name": "csrf", "scopes": ["read:interviews"]}).status_code == 403

    page, collector = desktop_page
    page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Administrator sign in required")).to_be_visible()
    expect(page.get_by_role("tablist", name="Admin sections")).to_have_count(0)

    _sign_in(page, e2e_workspace.base_url + "/account/", MEMBER_EMAIL, MEMBER_PASS)
    expect(page.get_by_text(MEMBER_EMAIL)).to_be_visible()
    tok_sec = page.locator("section[aria-label='Scoped API tokens']")
    expect(tok_sec).to_be_visible()
    expect(tok_sec.get_by_label("Administer models (admin only)")).to_have_count(0)
    page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Administrator access required")).to_be_visible()
    expect(page.get_by_role("tablist", name="Admin sections")).to_have_count(0)
    collector.assert_clean()


def test_m15_account_sessions_tokens_and_password_change_e2e(e2e_workspace, desktop_page):
    _setup_auth(e2e_workspace)
    with e2e_workspace.client() as c:
        extra_tok = c.post("/v1/auth/login", json={"email": MEMBER_EMAIL, "password": MEMBER_PASS, "deviceName": "CI Runner Laptop"}).json()["token"]

    page, collector = desktop_page
    _sign_in(page, e2e_workspace.base_url + "/account/", MEMBER_EMAIL, MEMBER_PASS)
    expect(page.get_by_text(MEMBER_EMAIL)).to_be_visible()

    sess_sec = page.locator("section[aria-label='Active device sessions']")
    expect(sess_sec.locator("tbody tr")).to_have_count(3)
    expect(sess_sec).to_contain_text("CI Runner Laptop")
    sess_sec.locator("tbody tr", has_text="CI Runner Laptop").get_by_role("button", name="Revoke").click()
    expect(page.get_by_text("Revoked session (CI Runner Laptop).")).to_be_visible()
    expect(sess_sec.locator("tbody tr")).to_have_count(2)
    page.reload(wait_until="domcontentloaded")
    expect(page.locator("section[aria-label='Active device sessions'] tbody tr")).to_have_count(2)
    with e2e_workspace.client() as c:
        assert c.get("/v1/me", headers={"Authorization": f"Bearer {extra_tok}"}).status_code == 401

    tok_sec = page.locator("section[aria-label='Scoped API tokens']")
    tok_sec.get_by_label("Token name").fill("CI Exporter")
    tok_sec.get_by_label("TTL (days, 1 to 365)").fill("30")
    tok_sec.get_by_label("Export reports").check()
    tok_sec.get_by_label("Read telemetry").check()
    tok_sec.get_by_role("button", name="Generate token").click()
    expect(tok_sec.get_by_text("Copy this API token now. It will not be shown again.")).to_be_visible()
    raw_tok = tok_sec.locator("code").inner_text().strip()
    assert raw_tok.startswith("ic_tok_")

    page.reload(wait_until="domcontentloaded")
    tok_sec = page.locator("section[aria-label='Scoped API tokens']")
    expect(tok_sec.get_by_text("Copy this API token now. It will not be shown again.")).to_have_count(0)
    assert raw_tok not in page.content()
    tok_row = tok_sec.locator("tbody tr", has_text="CI Exporter")
    expect(tok_row).to_contain_text(raw_tok[:14])
    expect(tok_row).to_contain_text("Active")

    assert account_auth.authenticate_bearer(f"Bearer {raw_tok}", required_scope="export:reports")[0]["email"] == MEMBER_EMAIL
    with pytest.raises(HTTPException) as exc:
        account_auth.authenticate_bearer(f"Bearer {raw_tok}", required_scope="write:interviews")
    assert exc.value.status_code == 403
    with e2e_workspace.client() as c:
        assert c.get("/v1/auth/sessions", headers={"Authorization": f"Bearer {raw_tok}"}).status_code == 401

    tok_row.get_by_role("button", name="Revoke").click()
    expect(tok_row).to_contain_text("Revoked")
    page.reload(wait_until="domcontentloaded")
    expect(page.locator("section[aria-label='Scoped API tokens'] tbody tr", has_text="CI Exporter")).to_have_count(0)
    with pytest.raises(HTTPException) as rev_exc:
        account_auth.authenticate_bearer(f"Bearer {raw_tok}")
    assert rev_exc.value.status_code == 401

    with e2e_workspace.client() as c:
        old_lap_tok = c.post("/v1/auth/login", json={"email": MEMBER_EMAIL, "password": MEMBER_PASS, "deviceName": "Old Laptop"}).json()["token"]

    pw_form = page.get_by_role("form", name="Change password")
    pw_form.get_by_label("Current password").fill(MEMBER_PASS)
    pw_form.get_by_label("New password", exact=True).fill(NEW_MEMBER_PASS)
    pw_form.get_by_label("Confirm new password").fill(NEW_MEMBER_PASS)
    pw_form.get_by_role("button", name="Update password").click()
    expect(pw_form.get_by_text("Password updated and session rotated.")).to_be_visible()
    page.get_by_role("button", name="Refresh security").click()
    expect(page.locator("section[aria-label='Active device sessions'] tbody tr")).to_have_count(1)
    assert "Old Laptop" not in page.locator("section[aria-label='Active device sessions']").inner_text()

    with e2e_workspace.client() as c:
        assert c.get("/v1/me", headers={"Authorization": f"Bearer {old_lap_tok}"}).status_code == 401
        assert c.post("/v1/auth/login", json={"email": MEMBER_EMAIL, "password": MEMBER_PASS}).status_code == 401
        assert c.post("/v1/auth/login", json={"email": MEMBER_EMAIL, "password": NEW_MEMBER_PASS}).status_code == 200
    for secret in (raw_tok, MEMBER_PASS, NEW_MEMBER_PASS):
        assert secret not in page.content()
    collector.assert_clean()


def test_m15_admin_security_unlock_session_revoke_and_alerts_e2e(e2e_workspace, desktop_page, monkeypatch):
    _setup_auth(e2e_workspace)
    _seed_degraded_model()
    delivered: list[dict] = []
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])

    async def fake_dispatch(url: str, body: bytes, headers: dict[str, str]):
        delivered.append({"url": url, "body": body, "headers": headers})
        return True, 202, None

    monkeypatch.setattr(alert_rules, "dispatch_fn", fake_dispatch)
    with e2e_workspace.client() as c:
        mem_tok = c.post("/v1/auth/login", json={"email": MEMBER_EMAIL, "password": MEMBER_PASS, "deviceName": "Member Phone"}).json()["token"]

    page, collector = desktop_page
    _sign_in(page, e2e_workspace.base_url + "/admin/", ADMIN_EMAIL, ADMIN_PASS, heading="Administrator sign in required")
    expect(page.get_by_role("heading", name="Model administration")).to_be_visible()

    with e2e_workspace.client() as c:
        login_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS)
        c.delete("/api/integrations/admin/security/rate-limits").raise_for_status()
        c.cookies.clear()
        for _ in range(10):
            assert c.post("/api/integrations/access/login", json={"email": MEMBER_EMAIL, "password": "Wrong-Pass-1234"}).status_code == 401
        assert c.post("/api/integrations/access/login", json={"email": MEMBER_EMAIL, "password": MEMBER_PASS}).status_code == 429

    tablist = page.get_by_role("tablist", name="Admin sections")
    tablist.get_by_role("tab", name="Models").focus()
    page.keyboard.press("End")
    sec_tab = tablist.get_by_role("tab", name="Security")
    expect(sec_tab).to_be_focused()
    expect(sec_tab).to_have_attribute("aria-selected", "true")
    panel = page.locator("#panel-security[role='tabpanel']")
    expect(panel).to_be_visible()

    rl_sec = panel.locator("section[aria-label='Rate limits and lockouts']")
    rl_sec.get_by_role("button", name="Refresh").click()
    email_row = rl_sec.locator("tbody tr", has_text="login_email_windows")
    expect(email_row).to_contain_text("m***@example.test")
    email_row.get_by_role("button", name="Unlock").click()
    expect(rl_sec.locator("tbody tr", has_text="login_email_windows")).to_have_count(0)
    rl_sec.get_by_role("button", name="Clear all").click()
    expect(panel.get_by_text(re.compile(r"Cleared \d+ rate-limit buckets\."))).to_be_visible()
    expect(rl_sec.locator("tbody tr", has_text="credential")).to_have_count(0)
    with e2e_workspace.client() as c:
        assert c.post("/api/integrations/access/login", json={"email": MEMBER_EMAIL, "password": MEMBER_PASS}).status_code == 200

    usr_sec = panel.locator("section[aria-label='User session revocation']")
    usr_sec.locator("select").select_option(label=f"{MEMBER_EMAIL} (user)")
    expect(usr_sec).to_contain_text("Member Phone")
    usr_sec.locator("tbody tr", has_text="Member Phone").get_by_role("button", name="Revoke").click()
    expect(panel.get_by_text("Revoked 1 session(s) without disabling the account.")).to_be_visible()
    expect(usr_sec).to_contain_text("active account")
    with e2e_workspace.client() as c:
        assert c.get("/v1/me", headers={"Authorization": f"Bearer {mem_tok}"}).status_code == 401
        assert c.post("/v1/auth/login", json={"email": MEMBER_EMAIL, "password": MEMBER_PASS}).status_code == 200

    with e2e_workspace.client() as adm_api:
        login_user(adm_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        assert adm_api.post("/api/admin/alerts", json={"name": "Bad SSRF", "trigger_type": "probe_failed", "threshold_value": 1, "webhook_url": "https://127.0.0.1/hook"}).status_code == 400

    alert_sec = panel.locator("section[aria-label='Model and budget webhook alerts']")
    alert_sec.get_by_role("button", name="New alert rule").click()
    alert_sec.get_by_label("Rule name").fill("Ref Error Streak")
    alert_sec.get_by_label("Trigger type").select_option("model_error_streak")
    alert_sec.get_by_label("Threshold value").fill("1")
    alert_sec.get_by_label("Capability filter").select_option("reference")
    alert_sec.get_by_label("Webhook URL (HTTPS)").fill(WEBHOOK_URL)
    alert_sec.get_by_label("Cooldown (minutes)").fill("0")
    alert_sec.get_by_label("Signing secret (optional HMAC-SHA256)").fill(WEBHOOK_SECRET)
    alert_sec.get_by_role("button", name="Create rule").click()

    card = alert_sec.locator("article", has_text="Ref Error Streak")
    expect(card).to_contain_text("Enabled")
    expect(card).to_contain_text("Signed (")
    assert WEBHOOK_SECRET not in page.content()

    card.get_by_role("button", name="Test webhook").click()
    expect(panel.get_by_text(re.compile(r"Webhook test succeeded for Ref Error Streak \(HTTP 20[02]\)\."))).to_be_visible()
    expect(alert_sec.locator("tbody tr").first).to_contain_text("Delivered")
    expect(alert_sec.locator("tbody tr").first).to_contain_text("202")
    expected_sig = "sha256=" + hmac.new(WEBHOOK_SECRET.encode(), delivered[0]["body"], hashlib.sha256).hexdigest()
    assert delivered[0]["headers"]["X-InterviewCheck-Signature"] == expected_sig
    assert json.loads(delivered[0]["body"])["event"] == "alert.test"

    alert_sec.get_by_role("button", name="Evaluate now").click()
    expect(panel.get_by_text("Evaluated 1 rule(s); 1 triggered.")).to_be_visible()
    assert len(delivered) == 2 and json.loads(delivered[1]["body"])["event"] == "alert.triggered"

    card.get_by_role("button", name="Edit").click()
    alert_sec.get_by_label("Rule name").fill("Ref Error Streak v2")
    alert_sec.get_by_role("button", name="Save rule").click()
    page.reload(wait_until="domcontentloaded")
    page.get_by_role("tab", name="Security").click()
    card_v2 = page.locator("#panel-security article", has_text="Ref Error Streak v2")
    expect(card_v2).to_be_visible()
    card_v2.get_by_role("button", name="Disable").click()
    expect(card_v2).to_contain_text("Disabled")
    card_v2.get_by_role("button", name="Delete Ref Error Streak v2").click()
    expect(page.locator("#panel-security article", has_text="Ref Error Streak v2")).to_have_count(0)
    collector.assert_clean()


@pytest.mark.parametrize("viewport", [(1440, 900, "desktop-1440"), (390, 844, "mobile-390")], ids=lambda v: v[2])
def test_m15_responsive_dark_light_overflow_and_keyboard(e2e_workspace, e2e_browser, monkeypatch, viewport):
    width, height, _ = viewport
    _setup_auth(e2e_workspace)
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])
    with e2e_workspace.client() as adm:
        login_user(adm, email=ADMIN_EMAIL, password=ADMIN_PASS)
        adm.post("/api/integrations/security/tokens", json={"name": "Resp Token", "scopes": ["read:interviews", "admin:models"]}).raise_for_status()
        adm.post("/api/admin/alerts", json={"name": "Resp Alert", "trigger_type": "probe_failed", "threshold_value": 1, "webhook_url": WEBHOOK_URL}).raise_for_status()

    mobile = width <= 480
    ctx = e2e_browser.new_context(viewport={"width": width, "height": height}, reduced_motion="reduce", is_mobile=mobile, has_touch=mobile)
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    try:
        _sign_in(page, e2e_workspace.base_url + "/account/", ADMIN_EMAIL, ADMIN_PASS)
        expect(page.get_by_text(ADMIN_EMAIL)).to_be_visible()
        for theme in ("dark", "light"):
            page.goto(e2e_workspace.base_url + "/account/", wait_until="domcontentloaded")
            expect(page.get_by_text(ADMIN_EMAIL)).to_be_visible()
            page.get_by_role("radio", name=theme.capitalize()).check()
            expect(page.locator("html")).to_have_attribute("data-theme", theme)
            expect(page.locator("section[aria-label='Scoped API tokens']")).to_contain_text("Resp Token")
            assert_no_horizontal_overflow(page)
            page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
            page.get_by_role("tab", name="Security").click()
            expect(page.locator("#panel-security")).to_contain_text("Resp Alert")
            assert_no_horizontal_overflow(page)
        collector.assert_clean()
    finally:
        ctx.close()
