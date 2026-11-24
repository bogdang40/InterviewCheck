"""Playwright E2E tests for M25 mobile admin tab bounds, fleet health timeline exports, overdue triage, and bulk assignment."""
from datetime import datetime, timedelta, timezone
import json
import re

from playwright.sync_api import expect
import pytest

from api import model_probe, model_telemetry, ssrf_guard, store
from e2e_suite.harness import ConsoleErrorCollector, assert_no_horizontal_overflow, login_user, signup_user

ADMIN_EMAIL = "admin-m25@example.test"
ALICE_EMAIL = "alice-m25@example.test"
PASS = "Synthetic-M25-Pass-9876"
BOOTSTRAP_SECRET = "m25-bootstrap-secret-1234"
MODEL_KEY_OK = "sk-m25-super-secret-api-key-1111"
MODEL_KEY_ERR = "sk-m25-super-secret-api-key-2222"
PROBE_ERR_SECRET = "sk-m25-leaked-probe-secret-9999"
VIEWPORTS = [(1440, 900, "desktop-1440"), (390, 844, "mobile-390")]
ADMIN_TABS = ("Models", "Accounts", "Usage", "Audit log", "Diagnostics", "Playground", "Security", "Prompts & SLA", "Compliance")
FORBIDDEN_SECRET_KEYS = frozenset({
    "encrypted_api_key", "encrypted_signing_secret", "token_hash", "api_key", "signing_secret", "totp_secret", "password_hash",
})


def _open_page(e2e_browser, width: int, height: int):
    mobile = width <= 480
    ctx = e2e_browser.new_context(viewport={"width": width, "height": height}, reduced_motion="reduce", is_mobile=mobile, has_touch=mobile)
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    page.set_default_navigation_timeout(30_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    return ctx, page, collector


def _setup_users(e2e_workspace, *, emails: tuple[str, ...], admin_emails: tuple[str, ...] = ()) -> None:
    e2e_workspace.configure_embedded_auth(admin_emails=admin_emails, bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    with e2e_workspace.client() as c:
        for email in emails:
            signup_user(c, email=email, password=PASS, admin_secret=BOOTSTRAP_SECRET if email in admin_emails else None)


def _sign_in_browser(page, base_url: str, email: str) -> None:
    page.goto(base_url + "/account/", wait_until="domcontentloaded")
    page.get_by_label("Operator email").fill(email)
    page.get_by_label("Password", exact=True).fill(PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(f"{email} · Access active")).to_be_visible()


def _assert_no_secret_keys(obj) -> None:
    if isinstance(obj, dict):
        for k, v in obj.items():
            assert k not in FORBIDDEN_SECRET_KEYS, f"Secret key leaked in timeline export: {k}"
            _assert_no_secret_keys(v)
    elif isinstance(obj, list):
        for item in obj:
            _assert_no_secret_keys(item)


def _assert_no_secret_text(text: str) -> None:
    for secret_val in (
        "encrypted_api_key", "encrypted_signing_secret", "token_hash",
        MODEL_KEY_OK, MODEL_KEY_ERR, PROBE_ERR_SECRET, BOOTSTRAP_SECRET, "e2e-deterministic-test-secret-key",
    ):
        assert secret_val not in text, f"Secret material leaked in export: {secret_val}"


def _assert_tab_strict_bounds(page, index: int) -> float:
    metrics = page.evaluate(
        """(idx) => {
          const strip = document.querySelector('.admin-tabs');
          const tabs = strip ? Array.from(strip.querySelectorAll('[role="tab"]')) : [];
          const tab = tabs[idx];
          if (!strip || !tab) return null;
          const s = strip.getBoundingClientRect();
          const t = tab.getBoundingClientRect();
          return {
            sLeft: s.left, sRight: s.right, scrollLeft: strip.scrollLeft,
            tLeft: t.left, tRight: t.right, tHeight: t.height,
            tScrollW: tab.scrollWidth, tClientW: tab.clientWidth,
          };
        }""",
        index,
    )
    assert metrics is not None
    assert metrics["tHeight"] >= 44, f"Tab {index} height {metrics['tHeight']} < 44"
    assert metrics["tScrollW"] <= metrics["tClientW"] + 1, f"Tab {index} text clipped: {metrics}"
    assert metrics["tLeft"] >= metrics["sLeft"] - 1, f"Tab {index} clipped left: {metrics}"
    assert metrics["tRight"] <= metrics["sRight"] + 1, f"Tab {index} clipped right: {metrics}"
    return float(metrics["scrollLeft"])


def _verify_timeline_and_exports(page) -> None:
    page.get_by_role("tab", name="Diagnostics").click()
    timeline = page.get_by_label("Fleet health timeline")
    expect(timeline).to_be_visible()

    summary = timeline.get_by_label("Health timeline summary")
    expect(summary).to_contain_text("3")
    expect(summary).to_contain_text("2 ok, 1 failed")
    expect(summary).to_contain_text("Models with errors")

    buckets = timeline.get_by_label("Health timeline buckets")
    events = timeline.get_by_label("Recent health check events")
    expect(buckets).to_be_visible()
    expect(events).to_be_visible()
    expect(events).to_contain_text("M25 Healthy Model")
    expect(events).to_contain_text("M25 Failing Model")
    assert_no_horizontal_overflow(page)

    timeline.get_by_label("Filter timeline by source").select_option("probe")
    expect(summary).to_contain_text("1 ok, 1 failed")
    expect(summary).to_contain_text("50.0%")
    expect(events.locator("tbody tr")).to_have_count(2)

    with page.expect_download() as csv_dl:
        timeline.get_by_role("button", name="Export timeline CSV").click()
    expect(timeline.get_by_role("status")).to_contain_text("Exported model-health-timeline.csv.")
    csv_text = csv_dl.value.path().read_text(encoding="utf-8-sig")
    assert "Checked at,Model ID,Slug,Display name" in csv_text
    assert "m25-ok-model" in csv_text and "m25-err-model" in csv_text
    assert "'=cmd|calc" in csv_text
    assert ",=cmd|calc" not in csv_text
    _assert_no_secret_text(csv_text)

    with page.expect_download() as json_dl:
        timeline.get_by_role("button", name="Export timeline JSON").click()
    expect(timeline.get_by_role("status")).to_contain_text("Exported model-health-timeline.json.")
    raw_json = json_dl.value.path().read_text(encoding="utf-8")
    doc = json.loads(raw_json)
    assert doc["filters"]["source"] == "probe"
    assert doc["summary"]["total_checks"] == 2
    assert doc["summary"]["ok_count"] == 1
    assert doc["summary"]["error_count"] == 1
    assert doc["summary"]["models_with_errors"] == 1
    assert len(doc["buckets"]) >= 1
    assert len(doc["events"]) == 2
    _assert_no_secret_keys(doc)
    _assert_no_secret_text(raw_json)
    assert_no_horizontal_overflow(page)


def test_m25_mobile_admin_tabs_unclipped_and_health_timeline_export(e2e_workspace, e2e_browser, monkeypatch):
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])

    async def fake_probe(row, *, api_key: str):
        if row["slug"] == "m25-ok-model":
            return model_probe.ProbeOutcome(
                ok=True, status="connected", http_status=200, latency_ms=42,
                last_error=None, checked_at=model_probe._now_iso(),
            )
        return model_probe.ProbeOutcome(
            ok=False, status="error", http_status=401, latency_ms=88,
            last_error=f"=cmd|calc failed with {PROBE_ERR_SECRET}", checked_at=model_probe._now_iso(),
        )

    monkeypatch.setattr(model_probe, "probe_model", fake_probe)
    _setup_users(e2e_workspace, emails=(ADMIN_EMAIL,), admin_emails=(ADMIN_EMAIL,))
    with e2e_workspace.client() as c:
        login_user(c, email=ADMIN_EMAIL, password=PASS)
        r1 = c.post("/api/admin/models", json={
            "slug": "m25-ok-model", "display_name": "M25 Healthy Model", "provider": "openai",
            "capability": "reference", "model_id": "gpt-4o", "apiKey": MODEL_KEY_OK,
        })
        r1.raise_for_status()
        id_ok = r1.json()["model"]["id"]
        r2 = c.post("/api/admin/models", json={
            "slug": "m25-err-model", "display_name": "M25 Failing Model", "provider": "anthropic",
            "capability": "judge", "model_id": "claude-sonnet-4-20250514", "apiKey": MODEL_KEY_ERR,
        })
        r2.raise_for_status()
        id_err = r2.json()["model"]["id"]
        assert c.post(f"/api/admin/models/{id_ok}/probe").status_code == 200
        assert c.post(f"/api/admin/models/{id_err}/probe").status_code == 502

    with store.connection(write=True) as db:
        model_telemetry.record_check(
            db, id_ok, source="live", ok=True, http_status=200,
            latency_ms=115, error=None, checked_at=model_probe._now_iso(),
        )

    d_ctx, d_page, d_collector = _open_page(e2e_browser, 1440, 900)
    try:
        _sign_in_browser(d_page, e2e_workspace.base_url, ADMIN_EMAIL)
        d_page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
        expect(d_page.get_by_role("heading", name="Model administration")).to_be_visible()
        _verify_timeline_and_exports(d_page)
        d_collector.assert_clean()
    finally:
        d_ctx.close()

    m_ctx, m_page, m_collector = _open_page(e2e_browser, 390, 844)
    try:
        _sign_in_browser(m_page, e2e_workspace.base_url, ADMIN_EMAIL)
        m_page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
        expect(m_page.get_by_role("heading", name="Model administration")).to_be_visible()
        assert_no_horizontal_overflow(m_page)

        tabs = m_page.get_by_role("tablist", name="Admin sections").get_by_role("tab")
        expect(tabs).to_have_count(len(ADMIN_TABS))
        tabs.nth(0).focus()
        _assert_tab_strict_bounds(m_page, 0)
        for idx in range(1, len(ADMIN_TABS)):
            m_page.keyboard.press("ArrowRight")
            cur = tabs.nth(idx)
            expect(cur).to_be_focused()
            expect(cur).to_have_attribute("aria-selected", "true")
            panel_id = cur.get_attribute("aria-controls")
            assert panel_id
            expect(m_page.locator(f"#{panel_id}[role='tabpanel']")).to_be_visible()
            _assert_tab_strict_bounds(m_page, idx)
            assert_no_horizontal_overflow(m_page)

        m_page.keyboard.press("Home")
        expect(tabs.nth(0)).to_be_focused()
        expect(tabs.nth(0)).to_have_attribute("aria-selected", "true")
        _assert_tab_strict_bounds(m_page, 0)

        m_page.keyboard.press("End")
        expect(tabs.nth(len(ADMIN_TABS) - 1)).to_be_focused()
        expect(tabs.nth(len(ADMIN_TABS) - 1)).to_have_attribute("aria-selected", "true")
        expect(m_page.locator("#panel-compliance[role='tabpanel']")).to_be_visible()
        assert _assert_tab_strict_bounds(m_page, len(ADMIN_TABS) - 1) > 0
        assert_no_horizontal_overflow(m_page)

        _verify_timeline_and_exports(m_page)
        m_collector.assert_clean()
    finally:
        m_ctx.close()


def _queue_pills(page):
    strip = page.get_by_label("Assignment queues")
    return (
        strip,
        strip.get_by_role("button", name=re.compile(r"^Assigned to me\b")),
        strip.get_by_role("button", name=re.compile(r"^High priority\b")),
        strip.get_by_role("button", name=re.compile(r"^Unassigned\b")),
        strip.get_by_role("button", name=re.compile(r"^Overdue\b")),
    )


def _assert_queue_counts(page, *, me: str, high: str, free: str, overdue: str):
    strip, me_pill, high_pill, free_pill, overdue_pill = _queue_pills(page)
    expect(me_pill).to_contain_text(me)
    expect(high_pill).to_contain_text(high)
    expect(free_pill).to_contain_text(free)
    expect(overdue_pill).to_contain_text(overdue)
    return strip, me_pill, high_pill, free_pill, overdue_pill


@pytest.mark.parametrize("viewport", VIEWPORTS, ids=lambda v: v[2])
def test_m25_overdue_queue_pill_and_bulk_session_assignment(e2e_workspace, e2e_browser, viewport):
    width, height, _ = viewport
    _setup_users(e2e_workspace, emails=(ALICE_EMAIL,))
    past_due = (datetime.now(timezone.utc) - timedelta(days=3)).isoformat()
    future_date = (datetime.now(timezone.utc) + timedelta(days=10)).strftime("%Y-%m-%d")

    with e2e_workspace.client() as c:
        login_user(c, email=ALICE_EMAIL, password=PASS)
        sids = []
        for cand in ("Overdue Candidate", "Bulk Alpha Candidate", "Bulk Beta Candidate"):
            s = c.post("/api/sessions", json={"candidate": cand, "role": "Platform Lead", "policy": "No AI", "consent": True})
            s.raise_for_status()
            sid = s.json()["id"]
            c.post(f"/api/sessions/{sid}/answers", json={
                "question": "Explain idempotency keys.", "answer": "Store request hash with response TTL.", "references": [],
            }).raise_for_status()
            sids.append(sid)
        sid_overdue, _sid_alpha, _sid_beta = sids
        c.put(f"/api/sessions/{sid_overdue}/assignment", json={
            "assignee_email": ALICE_EMAIL, "priority": "normal", "due_at": past_due,
        }).raise_for_status()

    ctx, page, collector = _open_page(e2e_browser, width, height)
    try:
        _sign_in_browser(page, e2e_workspace.base_url, ALICE_EMAIL)
        page.goto(e2e_workspace.base_url + "/interviews/", wait_until="domcontentloaded")
        strip, _me, _high, _free, overdue_pill = _assert_queue_counts(page, me="1", high="0", free="2", overdue="1")
        assert_no_horizontal_overflow(page)

        overdue_pill.click()
        expect(overdue_pill).to_have_attribute("aria-pressed", "true")
        overdue_row = strip.locator("li", has_text="Overdue Candidate")
        expect(overdue_row).to_be_visible()
        expect(overdue_row.get_by_text("Overdue", exact=True)).to_be_visible()
        expect(strip).not_to_contain_text("Bulk Alpha Candidate")

        overdue_row.get_by_role("link").click()
        expect(page).to_have_url(f"{e2e_workspace.base_url}/interviews/review/?id={sid_overdue}")
        bar = page.get_by_label("Session assignment")
        expect(bar).to_contain_text(ALICE_EMAIL)
        expect(bar.get_by_text("Overdue", exact=True)).to_be_visible()
        assert_no_horizontal_overflow(page)

        page.goto(e2e_workspace.base_url + "/interviews/", wait_until="domcontentloaded")
        strip, _me, _high, free_pill, _overdue = _queue_pills(page)
        free_pill.click()
        expect(free_pill).to_have_attribute("aria-pressed", "true")
        strip.get_by_label("Select Bulk Alpha Candidate for bulk assignment").check()
        strip.get_by_label("Select Bulk Beta Candidate for bulk assignment").check()
        expect(strip.get_by_text("2 selected")).to_be_visible()

        strip.get_by_label("Bulk assignee email").fill(ALICE_EMAIL)
        strip.get_by_label("Bulk priority").select_option("high")
        strip.get_by_label("Bulk due date").fill(future_date)
        strip.get_by_role("button", name="Assign selected").click()

        expect(strip.get_by_role("status")).to_contain_text(f"Assigned 2 sessions to {ALICE_EMAIL}.")
        _assert_queue_counts(page, me="3", high="2", free="0", overdue="1")
        assert_no_horizontal_overflow(page)

        page.reload(wait_until="domcontentloaded")
        strip, _me, high_pill, _free, _overdue = _assert_queue_counts(page, me="3", high="2", free="0", overdue="1")
        high_pill.click()
        expect(strip).to_contain_text("Bulk Alpha Candidate")
        expect(strip).to_contain_text("Bulk Beta Candidate")
        strip.get_by_label("Select Bulk Alpha Candidate for bulk assignment").check()
        strip.get_by_label("Select Bulk Beta Candidate for bulk assignment").check()
        strip.get_by_role("button", name="Clear selected assignments").click()

        expect(strip.get_by_role("status")).to_contain_text("Cleared assignments for 2 sessions.")
        _assert_queue_counts(page, me="1", high="0", free="2", overdue="1")

        page.reload(wait_until="domcontentloaded")
        _assert_queue_counts(page, me="1", high="0", free="2", overdue="1")
        assert_no_horizontal_overflow(page)
        collector.assert_clean()
    finally:
        ctx.close()
