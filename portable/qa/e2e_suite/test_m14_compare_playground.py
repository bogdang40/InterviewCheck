"""Opaque-box Playwright E2E tests for M14 candidate comparison and admin model playground."""
import json
from uuid import uuid4

from fastapi import HTTPException
from playwright.sync_api import expect
import pytest

from api import provider_http, store
from api.exports import PRINT_STYLE_HASH
from e2e_suite.harness import ConsoleErrorCollector, assert_no_horizontal_overflow, login_user, signup_user

ADMIN_EMAIL, MEMBER_EMAIL = "admin-m14@example.test", "member-m14@example.test"
BOOTSTRAP_SECRET = "m14-bootstrap-secret-1234"
ADMIN_PASS, MEMBER_PASS = "Synthetic-M14-Admin-Pass-1", "Synthetic-M14-Member-Pass-1"
OA_SECRET, ANT_SECRET, DG_SECRET = "sk-m14-oa-secret-1111", "sk-m14-ant-secret-2222", "sk-m14-dg-secret-3333"
PASSAGE = "The oldest active snapshot pins tombstones across every replica until compaction completes."


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


def _seed_rubric_role(client, name: str = "Staff Consensus Engineer") -> dict:
    res = client.post("/api/roles", json={
        "name": name, "description": "Distributed state and durability",
        "questions": ["Explain Raft safety.", "Explain WAL fsync."], "policy": "No external assistance.",
        "permitted_sources": [], "rubric": [{"id": "crit-safety", "criterion": "Consensus safety",
            "weight": 50, "expected_signals": ["Mentions quorum intersection"], "red_flags": ["Allows dual leaders"]}],
    })
    res.raise_for_status()
    return res.json()


def _seed_session(client, *, candidate: str, role: dict) -> str:
    res = client.post("/api/sessions", json={
        "candidate": candidate, "role": role["name"], "role_id": role["id"], "policy": role["policy"], "consent": True,
    })
    res.raise_for_status()
    return res.json()["id"]


def _add_answer(client, sid: str, *, question: str, answer: str, slot: int | None = None, match: bool = False) -> str:
    payload: dict = {"question": question, "answer": answer, "references": [{"label": "Ref", "text": PASSAGE}] if match else []}
    if slot is not None:
        payload["planned_slot"] = slot
    res = client.post(f"/api/sessions/{sid}/answers", json=payload)
    res.raise_for_status()
    return res.json()["id"]


def _create_model(client, *, slug: str, name: str, provider: str, capability: str, model_id: str, secret: str) -> dict:
    res = client.post("/api/admin/models", json={
        "slug": slug, "display_name": name, "provider": provider, "capability": capability,
        "model_id": model_id, "apiKey": secret, "enabled": True, "is_default": capability == "reference",
        "parameters": {"input_cost_per_1m_usd": 2.0, "output_cost_per_1m_usd": 8.0},
    })
    res.raise_for_status()
    return res.json()["model"]


def test_m14_compare_entry_picker_validation_and_empty_single_handling(e2e_workspace, desktop_page):
    with e2e_workspace.client() as c:
        role = _seed_rubric_role(c)
        s1, s2 = _seed_session(c, candidate="Ada Lovelace", role=role), _seed_session(c, candidate="Grace Hopper", role=role)
        s_trash = _seed_session(c, candidate="Trashed Candidate", role=role)
        _add_answer(c, s1, question="Explain Raft safety.", answer=PASSAGE, slot=1, match=True)
        _add_answer(c, s2, question="Explain Raft safety.", answer="Quorum prevents split brain.", slot=1)
        c.post(f"/api/sessions/{s_trash}/trash").raise_for_status()

    page, collector = desktop_page
    page.goto(e2e_workspace.base_url + "/interviews/", wait_until="domcontentloaded")
    compare_link = page.get_by_role("link", name="Compare")
    expect(compare_link).to_have_attribute("href", "/interviews/compare/")
    page.get_by_label("Select Ada Lovelace").check()
    page.get_by_label("Select Grace Hopper").check()
    href = compare_link.get_attribute("href") or ""
    assert s1 in href and s2 in href and "/interviews/compare/?ids=" in href

    page.goto(e2e_workspace.base_url + "/interviews/compare/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Candidate comparison")).to_be_visible()
    expect(page.get_by_text("Select 2 to 6 interviews to compare candidates side by side.")).to_be_visible()
    expect(page.get_by_role("button", name="Compare selected (0)")).to_be_disabled()

    page.goto(f"{e2e_workspace.base_url}/interviews/compare/?ids=not-a-uuid,{s1}", wait_until="domcontentloaded")
    expect(page.get_by_text("Ignored 1 invalid interview ID(s).")).to_be_visible()
    expect(page.get_by_text("Choose 2 to 6 interviews (1 of 6 selected).")).to_be_visible()
    expect(page.get_by_role("button", name="Compare selected (1)")).to_be_disabled()

    page.get_by_label("Filter interviews").fill("Grace")
    expect(page.locator("ul li label", has_text="Grace Hopper")).to_be_visible()
    expect(page.locator("ul li label", has_text="Trashed Candidate")).to_have_count(0)
    page.locator("ul li label", has_text="Grace Hopper").locator("input[type='checkbox']").check()
    page.get_by_role("button", name="Compare selected (2)").click()
    expect(page.get_by_role("heading", name="Candidates (2)")).to_be_visible()
    expect(page.get_by_role("heading", name="Question-slot matrix")).to_be_visible()
    collector.assert_clean()

    page.goto(f"{e2e_workspace.base_url}/interviews/compare/?ids={s1},{s_trash}", wait_until="domcontentloaded")
    expect(page.locator("main [role='alert']")).to_be_visible()
    expect(page.get_by_role("button", name="Retry comparison")).to_be_visible()
    assert not collector.page_errors and not collector.server_errors
    assert len(collector.console_errors) == 1 and "404" in collector.console_errors[0]
    collector.reset()


def test_m14_compare_matrix_rubric_gating_markdown_and_print_dossier(e2e_workspace, desktop_page):
    long_answer, note_secret = "EXCERPT_TOKEN " + ("x" * 280), "CONFIDENTIAL_NOTE_XYZ"
    with e2e_workspace.client() as c:
        role = _seed_rubric_role(c)
        s1 = _seed_session(c, candidate="Ada Lovelace", role=role)
        s2 = _seed_session(c, candidate='<script>alert(1)</script> | md', role=role)
        s3 = _seed_session(c, candidate="Lin Archived", role=role)
        a11 = _add_answer(c, s1, question="Explain Raft safety.", answer=long_answer, slot=1, match=True)
        _add_answer(c, s1, question="Explain WAL fsync.", answer="Fsync before ack.", slot=2)
        _add_answer(c, s1, question="Follow up?", answer="Monitor commit lag.")
        a21 = _add_answer(c, s2, question="Explain Raft safety.", answer=PASSAGE, slot=1, match=True)
        c.patch(f"/api/sessions/{s1}/answers/{a11}", json={"disposition": "explained", "note": note_secret}).raise_for_status()
        c.patch(f"/api/sessions/{s2}/answers/{a21}", json={"disposition": "unresolved", "note": "Verify quorum"}).raise_for_status()
        c.post(f"/api/sessions/{s2}/finish").raise_for_status()
    with store.connection(write=True) as db:
        db.execute("UPDATE sessions SET consent=0 WHERE id=?", (s3,))

    page, collector = desktop_page
    page.goto(f"{e2e_workspace.base_url}/interviews/compare/?ids={s1},{s2},{s3}", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Candidates (3)")).to_be_visible()
    expect(page.get_by_role("heading", name="Shared role rubric criteria")).to_be_visible()
    for text in ("Consensus safety", "Weight 50", "Mentions quorum intersection", "Allows dual leaders"):
        expect(page.get_by_text(text)).to_be_visible()

    matrix = page.get_by_role("table")
    expect(matrix.get_by_role("rowheader", name="Question 1 Explain Raft safety.")).to_be_visible()
    expect(matrix.get_by_role("rowheader", name="Question 2 Explain WAL fsync.")).to_be_visible()
    expect(matrix.get_by_role("rowheader", name="Unslotted")).to_be_visible()
    expect(matrix.get_by_text("No response recorded").first).to_be_visible()
    expect(matrix.get_by_role("link", name="Open answer").first).to_have_attribute("href", f"/interviews/review/?id={s1}&answer={a11}")

    assert "EXCERPT_TOKEN" not in page.content() and note_secret not in page.content()
    page.get_by_label("Include answer excerpts").check()
    page.get_by_label("Include interviewer notes").check()
    expect(matrix.get_by_text("EXCERPT_TOKEN")).to_be_visible()
    expect(matrix.get_by_text(note_secret)).to_be_visible()

    with page.expect_download() as dl_info:
        page.get_by_role("button", name="Download Markdown dossier").click()
    dl = dl_info.value
    assert dl.suggested_filename == "candidate-comparison.md"
    expect(page.get_by_text("Download started for candidate-comparison.md.")).to_be_visible()
    md_text = dl.path().read_text(encoding="utf-8")
    assert "Consensus safety" in md_text and note_secret in md_text
    assert "\\<script\\>alert\\(1\\)\\</script\\>" in md_text and "\\| md" in md_text

    print_href = page.get_by_role("link", name="Print or save PDF").get_attribute("href") or ""
    assert "include_excerpts=true" in print_href and "include_notes=true" in print_href
    print_res = page.request.get(e2e_workspace.base_url + print_href)
    assert print_res.status == 200 and "text/html" in print_res.headers.get("content-type", "")
    csp = print_res.headers.get("content-security-policy", "")
    assert "script-src 'self'" in csp and f"'{PRINT_STYLE_HASH}'" in csp and "'unsafe-inline'" not in csp
    html_text = print_res.text()
    assert '<script src="/api/exports/print.js" defer></script>' in html_text
    assert "onclick=" not in html_text and "&lt;script&gt;alert(1)&lt;/script&gt;" in html_text
    collector.assert_clean()


def test_compare_changed_plans_and_additional_answers(e2e_workspace, desktop_page, tmp_path):
    common, old, revised = "How do you measure lag?", "How do you check logs?", "How do you check metrics?"
    payload = {"name": "Release engineer", "policy": "Notes permitted.", "questions": [common, old]}
    with e2e_workspace.client() as c:
        role = c.post("/api/roles", json=payload).raise_for_status().json()
        ada = _seed_session(c, candidate="Ada", role=role)
        c.put(f"/api/roles/{role['id']}", json={**payload, "questions": [common, revised]}).raise_for_status()
        grace = _seed_session(c, candidate="Grace", role=role)
        c.put(f"/api/roles/{role['id']}", json={**payload, "questions": [common]}).raise_for_status()
        lin = _seed_session(c, candidate="Lin", role=role)
        _add_answer(c, ada, question="Show the evidence.", answer="I used a trace.", slot=2)
        extra = _add_answer(c, ada, question="What else did you inspect?", answer="The logs.", slot=2)
        _add_answer(c, lin, question="Walk through your notes.", answer="I compared offsets.")
        _add_answer(c, grace, question="What did you change?", answer="The metric.")

    page, collector = desktop_page
    page.goto(f"{e2e_workspace.base_url}/interviews/compare/?ids={ada},{grace},{lin}")
    table = page.get_by_role("table")
    expect(table.get_by_role("rowheader", name="Question 1 " + common)).to_be_visible()
    row = table.get_by_role("row").filter(has=page.get_by_role("rowheader", name="Question 2", exact=True))
    old_cell, new_cell, absent = (row.get_by_role("cell").nth(i) for i in range(3))
    expect(old_cell).to_contain_text(old)
    expect(old_cell).to_contain_text("Show the evidence.")
    expect(new_cell).to_contain_text(revised)
    expect(new_cell).to_contain_text("No response recorded")
    expect(absent).to_contain_text("Not in this interview plan.")
    unplanned = table.get_by_role("row").filter(has=page.get_by_role("rowheader", name="Unslotted"))
    expect(unplanned).to_have_count(2)
    expect(unplanned.first).to_contain_text("Walk through your notes.")
    expect(unplanned.first).not_to_contain_text("What did you change?")

    page.set_viewport_size({"width": 320, "height": 800})
    expect(old_cell.get_by_text("Ada", exact=True)).to_be_visible()
    expect(new_cell.get_by_text("Grace", exact=True)).to_be_visible()
    expect(absent.get_by_text("Lin", exact=True)).to_be_visible()
    assert_no_horizontal_overflow(page)
    row.scroll_into_view_if_needed()
    page.screenshot(path=tmp_path / "comparison-saved-plans.png")
    follow = table.get_by_role("row").filter(has=page.get_by_role("rowheader", name="Question 2 (additional answer)"))
    link = follow.get_by_role("link", name="Open answer")
    expect(link).to_have_attribute("href", f"/interviews/review/?id={ada}&answer={extra}")
    link.focus()
    page.keyboard.press("Enter")
    expect(page).to_have_url(f"{e2e_workspace.base_url}/interviews/review/?id={ada}&answer={extra}")
    collector.assert_clean()


def test_m14_playground_auth_presets_run_schema_errors_and_audit(e2e_workspace, desktop_page, monkeypatch):
    _setup_auth(e2e_workspace, include_member=True)
    probe_body = {"model_ids": [str(uuid4())], "system_prompt": "S", "user_input": "U"}
    with e2e_workspace.client() as anon:
        assert anon.get("/api/admin/models/playground/presets").status_code == 401
        assert anon.post("/api/admin/models/playground/run", json=probe_body).status_code == 401
    with e2e_workspace.client() as member_api:
        login_user(member_api, email=MEMBER_EMAIL, password=MEMBER_PASS)
        assert member_api.get("/api/admin/models/playground/presets").status_code == 403
        assert member_api.post("/api/admin/models/playground/run", json=probe_body).status_code == 403
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        m_oa = _create_model(admin_api, slug="pg-oa", name="PG OpenAI", provider="openai", capability="reference", model_id="gpt-4o", secret=OA_SECRET)
        _create_model(admin_api, slug="pg-ant", name="PG Anthropic", provider="anthropic", capability="judge", model_id="claude-sonnet-4-6", secret=ANT_SECRET)
        m_dg = _create_model(admin_api, slug="pg-dg", name="PG Deepgram", provider="deepgram", capability="transcription", model_id="nova-2", secret=DG_SECRET)
        assert admin_api.post("/api/admin/models/playground/run", json={"model_ids": [m_dg["id"]], "system_prompt": "S", "user_input": "U"}).status_code == 422
        admin_api.headers.pop("X-InterviewCheck", None)
        assert admin_api.post("/api/admin/models/playground/run", json={"model_ids": [m_oa["id"]], "system_prompt": "S", "user_input": "U"}).status_code == 403

    page, collector = desktop_page
    _sign_in_admin(page, e2e_workspace.base_url)
    tablist = page.get_by_role("tablist", name="Admin sections")
    tablist.get_by_role("tab", name="Diagnostics").focus()
    page.keyboard.press("ArrowRight")
    pg_tab = tablist.get_by_role("tab", name="Playground")
    expect(pg_tab).to_be_focused()
    expect(pg_tab).to_have_attribute("aria-selected", "true")
    panel = page.locator("#panel-playground")
    expect(panel.get_by_role("heading", name="Model playground")).to_be_visible()
    expect(panel.get_by_text("PG Deepgram")).to_have_count(0)

    panel.get_by_label("Benchmark preset").select_option("ai_judge_rubric")
    expect(panel.get_by_label("Expected schema")).to_have_value("judge_verdict")
    expect(panel.get_by_label("Frame user input as untrusted data (prompt-injection guard)")).to_be_checked()
    panel.locator("label", has_text="PG OpenAI").locator("input[type='checkbox']").check()
    panel.locator("label", has_text="PG Anthropic").locator("input[type='checkbox']").check()
    expect(panel.get_by_text("2 / 3 models selected")).to_be_visible()

    verdict = json.dumps({"likelihood": 88, "confidence": "high", "evidence": ["Quorum"], "follow_up_questions": ["Term bumps?"]})
    ant_verdict = json.dumps({"likelihood": 77, "confidence": "medium", "evidence": [f"Key {ANT_SECRET}"], "follow_up_questions": []})
    async def fake_ok(name, method, url, **kwargs):
        if name == "Anthropic":
            return {"stop_reason": "end_turn", "content": [{"type": "text", "text": ant_verdict}], "usage": {"input_tokens": 80, "output_tokens": 30}}
        return {"choices": [{"finish_reason": "stop", "message": {"content": verdict}}], "usage": {"prompt_tokens": 120, "completion_tokens": 40}}

    monkeypatch.setattr(provider_http, "fetch_json", fake_ok)
    panel.get_by_role("button", name="Run benchmark").click()
    expect(panel.get_by_text("2 / 2 succeeded")).to_be_visible()
    oa_card, ant_card = panel.get_by_label("Result for PG OpenAI"), panel.get_by_label("Result for PG Anthropic")
    expect(oa_card).to_contain_text("Schema valid")
    expect(oa_card).to_contain_text("120 in / 40 out")
    expect(ant_card).to_contain_text("[redacted]")
    oa_card.locator("summary", has_text="Parsed JSON").click()
    expect(oa_card).to_contain_text('"likelihood": 88')

    async def fake_mixed(name, method, url, **kwargs):
        if name == "Anthropic":
            raise HTTPException(502, f"Upstream failed with Bearer {ANT_SECRET}")
        return {"choices": [{"finish_reason": "stop", "message": {"content": "not valid json"}}], "usage": {"prompt_tokens": 10, "completion_tokens": 5}}

    monkeypatch.setattr(provider_http, "fetch_json", fake_mixed)
    panel.get_by_role("button", name="Run benchmark").click()
    expect(panel.get_by_text("1 / 2 succeeded")).to_be_visible()
    expect(oa_card).to_contain_text("Schema invalid")
    expect(oa_card.get_by_label("Schema validation errors")).to_be_visible()
    expect(ant_card).to_contain_text("HTTP 502")
    expect(ant_card.get_by_role("alert")).to_be_visible()

    panel.locator("label", has_text="PG OpenAI").locator("input[type='checkbox']").uncheck()
    panel.locator("label", has_text="PG Anthropic").locator("input[type='checkbox']").uncheck()
    expect(panel.get_by_role("button", name="Run benchmark")).to_be_disabled()
    panel.locator("label", has_text="PG OpenAI").locator("input[type='checkbox']").check()
    panel.get_by_label("System prompt").fill("   ")
    panel.get_by_role("button", name="Run benchmark").click()
    expect(panel.locator("p[role='alert']", has_text="System prompt and user input are required.")).to_be_visible()

    page.get_by_role("tab", name="Audit log").click()
    expect(page.locator("#panel-audit")).to_contain_text("admin.model.playground")
    html = page.content()
    for secret in (OA_SECRET, ANT_SECRET, DG_SECRET, "e2e-deterministic-test-secret-key"):
        assert secret not in html
    collector.assert_clean()


@pytest.mark.parametrize("viewport", [(1440, 900, "desktop-1440"), (390, 844, "mobile-390")], ids=lambda v: v[2])
def test_m14_responsive_compare_and_playground_viewports_and_themes(e2e_workspace, e2e_browser, monkeypatch, viewport):
    width, height, _ = viewport
    _setup_auth(e2e_workspace)
    with e2e_workspace.client() as c:
        login_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS)
        _create_model(c, slug="resp-oa", name="Responsive OpenAI", provider="openai", capability="reference", model_id="gpt-4o", secret=OA_SECRET)
        role = _seed_rubric_role(c)
        s1, s2 = _seed_session(c, candidate="Resp One", role=role), _seed_session(c, candidate="Resp Two", role=role)
        _add_answer(c, s1, question="Explain Raft safety.", answer=PASSAGE, slot=1, match=True)
        _add_answer(c, s2, question="Explain Raft safety.", answer="Quorum majority.", slot=1)

    async def fake_array(name, method, url, **kwargs):
        return {"choices": [{"finish_reason": "stop", "message": {"content": '["Q1?", "Q2?"]'}}], "usage": {"prompt_tokens": 30, "completion_tokens": 15}}

    monkeypatch.setattr(provider_http, "fetch_json", fake_array)
    mobile = width <= 480
    ctx = e2e_browser.new_context(viewport={"width": width, "height": height}, reduced_motion="reduce", is_mobile=mobile, has_touch=mobile)
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    try:
        _sign_in_admin(page, e2e_workspace.base_url)
        for theme in ("dark", "light"):
            page.goto(e2e_workspace.base_url + "/account/", wait_until="domcontentloaded")
            expect(page.get_by_text(ADMIN_EMAIL)).to_be_visible()
            page.get_by_role("radio", name=theme.capitalize()).check()
            expect(page.locator("html")).to_have_attribute("data-theme", theme)
            for route in ("/interviews/", "/interviews/compare/", f"/interviews/compare/?ids={s1},{s2}"):
                page.goto(e2e_workspace.base_url + route, wait_until="domcontentloaded")
                expect(page.locator("main#main-content")).to_be_visible()
                assert_no_horizontal_overflow(page)

            page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
            tablist = page.get_by_role("tablist", name="Admin sections")
            expect(tablist).to_be_visible()
            tablist.get_by_role("tab", name="Models").focus()
            page.keyboard.press("End")
            expect(tablist.get_by_role("tab").last).to_be_focused()
            tablist.get_by_role("tab", name="Playground").click()
            pg = page.locator("#panel-playground")
            expect(pg.get_by_role("heading", name="Model playground")).to_be_visible()
            pg.get_by_label("Benchmark preset").select_option("authoring_questions")
            pg.get_by_role("button", name="Run benchmark").click()
            expect(pg.get_by_text("1 / 1 succeeded")).to_be_visible()
            expect(pg.get_by_label("Result for Responsive OpenAI")).to_contain_text("Schema valid")
            assert_no_horizontal_overflow(page)
        collector.assert_clean()
    finally:
        ctx.close()
