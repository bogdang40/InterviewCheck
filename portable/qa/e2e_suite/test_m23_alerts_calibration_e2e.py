"""Playwright E2E tests for M23 admin alert delivery history/retry and calibration queue."""
from contextlib import contextmanager
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import re
import threading

import httpx
from playwright.sync_api import expect
import pytest

from e2e_suite.harness import (
    ConsoleErrorCollector,
    assert_no_horizontal_overflow,
    login_user,
    signup_user,
)

ADMIN_EMAIL = "admin-m23@example.test"
BOB_EMAIL = "bob-m23@example.test"
BOOTSTRAP_SECRET = "m23-bootstrap-secret-1234"
PASS = "Synthetic-M23-Pass-9876"
WEBHOOK_URL = "https://hooks.example.com/alerts"
WEBHOOK_SECRET = "whsec-m23-e2e-signing-secret"
VIEWPORTS = [(1440, 900, "desktop-1440"), (390, 844, "mobile-390")]


@contextmanager
def _local_webhook_server(monkeypatch, statuses: list[int]):
    captured: list[dict] = []
    lock = threading.Lock()
    queue = list(statuses)

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length") or "0")
            body = self.rfile.read(length)
            with lock:
                status = queue.pop(0) if queue else 200
                captured.append({
                    "path": self.path,
                    "headers": {k.lower(): v for k, v in self.headers.items()},
                    "body": body,
                    "status": status,
                })
            self.send_response(status)
            self.end_headers()
            self.wfile.write(b"ok")

        def log_message(self, format, *args):
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    from api import alert_rules, ssrf_guard

    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])

    async def local_dispatch(url: str, body: bytes, headers: dict[str, str]):
        async with httpx.AsyncClient(timeout=5.0, trust_env=False) as client:
            resp = await client.post(f"http://127.0.0.1:{port}/alerts", content=body, headers=headers)
        ok = 200 <= resp.status_code < 300
        err = None if ok else f"Webhook returned HTTP {resp.status_code}."
        return ok, resp.status_code, err

    monkeypatch.setattr(alert_rules, "dispatch_fn", local_dispatch)
    try:
        yield captured, lock
    finally:
        server.shutdown()
        server.server_close()


def _setup_users(e2e_workspace) -> None:
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    with e2e_workspace.client() as client:
        signup_user(client, email=ADMIN_EMAIL, password=PASS, admin_secret=BOOTSTRAP_SECRET)
        signup_user(client, email=BOB_EMAIL, password=PASS)


def _sign_in_browser(page, base_url: str, email: str) -> None:
    page.goto(base_url + "/account/", wait_until="domcontentloaded")
    page.get_by_label("Operator email").fill(email)
    page.get_by_label("Password", exact=True).fill(PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(f"{email} · Access active")).to_be_visible()


def _create_role(client, name: str, questions: list[str]) -> dict:
    res = client.post("/api/roles", json={
        "name": name,
        "description": f"{name} calibration scope",
        "questions": questions,
        "policy": "No external assistance.",
        "permitted_sources": [],
    })
    res.raise_for_status()
    return res.json()


def _seed_session(client, *, role: dict, candidate: str, questions: list[str]) -> tuple[str, list[str]]:
    s_res = client.post("/api/sessions", json={
        "candidate": candidate,
        "role": role["name"],
        "role_id": role["id"],
        "consent": True,
    })
    s_res.raise_for_status()
    sid = s_res.json()["id"]
    aids: list[str] = []
    for idx, question in enumerate(questions, start=1):
        a_res = client.post(f"/api/sessions/{sid}/answers", json={
            "question": question,
            "answer": f"Structured answer {idx} for {candidate}.",
            "references": [],
            "planned_slot": idx,
        })
        a_res.raise_for_status()
        aids.append(a_res.json()["id"])
    return sid, aids


def test_m23_admin_alert_delivery_history_filter_retry_and_exports(e2e_workspace, desktop_page, monkeypatch):
    _setup_users(e2e_workspace)
    with _local_webhook_server(monkeypatch, [502, 200, 503, 202]) as (captured, lock):
        with e2e_workspace.client() as adm:
            login_user(adm, email=ADMIN_EMAIL, password=PASS)
            assert adm.post("/api/admin/alerts", json={
                "name": "Blocked SSRF", "trigger_type": "probe_failed",
                "threshold_value": 1, "webhook_url": "https://127.0.0.1/hook",
            }).status_code == 400
            r1 = adm.post("/api/admin/alerts", json={
                "name": "=CMD|RuleAlpha", "trigger_type": "model_error_streak",
                "threshold_value": 1, "capability_filter": "reference",
                "webhook_url": WEBHOOK_URL, "signing_secret": WEBHOOK_SECRET, "cooldown_minutes": 0,
            })
            r1.raise_for_status()
            r1_id = r1.json()["rule"]["id"]
            r2 = adm.post("/api/admin/alerts", json={
                "name": "RuleBeta", "trigger_type": "probe_failed",
                "threshold_value": 1, "webhook_url": WEBHOOK_URL, "cooldown_minutes": 0,
            })
            r2.raise_for_status()
            r2_id = r2.json()["rule"]["id"]
            assert adm.post(f"/api/admin/alerts/{r1_id}/test").json()["ok"] is False
            assert adm.post(f"/api/admin/alerts/{r2_id}/test").json()["ok"] is True
            assert adm.post(f"/api/admin/alerts/{r2_id}/test").json()["ok"] is False

        page, collector = desktop_page
        _sign_in_browser(page, e2e_workspace.base_url, ADMIN_EMAIL)
        page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
        page.get_by_role("tab", name="Security").click()

        history = page.locator("[aria-label='Webhook delivery history']")
        expect(history).to_be_visible()
        kpi = history.locator("[aria-label='Alert delivery summary']")
        expect(kpi).to_contain_text("Total3")
        expect(kpi).to_contain_text("2 failing rules")
        expect(kpi).to_contain_text("Delivered1")
        expect(kpi).to_contain_text("Failed2")
        expect(kpi).to_contain_text("33.3%")
        assert WEBHOOK_SECRET not in page.content()

        history.get_by_label("Filter deliveries by status").select_option("failed")
        expect(kpi).to_contain_text("Total2")
        expect(kpi).to_contain_text("Failed2")
        expect(history.locator("tbody tr")).to_have_count(2)

        history.get_by_label("Filter deliveries by rule").select_option(r1_id)
        expect(kpi).to_contain_text("Total1")
        expect(history.locator("tbody tr")).to_have_count(1)
        expect(history.locator("tbody tr").first).to_contain_text("=CMD|RuleAlpha")

        history.locator("tbody tr").first.get_by_role("button", name="Retry").click()
        expect(history.locator("[role='status']")).to_contain_text(
            re.compile(r"Retried delivery #\d+ for =CMD\|RuleAlpha \(HTTP 202\)\.")
        )
        expect(history.locator("tbody tr")).to_have_count(1)

        with lock:
            assert len(captured) == 4
            retry_req = captured[-1]
        expected_sig = "sha256=" + hmac.new(WEBHOOK_SECRET.encode(), retry_req["body"], hashlib.sha256).hexdigest()
        assert retry_req["headers"]["x-interviewcheck-event"] == "alert.retry"
        assert retry_req["headers"]["x-interviewcheck-delivery"].startswith("retry:")
        assert retry_req["headers"]["x-interviewcheck-signature"] == expected_sig
        assert json.loads(retry_req["body"])["event"] == "alert.retry"

        history.get_by_label("Filter deliveries by status").select_option("")
        history.get_by_label("Filter deliveries by rule").select_option("")
        expect(kpi).to_contain_text("Total4")
        expect(kpi).to_contain_text("Delivered2")
        expect(kpi).to_contain_text("Failed2")
        expect(kpi).to_contain_text("50.0%")
        expect(history.locator("tbody tr").first).to_contain_text("Delivered")
        expect(history.locator("tbody tr").first).to_contain_text("202")

        with page.expect_download() as csv_dl:
            history.get_by_role("button", name="Export CSV").click()
        csv_text = csv_dl.value.path().read_text(encoding="utf-8-sig")
        assert "'=CMD|RuleAlpha" in csv_text
        assert "alert.retry" in csv_text or "retry:" in csv_text
        assert WEBHOOK_SECRET not in csv_text

        history.get_by_label("Filter deliveries by status").select_option("ok")
        expect(history.locator("tbody tr")).to_have_count(2)
        with page.expect_download() as json_dl:
            history.get_by_role("button", name="Export JSON").click()
        json_text = json_dl.value.path().read_text(encoding="utf-8")
        exported = json.loads(json_text)
        assert exported["summary"]["ok_count"] == 2
        assert len(exported["items"]) == 2 and all(item["ok"] is True for item in exported["items"])
        assert WEBHOOK_SECRET not in json_text
        collector.assert_clean()


def test_m23_roles_calibration_queue_filter_deeplink_and_exports(e2e_workspace, desktop_page):
    _setup_users(e2e_workspace)
    with e2e_workspace.client() as alice, e2e_workspace.client() as bob:
        login_user(alice, email=ADMIN_EMAIL, password=PASS)
        login_user(bob, email=BOB_EMAIL, password=PASS)
        r_sys = _create_role(alice, "Systems Role", ["How do you avoid deadlocks?", "Explain WAL fsync."])
        r_sec = _create_role(alice, "Security Role", ["Threat model RPCs."])

        s1, (a1, a2) = _seed_session(
            alice, role=r_sys, candidate='=HYPERLINK("https://bad")',
            questions=["How do you avoid deadlocks?", "Explain WAL fsync."],
        )
        s2, (a3,) = _seed_session(alice, role=r_sec, candidate="Grace Hopper", questions=["Threat model RPCs."])

        # Consensus on a1, disagreement on a2 (2nd question) and a3.
        alice.patch(f"/api/sessions/{s1}/answers/{a1}", json={"disposition": "explained", "note": "Agreed"}).raise_for_status()
        bob.patch(f"/api/sessions/{s1}/answers/{a1}", json={"disposition": "explained", "note": "Agreed"}).raise_for_status()
        alice.patch(f"/api/sessions/{s1}/answers/{a2}", json={"disposition": "explained", "note": "Solid WAL"}).raise_for_status()
        bob.patch(f"/api/sessions/{s1}/answers/{a2}", json={"disposition": "unresolved", "note": "Missing fsync"}).raise_for_status()
        alice.patch(f"/api/sessions/{s2}/answers/{a3}", json={"disposition": "disclosed", "note": "Policy note"}).raise_for_status()
        bob.patch(f"/api/sessions/{s2}/answers/{a3}", json={"disposition": "explained", "note": "Cleared"}).raise_for_status()

    page, collector = desktop_page
    _sign_in_browser(page, e2e_workspace.base_url, ADMIN_EMAIL)
    page.goto(e2e_workspace.base_url + "/roles/", wait_until="domcontentloaded")

    cal = page.get_by_role("region", name="Reviewer calibration disagreement queue")
    expect(cal).to_be_visible()
    expect(cal).to_contain_text("2 disagreements")
    expect(cal).to_contain_text("2 roles affected")
    expect(cal).to_contain_text("2 active reviewers")
    expect(cal).to_contain_text("Explain WAL fsync.")
    expect(cal).to_contain_text("Threat model RPCs.")
    expect(cal).to_contain_text(f"{ADMIN_EMAIL}: Explained")
    expect(cal).to_contain_text(f"{BOB_EMAIL}: Unresolved")

    cal.get_by_label("Filter calibration queue by role").select_option(r_sys["id"])
    expect(cal).to_contain_text("1 disagreement")
    expect(cal).to_contain_text("Explain WAL fsync.")
    expect(cal).not_to_contain_text("Threat model RPCs.")

    with page.expect_download() as csv_dl:
        cal.get_by_role("button", name="Export CSV").click()
    csv_text = csv_dl.value.path().read_text(encoding="utf-8-sig")
    assert "reviewer_metric" in csv_text and "disagreement" in csv_text
    assert "'=HYPERLINK" in csv_text
    assert "Threat model RPCs." not in csv_text

    cal.get_by_label("Filter calibration queue by role").select_option("")
    expect(cal).to_contain_text("2 disagreements")
    with page.expect_download() as json_dl:
        cal.get_by_role("button", name="Export JSON").click()
    jdata = json.loads(json_dl.value.path().read_text(encoding="utf-8"))
    assert len(jdata["disagreements"]) == 2
    assert len(jdata["reviewer_metrics"]) >= 2

    cal.get_by_label("Filter calibration queue by role").select_option(r_sys["id"])
    expect(cal).to_contain_text("1 disagreement")
    expect(cal.locator("ul > li")).to_have_count(1)
    review_link = cal.get_by_role("link", name="Review exchange")
    expect(review_link).to_have_attribute("href", f"/interviews/review/?id={s1}&answer={a2}#panel-discussion")
    review_link.click()
    expect(page).to_have_url(re.compile(rf"/interviews/review/\?id={s1}&answer={a2}"))
    expect(page.get_by_role("heading", name="Explain WAL fsync.")).to_be_visible()
    collector.assert_clean()


@pytest.mark.parametrize("viewport", VIEWPORTS, ids=lambda v: v[2])
def test_m23_responsive_desktop_and_mobile_viewports(e2e_workspace, e2e_browser, monkeypatch, viewport):
    width, height, _ = viewport
    _setup_users(e2e_workspace)
    with _local_webhook_server(monkeypatch, [502]):
        with e2e_workspace.client() as alice, e2e_workspace.client() as bob:
            login_user(alice, email=ADMIN_EMAIL, password=PASS)
            login_user(bob, email=BOB_EMAIL, password=PASS)
            r_post = alice.post("/api/admin/alerts", json={
                "name": "Viewport Alert", "trigger_type": "probe_failed",
                "threshold_value": 1, "webhook_url": WEBHOOK_URL, "cooldown_minutes": 0,
            })
            r_post.raise_for_status()
            alice.post(f"/api/admin/alerts/{r_post.json()['rule']['id']}/test").raise_for_status()

            role = _create_role(alice, "Viewport Role", ["Explain isolation."])
            sid, (aid,) = _seed_session(alice, role=role, candidate="Ada", questions=["Explain isolation."])
            alice.patch(f"/api/sessions/{sid}/answers/{aid}", json={"disposition": "explained", "note": "Good"}).raise_for_status()
            bob.patch(f"/api/sessions/{sid}/answers/{aid}", json={"disposition": "unresolved", "note": "Check"}).raise_for_status()

        mobile = width <= 480
        ctx = e2e_browser.new_context(
            viewport={"width": width, "height": height},
            reduced_motion="reduce", is_mobile=mobile, has_touch=mobile,
        )
        page = ctx.new_page()
        page.set_default_timeout(10_000)
        collector = ConsoleErrorCollector()
        collector.attach(page)
        try:
            _sign_in_browser(page, e2e_workspace.base_url, ADMIN_EMAIL)
            page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
            page.get_by_role("tab", name="Security").click()
            history = page.locator("[aria-label='Webhook delivery history']")
            expect(history.locator("tbody tr").first).to_contain_text("Viewport Alert")
            if mobile:
                box = history.locator("tbody tr").first.get_by_role("button", name="Retry").bounding_box()
                assert box is not None and box["height"] >= 44
            assert_no_horizontal_overflow(page)

            page.goto(e2e_workspace.base_url + "/roles/", wait_until="domcontentloaded")
            cal = page.get_by_role("region", name="Reviewer calibration disagreement queue")
            expect(cal).to_contain_text("1 disagreement")
            expect(cal).to_contain_text("Explain isolation.")
            if mobile:
                link_box = cal.get_by_role("link", name="Review exchange").bounding_box()
                assert link_box is not None and link_box["height"] >= 44
            assert_no_horizontal_overflow(page)
            collector.assert_clean()
        finally:
            ctx.close()
