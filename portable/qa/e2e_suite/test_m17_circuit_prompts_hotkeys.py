"""Opaque-box Playwright E2E tests for M17 circuit breakers, SLA, prompt templates, and review hotkeys."""
from fastapi import HTTPException
from playwright.sync_api import expect
import pytest

from api import model_telemetry, scoring_hooks, store
from e2e_suite.harness import ConsoleErrorCollector, assert_no_horizontal_overflow, login_user, signup_user

ADMIN_EMAIL = "admin-m17@example.test"
MEMBER_EMAIL = "member-m17@example.test"
BOOTSTRAP_SECRET = "m17-bootstrap-secret-1234"
ADMIN_PASS = "Synthetic-M17-Admin-Pass-1"
MEMBER_PASS = "Synthetic-M17-Member-Pass-1"


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
    expect(page.get_by_role("heading", name="Model administration")).to_be_visible()


def _create_model_api(
    client, *, slug: str, display_name: str, provider: str = "openai", capability: str = "judge",
    model_id: str = "gpt-4o", api_key: str = "sk-m17-api-1234", is_default: bool = False, parameters: dict | None = None,
) -> dict:
    res = client.post("/api/admin/models", json={
        "slug": slug, "display_name": display_name, "provider": provider, "capability": capability,
        "model_id": model_id, "apiKey": api_key, "enabled": True, "is_default": is_default,
        "parameters": parameters or {},
    })
    res.raise_for_status()
    return res.json()["model"]


def _create_session(client, candidate: str) -> str:
    res = client.post("/api/sessions", json={
        "candidate": candidate, "role": "Systems engineer",
        "policy": "Official reference material is allowed only when declared.", "consent": True,
    })
    res.raise_for_status()
    return res.json()["id"]


def _create_answer(client, sid: str, question: str, phrase: str, *, comparable: bool = True) -> dict:
    res = client.post(f"/api/sessions/{sid}/answers", json={
        "question": question, "answer": phrase, "references": [{"label": "Guide", "text": phrase}] if comparable else [],
    })
    res.raise_for_status()
    return res.json()


def _assert_no_secrets(page, *secrets: str) -> None:
    html = page.content()
    for secret in (*secrets, "e2e-deterministic-test-secret-key"):
        assert secret not in html


def test_m17_admin_sla_circuit_breaker_and_policy_controls(e2e_workspace, desktop_page, monkeypatch):
    _setup_auth(e2e_workspace, include_member=True)
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        primary = _create_model_api(
            admin_api, slug="m17-primary", display_name="Circuit Primary", provider="openai", capability="judge",
            model_id="gpt-4o", api_key="sk-m17-prim-secret-1111", is_default=True, parameters={"fallback_priority": 10},
        )
        _create_model_api(
            admin_api, slug="m17-backup", display_name="Circuit Backup", provider="anthropic", capability="judge",
            model_id="claude-sonnet-4-6", api_key="sk-m17-back-secret-2222", parameters={"fallback_priority": 20},
        )
        sla_model = _create_model_api(
            admin_api, slug="m17-sla-metrics", display_name="SLA Metrics Model", provider="openai",
            capability="reference", model_id="gpt-4o-mini", api_key="sk-m17-sla-secret-3333", is_default=True,
        )

    with e2e_workspace.client() as anon:
        assert anon.get("/api/admin/models/sla").status_code == 401
        assert anon.post(f"/api/admin/models/{primary['id']}/circuit/reset").status_code == 401
        assert anon.patch(f"/api/admin/models/{primary['id']}/circuit", json={"cooldown_seconds": 30}).status_code == 401
        assert anon.get("/api/admin/prompts").status_code == 401
    with e2e_workspace.client() as member_api:
        login_user(member_api, email=MEMBER_EMAIL, password=MEMBER_PASS)
        assert member_api.get("/api/admin/models/sla").status_code == 403
        assert member_api.post(f"/api/admin/models/{primary['id']}/circuit/reset").status_code == 403
        assert member_api.get("/api/admin/prompts").status_code == 403
    with e2e_workspace.client() as no_csrf:
        login_user(no_csrf, email=ADMIN_EMAIL, password=ADMIN_PASS)
        no_csrf.headers.pop("X-InterviewCheck", None)
        assert no_csrf.post(f"/api/admin/models/{primary['id']}/circuit/reset").status_code == 403
        assert no_csrf.patch(f"/api/admin/models/{primary['id']}/circuit", json={"cooldown_seconds": 30}).status_code == 403

    called_urls: list[str] = []

    async def failover_fetch(name, method, url, **kwargs):
        called_urls.append(url)
        if "openai.com" in url:
            raise HTTPException(503, "Upstream timeout sk-m17-leak-token-9999")
        return {"stop_reason": "end_turn", "content": [{"type": "text", "text": '{"likelihood": 45, "confidence": "medium"}'}]}

    monkeypatch.setattr(scoring_hooks, "fetch_json", failover_fetch)
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        for _ in range(3):
            res = admin_api.post("/api/scoring/judge", json={"question": "Explain caches", "answer": "LRU stores keys"})
            assert res.status_code == 200 and res.json()["provider"] == "anthropic"
        called_urls.clear()
        res_open = admin_api.post("/api/scoring/judge", json={"question": "Explain caches", "answer": "LRU stores keys"})
        assert res_open.status_code == 200 and res_open.json()["provider"] == "anthropic"
        assert called_urls == ["https://api.anthropic.com/v1/messages"]

    with store.connection(write=True) as db:
        for idx in range(1, 21):
            ok = idx <= 17
            model_telemetry.record_check(
                db, sla_model["id"], source="live", ok=ok, http_status=200 if ok else 503,
                latency_ms=idx * 100, error=None if ok else "Transient error", checked_at=f"2026-11-19T01:00:{idx:02d}Z",
            )

    page, collector = desktop_page
    _sign_in_admin(page, e2e_workspace.base_url)
    page.get_by_role("tab", name="Prompts & SLA").click()
    panel = page.locator("#panel-prompts")
    expect(panel.get_by_role("heading", name="Model SLA & circuit breakers")).to_be_visible()

    summary_cards = panel.locator("section[aria-label='Model SLA and circuit breakers']")
    expect(summary_cards).to_contain_text("Open / half-open circuits1")
    expect(summary_cards).to_contain_text("SLA breaches1")

    primary_row = panel.locator("tbody tr", has_text="Circuit Primary")
    expect(primary_row).to_contain_text("Open")
    expect(primary_row).to_contain_text("Streak 3/3 (60s)")
    expect(primary_row).to_contain_text("Breach")
    assert "sk-m17-leak-token-9999" not in primary_row.inner_text()

    sla_row = panel.locator("tbody tr", has_text="SLA Metrics Model")
    expect(sla_row).to_contain_text("1000 ms")
    expect(sla_row).to_contain_text("1900 ms")
    expect(sla_row).to_contain_text("2000 ms")
    expect(sla_row).to_contain_text("15.0%")
    expect(sla_row).to_contain_text("Within SLA")

    sla_row.get_by_role("button", name="Edit policy").click()
    policy_form = panel.locator("form", has_text="Edit circuit & SLA policy: SLA Metrics Model")
    expect(policy_form).to_be_visible()
    policy_form.get_by_label("Failure threshold (1 to 20)").fill("2")
    policy_form.get_by_label("Cooldown seconds (5 to 3600)").fill("30")
    policy_form.get_by_label("SLA target ms (100 to 60000)").fill("1500")
    policy_form.get_by_role("button", name="Save policy").click()
    policy_msg = "Updated circuit policy and SLA target for SLA Metrics Model."
    expect(panel.get_by_role("status").filter(has_text=policy_msg)).to_contain_text(policy_msg)
    expect(sla_row).to_contain_text("Breach")
    expect(sla_row).to_contain_text("Target 1500 ms")
    expect(sla_row).to_contain_text("Streak 0/2 (30s)")

    primary_row.get_by_role("button", name="Reset circuit").click()
    reset_msg = "Circuit reset to closed for Circuit Primary."
    expect(panel.get_by_role("status").filter(has_text=reset_msg)).to_contain_text(reset_msg)
    expect(primary_row).to_contain_text("Closed")
    expect(primary_row).to_contain_text("Streak 0/3 (60s)")

    page.reload(wait_until="domcontentloaded")
    page.get_by_role("tab", name="Prompts & SLA").click()
    expect(panel.locator("tbody tr", has_text="SLA Metrics Model")).to_contain_text("Target 1500 ms")
    expect(panel.locator("tbody tr", has_text="Circuit Primary")).to_contain_text("Closed")
    _assert_no_secrets(page, "sk-m17-prim-secret-1111", "sk-m17-back-secret-2222", "sk-m17-sla-secret-3333", "sk-m17-leak-token-9999")
    collector.assert_clean()


def test_m17_prompt_template_edit_diff_conflict_and_rollback(e2e_workspace, desktop_page, monkeypatch):
    _setup_auth(e2e_workspace)
    captured_instructions: list[str] = []
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        _create_model_api(
            admin_api, slug="m17-prompt-judge", display_name="Prompt Judge", provider="openai",
            capability="judge", model_id="gpt-4o", api_key="sk-m17-prompt-3333", is_default=True,
        )

    async def capture_judge_fetch(name, method, url, **kwargs):
        messages = (kwargs.get("json") or {}).get("messages") or []
        captured_instructions.append(str(messages[0].get("content") if messages else ""))
        return {"choices": [{"finish_reason": "stop", "message": {"content": '{"likelihood": 60, "confidence": "high", "evidence": ["ok"], "follow_up_questions": []}'}}]}

    monkeypatch.setattr(scoring_hooks, "fetch_json", capture_judge_fetch)
    page, collector = desktop_page
    _sign_in_admin(page, e2e_workspace.base_url)
    page.get_by_role("tab", name="Prompts & SLA").click()
    panel = page.locator("#panel-prompts")
    prompt_section = panel.locator("section[aria-label='Prompt templates']")
    expect(prompt_section.get_by_role("heading", name="Prompt template governance")).to_be_visible()

    prompt_section.get_by_label("Prompt slot").select_option("judge_rubric")
    expect(prompt_section.get_by_text("v1 active", exact=True)).to_be_visible()
    original_system = prompt_section.get_by_label("System prompt").input_value()

    v2_system = "Evaluate candidate responses strictly for technical evidence and clarity."
    v2_rule = "Return strict JSON with likelihood, confidence, evidence, and follow_up_questions."
    prompt_section.get_by_label("System prompt").fill(v2_system)
    prompt_section.get_by_label("Output rule").fill(v2_rule)
    prompt_section.get_by_label("Change note (optional)").fill("Tightened judge rubric v2")
    prompt_section.get_by_role("button", name="Save new version").click()

    save_msg = "Saved AI judge rubric as version 2."
    expect(panel.get_by_role("status").filter(has_text=save_msg)).to_contain_text(save_msg)
    expect(prompt_section.get_by_text("v2 active", exact=True)).to_be_visible()
    expect(prompt_section.get_by_text("2 versions", exact=True)).to_be_visible()

    v2_card = prompt_section.locator("article", has_text="v2").first
    expect(v2_card).to_contain_text("Active")
    expect(v2_card.locator("pre")).to_contain_text(f"+{v2_system}")
    prompt_section.get_by_role("button", name="Diff vs active").click()
    expect(prompt_section.locator("article", has_text="v1").first.locator("pre")).to_contain_text(f"+{v2_system}")
    prompt_section.get_by_role("button", name="Diff vs previous").click()

    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        judge_res = admin_api.post("/api/scoring/judge", json={"question": "What is WAL?", "answer": "Write-ahead log."})
        assert judge_res.status_code == 200
        assert any(v2_system in item and v2_rule in item for item in captured_instructions)
        assert admin_api.put("/api/admin/prompts/judge_rubric", json={
            "system_prompt": "Concurrent operator update version three prompt text.",
            "output_rule": "Return JSON output only for version three.",
            "change_note": "Concurrent admin edit", "expected_version": 2,
        }).status_code == 200

    prompt_section.get_by_label("System prompt").fill("Stale browser edit attempting to overwrite version two.")
    prompt_section.get_by_role("button", name="Save new version").click()
    conflict_alert = prompt_section.get_by_role("alert")
    expect(conflict_alert).to_contain_text("Version conflict (409):")
    assert not collector.page_errors and not collector.server_errors
    assert len(collector.console_errors) == 1 and "409" in collector.console_errors[0]
    collector.reset()

    conflict_alert.get_by_role("button", name="Reload latest version").click()
    expect(conflict_alert).to_have_count(0)
    expect(prompt_section.get_by_text("v3 active", exact=True)).to_be_visible()
    expect(prompt_section.get_by_label("System prompt")).to_have_value("Concurrent operator update version three prompt text.")

    prompt_section.get_by_role("button", name="Rollback to v1").click()
    rollback_msg = "Rolled back AI judge rubric to v1 (new v4)."
    expect(panel.get_by_role("status").filter(has_text=rollback_msg)).to_contain_text(rollback_msg)
    expect(prompt_section.get_by_text("v4 active", exact=True)).to_be_visible()
    expect(prompt_section.get_by_label("System prompt")).to_have_value(original_system)

    page.reload(wait_until="domcontentloaded")
    page.get_by_role("tab", name="Prompts & SLA").click()
    prompt_section.get_by_label("Prompt slot").select_option("judge_rubric")
    expect(prompt_section.get_by_text("v4 active", exact=True)).to_be_visible()
    _assert_no_secrets(page, "sk-m17-prompt-3333")
    collector.assert_clean()


def test_m17_review_workbench_hotkeys_focus_guard_aria_and_help_modal(e2e_workspace, desktop_page):
    phrase = "Measure three independent baselines before calibrating the distributed telemetry collector."
    with e2e_workspace.client() as c:
        sid = _create_session(c, "Hotkey Candidate")
        a1 = _create_answer(c, sid, "Q1: First matched question?", phrase, comparable=True)
        _create_answer(c, sid, "Q2: Second clear question?", "Plain answer without matches.", comparable=False)
        a3 = _create_answer(c, sid, "Q3: Third matched question?", phrase, comparable=True)

    page, collector = desktop_page
    page.goto(e2e_workspace.base_url + f"/interviews/review/?id={sid}&answer={a1['id']}", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Q1: First matched question?", exact=True)).to_be_visible()

    live_status = page.locator('p[role="status"][aria-live="polite"]')
    page.keyboard.press("j")
    expect(page.get_by_role("heading", name="Q2: Second clear question?", exact=True)).to_be_visible()
    expect(live_status).to_contain_text("Question 2 of 3: Q2: Second clear question?")

    page.keyboard.press("k")
    expect(page.get_by_role("heading", name="Q1: First matched question?", exact=True)).to_be_visible()
    expect(live_status).to_contain_text("Question 1 of 3: Q1: First matched question?")

    page.keyboard.press("n")
    expect(page.get_by_role("heading", name="Q3: Third matched question?", exact=True)).to_be_visible()
    expect(live_status).to_contain_text("Next pending match: Question 3 of 3: Q3: Third matched question?")

    outcome = page.get_by_label("Review outcome")
    page.keyboard.press("e")
    expect(outcome).to_have_value("explained")
    expect(live_status).to_contain_text("Review outcome set to Explained. Save review to persist.")
    with e2e_workspace.client() as c:
        assert c.get(f"/api/sessions/{sid}/answers/{a3['id']}").json()["disposition"] == "pending"

    page.keyboard.press("u")
    expect(outcome).to_have_value("unresolved")
    expect(live_status).to_contain_text("Review outcome set to Unresolved. Save review to persist.")

    page.keyboard.press("f")
    note = page.get_by_label("Interviewer note")
    expect(note).to_be_focused()
    expect(live_status).to_contain_text("Focused interviewer note.")

    page.keyboard.type("jkneuf focus guard note")
    expect(note).to_have_value("jkneuf focus guard note")
    expect(page.get_by_role("heading", name="Q3: Third matched question?", exact=True)).to_be_visible()
    expect(outcome).to_have_value("unresolved")

    outcome.focus()
    page.keyboard.press("j")
    expect(page.get_by_role("heading", name="Q3: Third matched question?", exact=True)).to_be_visible()

    page.get_by_role("button", name="Save review", exact=True).click()
    expect(page.get_by_text("Review saved", exact=True)).to_be_visible()
    with e2e_workspace.client() as c:
        saved_a3 = c.get(f"/api/sessions/{sid}/answers/{a3['id']}").json()
        assert saved_a3["disposition"] == "unresolved" and saved_a3["note"] == "jkneuf focus guard note"

    page.get_by_role("heading", name="Q3: Third matched question?", exact=True).click()
    page.keyboard.press("?")
    shortcut_dialog = page.locator("dialog.shortcut-dialog")
    expect(shortcut_dialog).to_be_visible()
    for desc in (
        "Select the next interview exchange", "Select the previous interview exchange",
        "Jump to the next pending match", "Set review outcome to Explained",
        "Set review outcome to Unresolved", "Focus the interviewer note field",
    ):
        expect(shortcut_dialog).to_contain_text(desc)

    page.keyboard.press("k")
    expect(shortcut_dialog).to_be_visible()
    expect(page.get_by_role("heading", name="Q3: Third matched question?", exact=True)).to_be_visible()
    page.keyboard.press("Escape")
    expect(shortcut_dialog).to_have_count(0)
    collector.assert_clean()


@pytest.mark.parametrize("viewport", [(1440, 900, "desktop-1440"), (390, 844, "mobile-390")], ids=lambda v: v[2])
def test_m17_responsive_prompts_sla_and_review_hotkeys_viewports(e2e_workspace, e2e_browser, viewport):
    width, height, _ = viewport
    _setup_auth(e2e_workspace)
    phrase = "Measure three independent baselines before calibrating the distributed telemetry collector."
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        m = _create_model_api(admin_api, slug="m17-resp-model", display_name="Responsive SLA Model", api_key="sk-m17-resp-4444", is_default=True)
        sid = _create_session(admin_api, "Responsive Hotkey Candidate")
        a1 = _create_answer(admin_api, sid, "Responsive Q1?", phrase, comparable=True)
        _create_answer(admin_api, sid, "Responsive Q2?", phrase, comparable=True)

    with store.connection(write=True) as db:
        model_telemetry.record_check(
            db, m["id"], source="live", ok=True, http_status=200, latency_ms=145, error=None, checked_at="2026-11-19T02:00:00Z",
        )

    mobile = width <= 480
    ctx = e2e_browser.new_context(viewport={"width": width, "height": height}, reduced_motion="reduce", is_mobile=mobile, has_touch=mobile)
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    try:
        _sign_in_admin(page, e2e_workspace.base_url)
        page.get_by_role("tab", name="Prompts & SLA").click()
        panel = page.locator("#panel-prompts")
        expect(panel.get_by_role("heading", name="Model SLA & circuit breakers")).to_be_visible()
        expect(panel.get_by_role("heading", name="Prompt template governance")).to_be_visible()
        assert_no_horizontal_overflow(page)

        page.goto(e2e_workspace.base_url + f"/interviews/review/?id={sid}&answer={a1['id']}", wait_until="domcontentloaded")
        expect(page.get_by_role("heading", name="Responsive Q1?", exact=True)).to_be_visible()
        page.keyboard.press("j")
        expect(page.get_by_role("heading", name="Responsive Q2?", exact=True)).to_be_visible()
        page.keyboard.press("e")
        expect(page.get_by_label("Review outcome")).to_have_value("explained")
        assert_no_horizontal_overflow(page)

        page.get_by_role("button", name="Discard review changes").click()
        page.keyboard.press("k")
        expect(page.get_by_role("heading", name="Responsive Q1?", exact=True)).to_be_visible()
        live_status = page.locator('p[role="status"][aria-live="polite"]')
        expect(live_status).to_have_text("Question 1 of 2: Responsive Q1?")
        expect(live_status).not_to_contain_text("Save or discard changes before switching exchanges.")
        page.get_by_role("heading", name="Responsive Q1?", exact=True).click()
        page.keyboard.press("?")
        shortcut_dialog = page.locator("dialog.shortcut-dialog")
        expect(shortcut_dialog).to_be_visible()
        assert_no_horizontal_overflow(page)
        page.keyboard.press("Escape")
        expect(shortcut_dialog).to_have_count(0)
        _assert_no_secrets(page, "sk-m17-resp-4444")
        collector.assert_clean()
    finally:
        ctx.close()
