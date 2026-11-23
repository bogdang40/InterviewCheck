"""Cross-wave M11-M22 Playwright E2E hardening across desktop (1440x900) and mobile (390x844)."""
import json

from playwright.sync_api import expect
import pytest

from e2e_suite.harness import ConsoleErrorCollector, assert_no_horizontal_overflow, login_user, signup_user

ADMIN_EMAIL = "admin-m22@example.test"
ADMIN_PASS = "Synthetic-M22-Pass-9876"
BOOTSTRAP_SECRET = "m22-bootstrap-secret-1234"
VIEWPORTS = [(1440, 900, "desktop-1440"), (390, 844, "mobile-390")]
ADMIN_TABS = ("Models", "Accounts", "Audit log", "Diagnostics", "Playground", "Security", "Prompts & SLA", "Compliance")


def _open_page(e2e_browser, width: int, height: int):
    mobile = width <= 480
    ctx = e2e_browser.new_context(
        viewport={"width": width, "height": height}, reduced_motion="reduce", is_mobile=mobile, has_touch=mobile,
    )
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    page.set_default_navigation_timeout(30_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    return ctx, page, collector


def _intercept_until_cleared(page, pattern: str, *, status: int, detail: str, once: bool = True):
    state = {"active": True, "hits": 0, "routed": True}

    def handler(route):
        if state["active"]:
            state["hits"] += 1
            if once:
                state["active"] = False
            route.fulfill(status=status, content_type="application/json", body=json.dumps({"detail": detail}))
            return
        route.continue_()

    def clear() -> None:
        state["active"] = False
        if state["routed"]:
            state["routed"] = False
            page.unroute(pattern, handler)

    page.route(pattern, handler)
    state["clear"] = clear
    return state


def _assert_expected_errors(
    collector: ConsoleErrorCollector,
    status: int,
    *,
    page=None,
    gate: dict | None = None,
    exact_one: bool = True,
) -> None:
    if gate is not None:
        gate["clear"]()
    if page is not None:
        expected_hits = gate["hits"] if gate is not None else 1
        for _ in range(40):
            if len(collector.server_errors) >= expected_hits and len(collector.console_errors) >= expected_hits:
                break
            page.wait_for_timeout(25)
        page.wait_for_timeout(150)
    assert not collector.page_errors, f"Uncaught page errors: {collector.page_errors}"
    assert collector.server_errors and all(str(status) in e for e in collector.server_errors), collector.server_errors
    assert collector.console_errors and all(str(status) in e for e in collector.console_errors), collector.console_errors
    if exact_one:
        assert len(collector.server_errors) == 1 and len(collector.console_errors) == 1
    collector.reset()


def _setup_admin(e2e_workspace) -> None:
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    with e2e_workspace.client() as client:
        signup_user(client, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)


def _sign_in_browser(page, base_url: str) -> None:
    page.goto(base_url + "/account/", wait_until="domcontentloaded")
    page.get_by_label("Operator email").fill(ADMIN_EMAIL)
    page.get_by_label("Password", exact=True).fill(ADMIN_PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(f"{ADMIN_EMAIL} · Access active")).to_be_visible()


def _create_role_with_rubric(client, name: str) -> dict:
    res = client.post("/api/roles", json={
        "name": name, "description": f"{name} engineering interviews", "questions": ["Describe your isolation strategy."],
        "policy": "No external assistance.", "permitted_sources": [{"label": "Reference Spec", "text": "Use serializable snapshots."}],
        "rubric": [{"id": "crit-design", "criterion": "System Design", "weight": 50,
                    "expected_signals": ["Mentions isolation guarantees"], "red_flags": ["Skips failure modes"]}],
        "change_note": "Initial M22 rubric",
    })
    res.raise_for_status()
    return res.json()


def _create_session_answer(client, *, candidate: str, role: dict, tag: str | None = None, rating: int | None = None):
    s_res = client.post("/api/sessions", json={
        "candidate": candidate, "role": role["name"], "role_id": role["id"], "consent": True,
    })
    s_res.raise_for_status()
    sid = s_res.json()["id"]
    phrase = "Use deterministic write-ahead logging with checksummed frames for crash recovery."
    a_res = client.post(f"/api/sessions/{sid}/answers", json={
        "question": "Describe your isolation strategy.", "answer": phrase,
        "references": [{"label": "Storage Guide", "text": phrase}], "planned_slot": 1,
    })
    a_res.raise_for_status()
    aid = a_res.json()["id"]
    client.patch(f"/api/sessions/{sid}/answers/{aid}", json={
        "disposition": "explained", "note": f"Reviewed note for {candidate}.",
    }).raise_for_status()
    if tag:
        client.post("/api/interviews/bulk/tag", json={"session_ids": [sid], "add": [tag], "remove": []}).raise_for_status()
    if rating is not None:
        client.put(f"/api/sessions/{sid}/scorecard", json={"items": [{
            "criterion_id": "crit-design", "criterion_label": "System Design",
            "weight": 50, "rating": rating, "rationale": "Verified isolation reasoning.",
        }]}).raise_for_status()
    return sid, aid


@pytest.mark.parametrize("viewport", VIEWPORTS, ids=lambda v: v[2])
def test_m22_roles_unique_aria_labels_and_calibration_retry(e2e_workspace, e2e_browser, viewport):
    width, height, _ = viewport
    with e2e_workspace.client() as client:
        r_alpha = _create_role_with_rubric(client, "Role Alpha")
        _create_role_with_rubric(client, "Role Beta")
        _create_session_answer(client, candidate="Ada Lovelace", role=r_alpha)

    ctx, page, collector = _open_page(e2e_browser, width, height)
    try:
        a_gate = _intercept_until_cleared(page, "**/api/roles/analytics", status=500, detail="Analytics unavailable", once=False)
        c_gate = _intercept_until_cleared(page, "**/api/roles/*/calibration", status=500, detail="Calibration failed")
        page.goto(e2e_workspace.base_url + "/roles/", wait_until="domcontentloaded")
        expect(page.get_by_role("heading", name="Role library")).to_be_visible()
        for role_name in ("Role Alpha", "Role Beta"):
            for prefix in ("Version history for", "Edit role", "Prepare interview for"):
                btn = page.get_by_role("button", name=f"{prefix} {role_name}", exact=True)
                expect(btn).to_be_visible()
                if width <= 480:
                    box = btn.bounding_box()
                    assert box is not None and box["height"] >= 44

        panel = page.get_by_label("Role calibration analytics")
        expect(panel.get_by_role("alert")).to_contain_text("Analytics unavailable")
        a_gate["clear"]()
        assert a_gate["hits"] >= 1
        _assert_expected_errors(collector, 500, page=page, gate=a_gate, exact_one=False)
        panel.get_by_role("alert").get_by_role("button", name="Retry", exact=True).click()
        expect(panel).to_contain_text("Active sessions")

        panel.get_by_role("button", name="Inspect calibration").first.click()
        expect(panel.get_by_role("alert")).to_contain_text("Calibration failed")
        assert c_gate["hits"] == 1
        _assert_expected_errors(collector, 500, page=page, gate=c_gate)
        panel.get_by_role("alert").get_by_role("button", name="Retry", exact=True).click()
        expect(panel.get_by_role("heading", name="Reviewer spread for Role Alpha")).to_be_visible()

        page.get_by_role("button", name="Edit role Role Alpha", exact=True).click()
        page.get_by_role("textbox", name="Description", exact=True).fill("Updated M22 description")
        page.get_by_label("Version change note").fill("Updated description")
        page.get_by_role("button", name="Save role", exact=True).click()
        expect(page.get_by_role("status").filter(has_text="Saved role Role Alpha (v2).")).to_be_visible()
        assert_no_horizontal_overflow(page)

        page.goto(f"{e2e_workspace.base_url}/roles/?role={r_alpha['id']}", wait_until="domcontentloaded")
        expect(page.get_by_role("heading", name="Role Alpha")).to_be_visible()
        assert_no_horizontal_overflow(page)
        collector.assert_clean()
    finally:
        ctx.close()


@pytest.mark.parametrize("viewport", VIEWPORTS, ids=lambda v: v[2])
def test_m22_review_draft_recovery_scorecard_and_brief_hardening(e2e_workspace, e2e_browser, viewport):
    width, height, _ = viewport
    with e2e_workspace.client() as client:
        role = _create_role_with_rubric(client, "Staff Storage")
        sid, aid = _create_session_answer(client, candidate="Grace Hopper", role=role)

    ctx, page, collector = _open_page(e2e_browser, width, height)
    try:
        page.goto(f"{e2e_workspace.base_url}/interviews/review/?id={sid}", wait_until="domcontentloaded")
        expect(page.get_by_role("heading", name="Describe your isolation strategy.")).to_be_visible()
        page.get_by_label("Interviewer note").fill("Recovered draft observation after reload")
        page.wait_for_function("k => Boolean(window.localStorage.getItem(k))", arg=f"ic_draft_v1:{sid}:review:{aid}")
        page.reload(wait_until="domcontentloaded")
        recovery = page.get_by_role("region", name="Local draft recovery")
        expect(recovery).to_be_visible()
        recovery.get_by_role("button", name="Restore local edits").click()
        expect(page.get_by_label("Interviewer note")).to_have_value("Recovered draft observation after reload")
        page.get_by_role("button", name="Save review").click()
        expect(page.get_by_text("Review saved")).to_be_visible()

        page.get_by_role("button", name="Rate System Design 4 of 5").click()
        page.get_by_label("Rationale for System Design").fill("Solid snapshot isolation analysis")
        page.get_by_role("button", name="Save scorecard").click()
        expect(page.get_by_text("Scorecard saved.")).to_be_visible()
        expect(page.get_by_test_id("scorecard-weighted-badge")).to_have_text("Score: 80.0%")
        page.get_by_label("Handoff note").fill("Ready for panel debrief")
        page.get_by_role("button", name="Add handoff note").click()
        expect(page.get_by_text("Handoff note added.")).to_be_visible()
        assert_no_horizontal_overflow(page)

        page.goto(f"{e2e_workspace.base_url}/interviews/brief/?id={sid}", wait_until="domcontentloaded")
        live_status = page.locator("aside.brief-options [role='status'][aria-live='polite']")
        expect(live_status).to_contain_text("Preview updated: 0 excerpts and 0 notes included.")
        excerpts_btn = page.get_by_role("button", name="Select all excerpts", exact=True)
        notes_btn = page.get_by_role("button", name="Select all notes", exact=True)
        excerpts_btn.click()
        expect(excerpts_btn).to_have_attribute("aria-pressed", "true")
        expect(live_status).to_contain_text("1 excerpt and 0 notes included.")
        notes_btn.focus()
        page.keyboard.press("Enter")
        expect(notes_btn).to_have_attribute("aria-pressed", "true")
        expect(live_status).to_contain_text("1 excerpt and 1 note included.")

        page.locator("aside.brief-options details > summary").focus()
        page.keyboard.press("Enter")
        expect(page.get_by_label("Answer excerpt for exchange 1")).to_be_checked()

        dl_gate = _intercept_until_cleared(page, "**/api/sessions/*/brief/download", status=500, detail="Export failed")
        page.get_by_role("button", name="Download brief").click()
        err_alert = page.locator("aside.brief-options .error[role='alert']")
        expect(err_alert).to_contain_text("Export failed")
        assert dl_gate["hits"] == 1
        _assert_expected_errors(collector, 500, page=page, gate=dl_gate)
        err_alert.get_by_role("button", name="Refresh preview").click()
        expect(live_status).to_contain_text("1 excerpt and 1 note included.")

        with page.expect_download() as dl:
            page.get_by_role("button", name="Download brief").click()
        assert "Recovered draft observation after reload" in dl.value.path().read_text(encoding="utf-8")
        expect(live_status).to_contain_text(f"Brief downloaded as review-brief-{sid}.md.")
        assert_no_horizontal_overflow(page)
        collector.assert_clean()
    finally:
        ctx.close()


@pytest.mark.parametrize("viewport", VIEWPORTS, ids=lambda v: v[2])
def test_m22_compare_empty_retry_dossier_and_data_cohort_export(e2e_workspace, e2e_browser, viewport):
    width, height, _ = viewport
    with e2e_workspace.client() as client:
        role = _create_role_with_rubric(client, "Platform Lead")
        _create_session_answer(client, candidate="Candidate One", role=role, tag="m22-cohort", rating=4)

    ctx, page, collector = _open_page(e2e_browser, width, height)
    try:
        feed_gate = _intercept_until_cleared(page, "**/api/interviews/feed*", status=500, detail="Archive feed error", once=False)
        page.goto(e2e_workspace.base_url + "/interviews/compare/", wait_until="domcontentloaded")
        alert = page.locator(".error[role='alert']")
        expect(alert).to_contain_text("Archive feed error")
        feed_gate["clear"]()
        assert feed_gate["hits"] >= 1
        _assert_expected_errors(collector, 500, page=page, gate=feed_gate, exact_one=False)
        alert.get_by_role("button", name="Retry", exact=True).click()
        expect(page.get_by_text("Only 1 interview found.")).to_be_visible()
        expect(page.get_by_role("link", name="New interview", exact=True)).to_have_attribute("href", "/interviews/new/")

        with e2e_workspace.client() as client:
            _create_session_answer(client, candidate="Candidate Two", role=role, tag="m22-cohort", rating=5)

        page.reload(wait_until="domcontentloaded")
        page.get_by_label("Candidate One").check()
        page.get_by_label("Candidate Two").check()
        page.get_by_role("button", name="Compare selected (2)").click()
        expect(page.get_by_role("heading", name="Candidates (2)")).to_be_visible()
        expect(page.get_by_role("heading", name="Question-slot matrix")).to_be_visible()
        assert_no_horizontal_overflow(page)

        page.goto(e2e_workspace.base_url + "/data/", wait_until="domcontentloaded")
        expect(page.get_by_role("region", name="Cohort filters")).to_be_visible()
        expect(page.get_by_role("heading", name="Cohort analytics and scorecard calibration")).to_be_visible()
        expect(page.get_by_text("2 scored sessions")).to_be_visible()
        expect(page.get_by_role("button", name="m22-cohort")).to_be_visible()
        with page.expect_download() as csv_dl:
            page.get_by_role("button", name="Export CSV").click()
        assert "Candidate One" in csv_dl.value.path().read_text(encoding="utf-8-sig")
        with page.expect_download() as json_dl:
            page.get_by_role("button", name="Export JSON").click()
        payload = json.loads(json_dl.value.path().read_text(encoding="utf-8"))
        assert payload["format"] == "interviewcheck.cohort_analytics" and payload["summary"]["session_count"] == 2
        assert_no_horizontal_overflow(page)
        collector.assert_clean()
    finally:
        ctx.close()


@pytest.mark.parametrize("viewport", VIEWPORTS, ids=lambda v: v[2])
def test_m22_empty_home_ctas_and_connections_account_503_retry(e2e_workspace, e2e_browser, viewport):
    width, height, _ = viewport
    _setup_admin(e2e_workspace)
    ctx, page, collector = _open_page(e2e_browser, width, height)
    try:
        _sign_in_browser(page, e2e_workspace.base_url)

        page.goto(e2e_workspace.base_url + "/", wait_until="domcontentloaded")
        expect(page.get_by_role("heading", name="Get started")).to_be_visible()
        expect(page.get_by_role("link", name="Open interviews", exact=True)).to_have_attribute("href", "/interviews/")
        expect(page.get_by_role("link", name="Manage roles", exact=True)).to_have_attribute("href", "/roles/")
        assert_no_horizontal_overflow(page)

        conn_gate = _intercept_until_cleared(page, "**/api/integrations/status", status=503, detail="Connections unavailable", once=False)
        page.goto(e2e_workspace.base_url + "/connections/", wait_until="domcontentloaded")
        conn_alert = page.locator(".error[role='alert']")
        expect(conn_alert).to_contain_text("Connections unavailable")
        conn_gate["clear"]()
        assert conn_gate["hits"] >= 1
        _assert_expected_errors(collector, 503, page=page, gate=conn_gate, exact_one=False)
        conn_alert.get_by_role("button", name="Retry", exact=True).click()
        expect(page.get_by_label("Import calendar events")).to_be_visible()
        expect(conn_alert).to_have_count(0)
        assert_no_horizontal_overflow(page)

        acct_gate = _intercept_until_cleared(page, "**/api/integrations/account", status=503, detail="Account gateway down", once=False)
        page.goto(e2e_workspace.base_url + "/account/", wait_until="domcontentloaded")
        acct_alert = page.locator(".error[role='alert']")
        expect(acct_alert).to_contain_text("Account gateway down")
        acct_gate["clear"]()
        assert acct_gate["hits"] >= 1
        _assert_expected_errors(collector, 503, page=page, gate=acct_gate, exact_one=False)
        acct_alert.get_by_role("button", name="Retry", exact=True).click()
        expect(page.get_by_text(f"{ADMIN_EMAIL} · Access active")).to_be_visible()
        assert_no_horizontal_overflow(page)
        collector.assert_clean()
    finally:
        ctx.close()


@pytest.mark.parametrize("viewport", VIEWPORTS, ids=lambda v: v[2])
def test_m22_admin_8_tabs_keyboard_traversal_desktop_and_mobile(e2e_workspace, e2e_browser, viewport):
    width, height, _ = viewport
    _setup_admin(e2e_workspace)
    with e2e_workspace.client() as client:
        login_user(client, email=ADMIN_EMAIL, password=ADMIN_PASS)
        client.post("/api/admin/models", json={
            "slug": "m22-eval-model", "display_name": "M22 Eval Model",
            "provider": "openai", "capability": "reference", "model_id": "gpt-4o", "apiKey": "sk-m22-1111",
        }).raise_for_status()

    ctx, page, collector = _open_page(e2e_browser, width, height)
    try:
        _sign_in_browser(page, e2e_workspace.base_url)
        page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
        expect(page.get_by_role("heading", name="Model administration")).to_be_visible()

        tabs = page.get_by_role("tablist", name="Admin sections").get_by_role("tab")
        expect(tabs).to_have_count(len(ADMIN_TABS))
        for idx, label in enumerate(ADMIN_TABS):
            expect(tabs.nth(idx)).to_have_text(label)

        tabs.nth(0).focus()
        for idx in range(1, len(ADMIN_TABS)):
            page.keyboard.press("ArrowRight")
            current = tabs.nth(idx)
            expect(current).to_be_focused()
            expect(current).to_have_attribute("aria-selected", "true")
            expect(current).to_have_attribute("tabindex", "0")
            panel_id = current.get_attribute("aria-controls")
            assert panel_id
            expect(page.locator(f"#{panel_id}[role='tabpanel']")).to_be_visible()
            assert_no_horizontal_overflow(page)

        page.keyboard.press("Home")
        expect(tabs.nth(0)).to_be_focused()
        expect(page.locator("#panel-models[role='tabpanel']")).to_be_visible()
        page.keyboard.press("End")
        expect(tabs.nth(len(ADMIN_TABS) - 1)).to_be_focused()
        expect(page.locator("#panel-compliance[role='tabpanel']")).to_be_visible()
        assert_no_horizontal_overflow(page)
        collector.assert_clean()
    finally:
        ctx.close()
