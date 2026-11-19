"""Opaque-box Playwright and API E2E tests for M13 probes, key rotation, and responsive hardening."""
import base64
from datetime import datetime, timezone
import os
import sqlite3

from playwright.sync_api import expect
import pytest

from api import health_probes, model_probe, secret_box
from e2e_suite.harness import (
    PORTABLE_ROOT,
    ConsoleErrorCollector,
    assert_no_horizontal_overflow,
    login_user,
    signup_user,
)

ADMIN_EMAIL = "admin-m13@example.test"
MEMBER_EMAIL = "member-m13@example.test"
BOOTSTRAP_SECRET = "m13-bootstrap-secret-1234"
ADMIN_PASS = "Synthetic-M13-Admin-Pass-1"
MEMBER_PASS = "Synthetic-M13-Member-Pass-1"
OLD_MASTER_KEY = "m13-old-master-key-v1"
NEW_MASTER_KEY = "m13-new-master-key-v2"
MODEL_API_KEY = "sk-m13-rotate-secret-9876"

PRIMARY_ROUTES = (
    "/",
    "/interviews/",
    "/interviews/new/",
    "/interviews/review/",
    "/interviews/brief/",
    "/roles/",
    "/connections/",
    "/data/",
    "/account/",
    "/sample/",
    "/trash/",
)


def _setup_auth(e2e_workspace, *, include_member: bool = False) -> None:
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
        if include_member:
            signup_user(c, email=MEMBER_EMAIL, password=MEMBER_PASS)


def _sign_in_admin(page, base_url: str) -> None:
    page.goto(base_url + "/admin/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Administrator sign in required")).to_be_visible()
    page.get_by_label("Operator email").fill(ADMIN_EMAIL)
    page.get_by_label("Password", exact=True).fill(ADMIN_PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_role("tablist", name="Admin sections")).to_be_visible()


def _assert_minimized_readyz(res, tmp_path, *, forbidden_kids: tuple[str, ...] = ()) -> dict:
    assert res.headers.get("cache-control") == "no-store"
    body = res.json()
    assert set(body.keys()) == {"ok", "checks"}
    assert set(body["checks"].keys()) == {"review_db", "access_db", "secret_box", "web_bundle"}
    raw = res.text
    assert str(tmp_path) not in raw
    for marker in ("Traceback", "Exception", "Error", ".sqlite", ".model_secret", "icbox", "v1:", "v2:", *forbidden_kids):
        assert marker not in raw
    return body


def _assert_no_secrets_anywhere(page, api_client, *secrets: str) -> None:
    all_secrets = (*secrets, OLD_MASTER_KEY, NEW_MASTER_KEY, "e2e-deterministic-test-secret-key")
    html = page.content()
    for secret in all_secrets:
        assert secret not in html
    for path in ("/api/admin/models", "/api/admin/models/key-status", "/api/admin/models/diagnostics", "/api/readyz", "/api/integrations/admin/audit"):
        resp = api_client.get(path)
        assert resp.status_code == 200
        for secret in all_secrets:
            assert secret not in resp.text
    chunks_dir = PORTABLE_ROOT / "web" / "out" / "_next" / "static" / "chunks"
    if chunks_dir.is_dir():
        for chunk in chunks_dir.glob("*.js"):
            text = chunk.read_text(encoding="utf-8", errors="ignore")
            for secret in all_secrets:
                assert secret not in text


def test_m13_healthz_readyz_probes_and_minimization(e2e_workspace, tmp_path, monkeypatch):
    with e2e_workspace.client() as c:
        hz = c.get("/api/healthz")
        assert hz.status_code == 200
        assert hz.headers.get("cache-control") == "no-store"
        assert hz.json() == {"ok": True, "service": "interviewcheck-api"}

        rz = c.get("/api/readyz")
        assert rz.status_code == 200
        assert _assert_minimized_readyz(rz, tmp_path) == {
            "ok": True,
            "checks": {"review_db": "ok", "access_db": "skipped", "secret_box": "ok", "web_bundle": "ok"},
        }

    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    with e2e_workspace.client() as c:
        rz_emb = c.get("/api/readyz")
        assert rz_emb.status_code == 200
        assert _assert_minimized_readyz(rz_emb, tmp_path) == {
            "ok": True,
            "checks": {"review_db": "ok", "access_db": "ok", "secret_box": "ok", "web_bundle": "ok"},
        }

        missing_dist = tmp_path / "missing_web_out"
        missing_dist.mkdir()
        with monkeypatch.context() as mp:
            mp.setattr(health_probes, "DIST", missing_dist)
            rz_missing = c.get("/api/readyz")
            assert rz_missing.status_code == 503
            assert _assert_minimized_readyz(rz_missing, tmp_path) == {
                "ok": False,
                "checks": {"review_db": "ok", "access_db": "ok", "secret_box": "ok", "web_bundle": "missing"},
            }

    if os.name != "nt":
        file_master = b"k" * 32
        kid = secret_box.key_id_for(file_master)
        monkeypatch.delenv("INTERVIEWCHECK_MODEL_SECRET_KEY", raising=False)
        e2e_workspace.secret_file.write_bytes(base64.urlsafe_b64encode(file_master))
        e2e_workspace.secret_file.chmod(0o644)
        with e2e_workspace.client() as c:
            rz_perm = c.get("/api/readyz")
            assert rz_perm.status_code == 503
            body = _assert_minimized_readyz(rz_perm, tmp_path, forbidden_kids=(kid,))
            assert body["ok"] is False and body["checks"]["secret_box"] == "error"
            e2e_workspace.secret_file.chmod(0o600)
            assert c.get("/api/readyz").status_code == 200
        monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "e2e-deterministic-test-secret-key")


def test_m13_key_rotation_api_security_gates(e2e_workspace):
    _setup_auth(e2e_workspace, include_member=True)
    with e2e_workspace.client() as anon:
        assert anon.get("/api/admin/models/key-status").status_code == 401
        assert anon.post("/api/admin/models/rotate-keys").status_code == 401

    with e2e_workspace.client() as member_api:
        login_user(member_api, email=MEMBER_EMAIL, password=MEMBER_PASS)
        assert member_api.get("/api/admin/models/key-status").status_code == 403
        assert member_api.post("/api/admin/models/rotate-keys").status_code == 403

    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        admin_api.headers.pop("X-InterviewCheck", None)
        assert admin_api.post("/api/admin/models/rotate-keys").status_code == 403

    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        assert admin_api.post("/api/admin/models/rotate-keys", json={"apiKey": "sk-raw-body"}).status_code == 422
        assert admin_api.post("/api/admin/models/rotate-keys", json={"key": "raw-master-key"}).status_code == 422
        assert admin_api.post("/api/admin/models/rotate-keys", json={"previous_keys": ["old-key"]}).status_code == 422


def test_m13_admin_ui_key_rotation_across_restarts(e2e_workspace, desktop_page, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", OLD_MASTER_KEY)
    old_kid = secret_box.active_key_id()
    legacy_v1_secret = "sk-m13-legacy-v1-secret-4321"
    _setup_auth(e2e_workspace)

    page, collector = desktop_page
    _sign_in_admin(page, e2e_workspace.base_url)

    page.get_by_role("button", name="Connect model").first.click()
    dlg = page.get_by_role("dialog", name="Connect model")
    dlg.get_by_label("Provider").select_option("openai")
    dlg.get_by_label("Display name").fill("M13 Rotate OpenAI")
    dlg.get_by_label("Model ID").fill("gpt-4o")
    dlg.get_by_label("Slug (optional, auto-generated if blank)").fill("m13-rotate-openai")
    dlg.get_by_label("API key").fill(MODEL_API_KEY)
    dlg.get_by_role("button", name="Save and connect").click()
    expect(dlg).to_have_count(0)
    expect(page.locator("article.admin-model-card", has_text="M13 Rotate OpenAI")).to_be_visible()

    with sqlite3.connect(e2e_workspace.review_db) as db:
        enc_before = db.execute("SELECT encrypted_api_key FROM connected_models WHERE slug='m13-rotate-openai'").fetchone()[0]
    assert enc_before.startswith(f"v2:{old_kid}:") and MODEL_API_KEY not in enc_before

    # Seed a legacy v1: model row before rotating so UI migration covers both v1: and prior v2:<old_kid>:.
    from api import model_registry, store
    legacy_id = "11111111-2222-4333-8444-555555555555"
    legacy_enc = secret_box.encrypt_secret(legacy_v1_secret, aad=legacy_id, envelope="v1")
    assert legacy_enc.startswith("v1:")
    with store.connection(write=True) as db:
        model_registry.create_model(
            db, model_uuid=legacy_id, slug="m13-legacy-v1", display_name="M13 Legacy V1",
            provider="anthropic", capability="judge", model_id="claude-sonnet-4-20250514",
            endpoint=None, api_version=None, parameters={}, encrypted_api_key=legacy_enc,
            key_hint=secret_box.mask_key_hint(legacy_v1_secret), enabled=True, is_default=False,
        )

    page.goto("about:blank")
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", NEW_MASTER_KEY)
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS", OLD_MASTER_KEY)
    new_kid = secret_box.active_key_id()
    e2e_workspace.restart()

    page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Model administration")).to_be_visible()
    page.get_by_role("tab", name="Diagnostics").click()

    rot_card = page.locator("section[aria-label='Credential encryption and key rotation']")
    expect(rot_card.get_by_test_id("active-key-id")).to_have_text(new_kid)
    expect(rot_card).to_contain_text("Environment (env)")
    expect(rot_card).to_contain_text("2 needs rotation")
    expect(rot_card.locator(".admin-metric", has_text="Previous keys configured").locator("strong")).to_have_text("1")
    expect(rot_card.locator(".admin-metric", has_text="Current v2 count").locator("strong")).to_have_text("0")
    expect(rot_card.locator(".admin-metric", has_text="Needs rotation").locator("strong")).to_have_text("2")

    trigger_btn = rot_card.get_by_role("button", name="Re-encrypt stored keys")
    trigger_btn.click()
    confirm_bar = rot_card.locator("[role='region'][aria-label='Confirm key rotation']")
    expect(confirm_bar).to_be_visible()
    cancel_btn = confirm_bar.get_by_role("button", name="Cancel")
    expect(cancel_btn).to_be_focused()
    cancel_btn.click()
    expect(confirm_bar).to_have_count(0)
    expect(trigger_btn).to_be_focused()
    trigger_btn.click()
    expect(confirm_bar).to_be_visible()
    confirm_bar.get_by_role("button", name="Confirm re-encryption").click()

    expect(rot_card.get_by_text(f"Re-encrypted 2 stored credential(s) under active key {new_kid}.")).to_be_visible()
    expect(rot_card).to_contain_text("All keys current")
    expect(rot_card.locator(".admin-metric", has_text="Needs rotation").locator("strong")).to_have_text("0")
    expect(rot_card.locator(".admin-metric", has_text="Current v2 count").locator("strong")).to_have_text("2")

    with sqlite3.connect(e2e_workspace.review_db) as db:
        enc_after = db.execute("SELECT encrypted_api_key FROM connected_models WHERE slug='m13-rotate-openai'").fetchone()[0]
        enc_legacy_after = db.execute("SELECT encrypted_api_key FROM connected_models WHERE slug='m13-legacy-v1'").fetchone()[0]
    assert enc_after.startswith(f"v2:{new_kid}:") and MODEL_API_KEY not in enc_after
    assert enc_legacy_after.startswith(f"v2:{new_kid}:") and legacy_v1_secret not in enc_legacy_after

    page.goto("about:blank")
    monkeypatch.delenv("INTERVIEWCHECK_MODEL_SECRET_KEY_PREVIOUS", raising=False)
    e2e_workspace.restart()

    page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
    page.get_by_role("tab", name="Diagnostics").click()
    expect(rot_card).to_contain_text("All keys current")
    expect(rot_card.locator(".admin-metric", has_text="Previous keys configured").locator("strong")).to_have_text("0")
    expect(rot_card.locator(".admin-metric", has_text="Current v2 count").locator("strong")).to_have_text("2")
    expect(rot_card.locator(".admin-metric", has_text="Needs rotation").locator("strong")).to_have_text("0")

    page.get_by_role("tab", name="Models").click()
    card = page.locator("article.admin-model-card", has_text="M13 Rotate OpenAI")
    card.get_by_role("button", name="Configure").click()
    edit_dlg = page.get_by_role("dialog")
    edit_dlg.get_by_label("Display name").fill("M13 Rotated OpenAI")
    edit_dlg.get_by_role("button", name="Save configuration").click()
    expect(edit_dlg).to_have_count(0)
    updated_card = page.locator("article.admin-model-card", has_text="M13 Rotated OpenAI")
    expect(updated_card).to_be_visible()

    probed_keys: list[str] = []

    async def _fake_probe(row, *, api_key: str):
        probed_keys.append(api_key)
        return model_probe.ProbeOutcome(
            ok=True, status="connected", http_status=200, latency_ms=24,
            last_error=None, checked_at=datetime.now(timezone.utc).isoformat(),
        )

    monkeypatch.setattr(model_probe, "probe_model", _fake_probe)
    updated_card.get_by_role("button", name="Test connection").click()
    expect(page.get_by_text("M13 Rotated OpenAI connected (24 ms).")).to_be_visible()
    legacy_card = page.locator("article.admin-model-card", has_text="M13 Legacy V1")
    legacy_card.get_by_role("button", name="Test connection").click()
    expect(page.get_by_text("M13 Legacy V1 connected (24 ms).")).to_be_visible()
    assert probed_keys == [MODEL_API_KEY, legacy_v1_secret]

    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        st = admin_api.get("/api/admin/models/key-status").json()
        assert st["needs_rotation_count"] == 0 and st["current_v2_count"] >= 2
        _assert_no_secrets_anywhere(page, admin_api, MODEL_API_KEY, legacy_v1_secret)
    collector.assert_clean()


@pytest.mark.parametrize("viewport", [(1440, 900, "desktop-1440"), (390, 844, "mobile-390")], ids=lambda v: v[2])
def test_m13_responsive_workspace_and_diagnostics_route_sweep(e2e_workspace, e2e_browser, viewport):
    width, height, _ = viewport
    _setup_auth(e2e_workspace)
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        admin_api.post("/api/admin/models", json={
            "slug": "sweep-openai", "display_name": "Sweep OpenAI", "provider": "openai",
            "capability": "reference", "model_id": "gpt-4o", "apiKey": "sk-m13-sweep-1234",
        }).raise_for_status()

    mobile = width <= 480
    ctx = e2e_browser.new_context(viewport={"width": width, "height": height}, reduced_motion="reduce", is_mobile=mobile, has_touch=mobile)
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    try:
        _sign_in_admin(page, e2e_workspace.base_url)
        for route in PRIMARY_ROUTES:
            resp = page.goto(e2e_workspace.base_url + route, wait_until="domcontentloaded")
            assert resp is not None and resp.status == 200
            expect(page.locator("main#main-content")).to_be_visible()
            assert_no_horizontal_overflow(page)

        resp_admin = page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
        assert resp_admin is not None and resp_admin.status == 200
        expect(page.get_by_role("tablist", name="Admin sections")).to_be_visible()
        assert_no_horizontal_overflow(page)

        page.get_by_role("tab", name="Diagnostics").click()
        expect(page.locator("#panel-diagnostics")).to_be_visible()
        rot_card = page.locator("section[aria-label='Credential encryption and key rotation']")
        expect(rot_card.get_by_test_id("active-key-id")).to_be_visible()
        assert_no_horizontal_overflow(page)
        collector.assert_clean()
    finally:
        ctx.close()
