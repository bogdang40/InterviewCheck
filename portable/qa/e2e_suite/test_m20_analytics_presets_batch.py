"""Opaque-box Playwright E2E tests for M20 cohort analytics, global tag/role filters, presets, and batch ops."""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
from urllib.parse import parse_qs, urlsplit
from uuid import uuid4

import httpx
from playwright.sync_api import expect
import pytest

from api import ssrf_guard, store
from e2e_suite.harness import assert_no_horizontal_overflow, login_user, signup_user

ADMIN_EMAIL = "admin-m20@example.test"
MEMBER_EMAIL = "member-m20@example.test"
BOOTSTRAP_SECRET = "m20-bootstrap-secret-1234"
ADMIN_PASS = "Synthetic-M20-Admin-Pass-1"
MEMBER_PASS = "Synthetic-M20-Member-Pass-1"
OK_SECRET = "sk-m20-preset-ok-secret-1111"
ERR_SECRET = "sk-m20-batch-err-secret-2222"


@contextmanager
def _mock_llm_probe_server(monkeypatch):
    requests_seen: list[tuple[str, str]] = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            requests_seen.append(("GET", self.path))
            ok = self.path.startswith("/ok/")
            body = json.dumps({"data": [{"id": "qwen-2.5-72b-instruct"}]} if ok else {"error": "down"}).encode("utf-8")
            self.send_response(200 if ok else 502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format, *args):
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    class LocalMockTransport(httpx.AsyncHTTPTransport):
        async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
            if request.url.host == "mock-llm.example.test":
                request.url = request.url.copy_with(scheme="http", host="127.0.0.1", port=port)
            return await super().handle_async_request(request)

    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])
    monkeypatch.setattr(ssrf_guard, "SafeAsyncTransport", LocalMockTransport)
    try:
        yield requests_seen
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def _create_role(c, name: str) -> dict:
    res = c.post("/api/roles", json={
        "name": name, "description": f"{name} evaluation", "policy": "Declared reference material only.",
        "questions": ["Describe system reliability tradeoffs."], "permitted_sources": [],
        "rubric": [{"id": "arch", "criterion": "Architecture", "weight": 2}],
    })
    res.raise_for_status()
    return res.json()


def _create_session(
    c, *, candidate: str, role: dict, tags: list[str] | None = None,
    created_at: str | None = None, finished: bool = False, archived: bool = False,
    trashed: bool = False, disposition: str | None = None, rating: int | None = None,
) -> str:
    s_res = c.post("/api/sessions", json={
        "candidate": candidate, "role": role["name"], "role_id": role["id"], "policy": role["policy"], "consent": True,
    })
    s_res.raise_for_status()
    sid = s_res.json()["id"]
    if disposition is not None:
        a_res = c.post(f"/api/sessions/{sid}/answers", json={
            "question": "Describe system reliability tradeoffs.", "answer": "Use quorum replication.", "references": [],
        })
        a_res.raise_for_status()
        c.patch(f"/api/sessions/{sid}/answers/{a_res.json()['id']}", json={"disposition": disposition, "note": "Ok"}).raise_for_status()
    if rating is not None:
        c.put(f"/api/sessions/{sid}/scorecard", json={
            "items": [{"criterion_id": "arch", "criterion_label": "Architecture", "weight": 2, "rating": rating, "rationale": "Solid"}],
        }).raise_for_status()
    if tags:
        c.post("/api/interviews/bulk/tag", json={"session_ids": [sid], "add": tags, "remove": []}).raise_for_status()
    if finished:
        c.post(f"/api/sessions/{sid}/finish").raise_for_status()
    if archived:
        with store.connection(write=True) as db:
            db.execute("UPDATE sessions SET consent=0 WHERE id=?", (sid,))
    if created_at:
        with store.connection(write=True) as db:
            db.execute("UPDATE sessions SET created_at=? WHERE id=?", (created_at, sid))
    if trashed:
        c.post("/api/interviews/bulk/archive", json={"session_ids": [sid], "confirm_count": 1}).raise_for_status()
    return sid


def _sign_in_admin(page, base_url: str) -> None:
    page.goto(base_url + "/admin/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Administrator sign in required")).to_be_visible()
    page.get_by_label("Operator email").fill(ADMIN_EMAIL)
    page.get_by_label("Password", exact=True).fill(ADMIN_PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_role("heading", name="Model administration")).to_be_visible()


def test_m20_data_cohort_analytics_filters_charts_and_exports(e2e_workspace, desktop_page, mobile_page):
    with e2e_workspace.client() as c:
        role_sys = _create_role(c, "Systems Architect")
        role_prod = _create_role(c, "Product Lead")
        sid_alice = _create_session(
            c, candidate="Alice Alpha", role=role_sys, tags=["systems", "priority"],
            created_at="2026-10-10T12:00:00Z", finished=True, disposition="explained", rating=5,
        )
        _create_session(
            c, candidate="=CMD('calc')", role=role_sys, tags=["systems"],
            created_at="2026-10-15T12:00:00Z", disposition="unresolved", rating=2,
        )
        _create_session(
            c, candidate="Clara Archived", role=role_prod, tags=["product"],
            created_at="2026-10-20T12:00:00Z", archived=True,
        )
        _create_session(
            c, candidate="Trashed Bob", role=role_sys, tags=["systems", "trashed-only"],
            created_at="2026-10-22T12:00:00Z", trashed=True, disposition="explained", rating=1,
        )

    page, collector = desktop_page
    page.goto(e2e_workspace.base_url + "/data/", wait_until="domcontentloaded")
    cohort = page.locator("section[aria-labelledby='cohort-analytics-heading']")
    expect(cohort.get_by_role("heading", name="Cohort analytics and scorecard calibration")).to_be_visible()
    expect(cohort.get_by_text("1 active / 1 finished / 1 archived")).to_be_visible()
    expect(cohort.locator("strong", has_text="50.0%").first).to_be_visible()
    expect(cohort.locator("strong", has_text="70.0%")).to_be_visible()
    expect(cohort.get_by_text("2 scored sessions")).to_be_visible()

    hist = cohort.get_by_label("Scorecard distribution histogram")
    expect(hist).to_contain_text("40-60%")
    expect(hist).to_contain_text("80-100%")
    tag_table = cohort.get_by_role("table", name="Cohort review outcomes by tag")
    expect(tag_table).to_contain_text("systems")
    expect(tag_table).to_contain_text("priority")
    expect(tag_table.get_by_text("trashed-only")).to_have_count(0)
    expect(cohort.get_by_role("table", name="Daily cohort timeline")).to_contain_text("2026-10-15")
    pipeline = cohort.get_by_role("table", name="Cohort candidate pipeline")
    expect(pipeline.get_by_role("link", name="Alice Alpha")).to_have_attribute("href", f"/interviews/review/?id={sid_alice}")
    expect(pipeline.get_by_text("Trashed Bob")).to_have_count(0)

    tag_table.get_by_role("button", name="priority").click()
    expect(cohort.get_by_role("heading", name="Candidate pipeline (1)")).to_be_visible()
    cohort.get_by_role("button", name="Clear cohort filters").click()
    expect(cohort.get_by_role("heading", name="Candidate pipeline (3)")).to_be_visible()

    cohort.get_by_label("Filter cohort by lifecycle").select_option("archived")
    expect(cohort.get_by_role("table", name="Cohort candidate pipeline")).to_contain_text("Clara Archived")
    cohort.get_by_role("button", name="Clear cohort filters").click()

    cohort.get_by_label("Cohort start date").fill("2026-10-18")
    cohort.get_by_label("Cohort end date").fill("2026-10-12")
    expect(cohort.get_by_role("alert")).to_contain_text("The start date must be on or before the end date.")
    cohort.get_by_label("Cohort start date").fill("2026-10-12")
    cohort.get_by_label("Cohort end date").fill("2026-10-16")
    expect(cohort.get_by_role("table", name="Cohort candidate pipeline")).to_contain_text("=CMD('calc')")
    cohort.get_by_role("button", name="Clear cohort filters").click()

    cohort.get_by_label("Filter cohort by role").select_option(role_sys["id"])
    expect(cohort.get_by_role("heading", name="Candidate pipeline (2)")).to_be_visible()

    with page.expect_download() as csv_dl:
        cohort.get_by_role("button", name="Export CSV").click()
    assert csv_dl.value.suggested_filename == "cohort-analytics.csv"
    csv_text = csv_dl.value.path().read_text(encoding="utf-8-sig")
    assert csv_text.startswith("Session ID,Candidate,Role,Role ID,Lifecycle,")
    assert "Alice Alpha" in csv_text and "'=CMD('calc')" in csv_text and "Trashed Bob" not in csv_text

    with page.expect_download() as json_dl:
        cohort.get_by_role("button", name="Export JSON").click()
    assert json_dl.value.suggested_filename == "cohort-analytics.json"
    exported = json.loads(json_dl.value.path().read_text(encoding="utf-8"))
    assert exported["format"] == "interviewcheck.cohort_analytics"
    assert exported["filters"]["role_id"] == role_sys["id"]
    assert exported["summary"]["session_count"] == 2
    assert_no_horizontal_overflow(page)
    collector.assert_clean()

    m_page, m_collector = mobile_page
    m_page.goto(e2e_workspace.base_url + "/data/", wait_until="domcontentloaded")
    expect(m_page.locator("section[aria-labelledby='cohort-analytics-heading']").get_by_role("heading", name="Candidate pipeline (3)")).to_be_visible()
    assert_no_horizontal_overflow(m_page)
    m_collector.assert_clean()


def test_m20_interviews_global_tag_chips_and_role_url_filter(e2e_workspace, desktop_page, mobile_page):
    with e2e_workspace.client() as c:
        role_be = _create_role(c, "Backend Platform")
        role_fe = _create_role(c, "Frontend Design")
        _create_session(c, candidate="Backend Page2 Rare", role=role_be, tags=["page2-rare", "shared-cohort"], created_at="2026-10-01T10:00:00Z")
        _create_session(c, candidate="Backend Page2 Plain", role=role_be, created_at="2026-10-01T11:00:00Z")
        for idx in range(25):
            _create_session(
                c, candidate=f"Frontend Candidate {idx:02d}", role=role_fe,
                tags=["shared-cohort"] if idx == 0 else None,
                created_at=f"2026-10-02T{idx:02d}:00:00Z" if idx < 24 else "2026-10-03T00:00:00Z",
            )

    page, collector = desktop_page
    page.goto(e2e_workspace.base_url + "/interviews/", wait_until="domcontentloaded")
    expect(page.get_by_text("1 to 25 of 27 matching interviews")).to_be_visible()
    tag_group = page.get_by_role("group", name="Tag filters")
    expect(tag_group.get_by_role("button", name="shared-cohort(2)")).to_be_visible()
    expect(tag_group.get_by_role("button", name="page2-rare(1)")).to_be_visible()

    tag_group.get_by_role("button", name="page2-rare(1)").click()
    expect(page.locator("ul.work-list > li")).to_have_count(1)
    expect(page.locator("ul.work-list")).to_contain_text("Backend Page2 Rare")
    assert parse_qs(urlsplit(page.url).query).get("tag") == ["page2-rare"]
    page.get_by_role("button", name="Clear filters").click()
    expect(page.get_by_text("1 to 25 of 27 matching interviews")).to_be_visible()

    page.get_by_label("Filter by role").select_option(role_be["id"])
    expect(page.locator("ul.work-list > li")).to_have_count(2)
    expect(page.locator("ul.work-list")).to_contain_text("Backend Page2 Rare")
    assert parse_qs(urlsplit(page.url).query).get("role_id") == [role_be["id"]]

    page.reload(wait_until="domcontentloaded")
    expect(page.get_by_label("Filter by role")).to_have_value(role_be["id"])
    expect(page.locator("ul.work-list > li")).to_have_count(2)
    assert_no_horizontal_overflow(page)

    page.get_by_role("button", name="Clear filters").click()
    expect(page.get_by_label("Filter by role")).to_have_value("")
    assert "role_id" not in parse_qs(urlsplit(page.url).query)
    collector.assert_clean()

    m_page, m_collector = mobile_page
    m_page.goto(f"{e2e_workspace.base_url}/interviews/?role_id={role_be['id']}", wait_until="domcontentloaded")
    expect(m_page.get_by_text("2 of 27 shown")).to_be_visible()
    expect(m_page.get_by_role("group", name="Tag filters").get_by_role("button", name="page2-rare(1)")).to_be_visible()
    assert_no_horizontal_overflow(m_page)
    m_collector.assert_clean()


def test_m20_admin_presets_batch_toggle_probe_and_security(e2e_workspace, desktop_page, mobile_page, monkeypatch):
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
        signup_user(c, email=MEMBER_EMAIL, password=MEMBER_PASS)

    dummy_ids = [str(uuid4())]
    with e2e_workspace.client() as anon:
        for path in ("/api/admin/models/presets", "/api/analytics/cohorts", "/api/analytics/cohorts/export", "/api/interviews/tags"):
            assert anon.get(path).status_code == 401
        assert anon.post("/api/admin/models/batch/toggle", json={"model_ids": dummy_ids, "enabled": False}).status_code == 401
        assert anon.post("/api/admin/models/batch/probe", json={"model_ids": dummy_ids}).status_code == 401
    with e2e_workspace.client() as member_api:
        login_user(member_api, email=MEMBER_EMAIL, password=MEMBER_PASS)
        assert member_api.get("/api/admin/models/presets").status_code == 403
        assert member_api.post("/api/admin/models/batch/toggle", json={"model_ids": dummy_ids, "enabled": False}).status_code == 403
        assert member_api.post("/api/admin/models/batch/probe", json={"model_ids": dummy_ids}).status_code == 403
    with e2e_workspace.client() as no_csrf:
        login_user(no_csrf, email=ADMIN_EMAIL, password=ADMIN_PASS)
        no_csrf.headers.pop("X-InterviewCheck", None)
        assert no_csrf.post("/api/admin/models/batch/toggle", json={"model_ids": dummy_ids, "enabled": False}).status_code == 403
        assert no_csrf.post("/api/admin/models/batch/probe", json={"model_ids": dummy_ids}).status_code == 403

    with _mock_llm_probe_server(monkeypatch) as mock_requests:
        page, collector = desktop_page
        _sign_in_admin(page, e2e_workspace.base_url)

        page.get_by_role("button", name="Connect model").first.click()
        dlg = page.get_by_role("dialog", name="Connect model")
        preset_select = dlg.get_by_label("Quick-start template")
        expect(preset_select.locator("option[value='compat-qwen-planning']")).to_have_count(1)
        preset_select.select_option("compat-qwen-planning")
        expect(dlg.get_by_role("combobox", name="Provider", exact=True)).to_have_value("openai_compatible")
        expect(dlg.get_by_role("combobox", name="Capability", exact=True)).to_have_value("question_planning")
        expect(dlg.get_by_label("Display name")).to_have_value("OpenAI-Compatible (Planning)")
        expect(dlg.get_by_label("Model ID")).to_have_value("qwen-2.5-72b-instruct")
        expect(dlg.get_by_label("Slug (optional, auto-generated if blank)")).to_have_value("compat-qwen-plan")
        expect(dlg.get_by_label("Endpoint URL (HTTPS)")).to_have_attribute("placeholder", "https://llm.internal.example/v1")
        expect(dlg.get_by_label("Temperature (0 to 2)")).to_have_value("0.3")
        expect(dlg.get_by_label("Max tokens (1 to 128000)")).to_have_value("1400")

        dlg.get_by_label("Endpoint URL (HTTPS)").fill("https://mock-llm.example.test/ok/v1")
        dlg.get_by_label("API key").fill(OK_SECRET)
        dlg.get_by_role("button", name="Save and connect").click()
        expect(dlg).to_have_count(0)
        ok_card = page.locator("article.admin-model-card", has_text="OpenAI-Compatible (Planning)")
        expect(ok_card).to_be_visible()

        with e2e_workspace.client() as admin_api:
            login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
            admin_api.post("/api/admin/models", json={
                "display_name": "Mock Failing Judge", "slug": "mock-err-judge",
                "provider": "openai_compatible", "capability": "judge", "model_id": "llama-3.3-70b-instruct",
                "endpoint": "https://mock-llm.example.test/err/v1", "apiKey": ERR_SECRET, "enabled": True,
            }).raise_for_status()

        page.reload(wait_until="domcontentloaded")
        err_card = page.locator("article.admin-model-card", has_text="Mock Failing Judge")
        expect(ok_card).to_be_visible()
        expect(err_card).to_be_visible()

        batch_bar = page.get_by_role("region", name="Batch model operations")
        page.get_by_label("Select OpenAI-Compatible (Planning)").check()
        page.get_by_label("Select Mock Failing Judge").check()
        expect(batch_bar).to_contain_text("2 selected")

        batch_bar.get_by_role("button", name="Pause selected").click()
        expect(page.get_by_text("2 models disabled.")).to_be_visible()
        page.reload(wait_until="domcontentloaded")
        expect(ok_card).to_contain_text("disabled")
        expect(err_card).to_contain_text("disabled")

        batch_bar.get_by_role("button", name="Select visible (2)").click()
        batch_bar.get_by_role("button", name="Activate selected").click()
        expect(page.get_by_text("2 models enabled.")).to_be_visible()
        expect(ok_card).to_contain_text("unverified")
        expect(err_card).to_contain_text("unverified")

        batch_bar.get_by_role("button", name="Batch probe").click()
        summary = batch_bar.get_by_role("status", name="Batch probe results")
        expect(summary).to_contain_text("Batch probe summary: 1 connected, 1 failed out of 2.")
        expect(summary).to_contain_text("OpenAI-Compatible (Planning)")
        expect(summary).to_contain_text("Mock Failing Judge")
        expect(summary).to_contain_text("HTTP 502")
        assert any(path == "/ok/v1/models" for _, path in mock_requests)
        assert any(path == "/err/v1/models" for _, path in mock_requests)

        page.reload(wait_until="domcontentloaded")
        expect(ok_card).to_contain_text("connected")
        expect(err_card).to_contain_text("error")
        html = page.content()
        assert OK_SECRET not in html and ERR_SECRET not in html
        assert_no_horizontal_overflow(page)
        collector.assert_clean()

        m_page, m_collector = mobile_page
        _sign_in_admin(m_page, e2e_workspace.base_url)
        m_batch = m_page.get_by_role("region", name="Batch model operations")
        expect(m_batch.get_by_role("button", name="Select visible (2)")).to_be_visible()
        expect(m_batch.get_by_role("button", name="Batch probe")).to_be_visible()
        assert_no_horizontal_overflow(m_page)
        m_collector.assert_clean()
