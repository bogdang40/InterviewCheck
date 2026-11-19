"""Opaque-box Playwright E2E tests for M19 scorecards, handoff notes, local draft recovery, and print options."""
import json
from urllib.parse import parse_qs, urlsplit

from playwright.sync_api import expect
import pytest

from e2e_suite.harness import ConsoleErrorCollector, assert_no_horizontal_overflow, signup_user

ADMIN_EMAIL = "admin-m19@example.test"
ADMIN_PASS = "Synthetic-M19-Admin-Pass-1"
BOOTSTRAP_SECRET = "m19-bootstrap-secret-1234"
CANDIDATE_NAME = "Nadia Kovalenko"
RAW_ANSWER_TEXT = "Sentinel-phrase-wal-checkpoint-alpha-9182 verifies durability across restarts."
SOURCE_PASSAGE_TEXT = "Sentinel-phrase-wal-checkpoint-alpha-9182 from the internal storage manual."


def _seed_role_and_session(client, *, with_answer: bool = True):
    role_res = client.post(
        "/api/roles",
        json={
            "name": "Distributed Storage Engineer",
            "description": "Core storage systems",
            "policy": "Declared reference docs are allowed.",
            "questions": ["How does WAL recovery preserve durability?"],
            "rubric": [
                {"id": "sys-design", "criterion": "System Design", "weight": 3},
                {"id": "comm", "criterion": "Communication", "weight": 1},
            ],
        },
    )
    role_res.raise_for_status()
    role = role_res.json()
    sess_res = client.post(
        "/api/sessions",
        json={
            "candidate": CANDIDATE_NAME,
            "role": role["name"],
            "role_id": role["id"],
            "policy": role["policy"],
            "consent": True,
        },
    )
    sess_res.raise_for_status()
    session = sess_res.json()
    answer = None
    if with_answer:
        ans_res = client.post(
            f"/api/sessions/{session['id']}/answers",
            json={
                "question": "How does WAL recovery preserve durability?",
                "answer": RAW_ANSWER_TEXT,
                "references": [{"label": "Storage Manual", "text": SOURCE_PASSAGE_TEXT, "permitted": False}],
            },
        )
        ans_res.raise_for_status()
        answer = ans_res.json()
    return role, session, answer


def _wait_local_draft(page, key: str) -> dict:
    page.wait_for_function(
        "(k) => Boolean(window.localStorage.getItem(k))",
        arg=key,
        timeout=5000,
    )
    raw = page.evaluate("(k) => window.localStorage.getItem(k)", key)
    assert raw is not None
    return json.loads(raw)


def test_m19_scorecard_grading_handoff_notes_and_security_gates(e2e_workspace, desktop_page):
    with e2e_workspace.client() as c:
        _, session, answer = _seed_role_and_session(c, with_answer=True)
    sid = session["id"]
    aid = answer["id"]

    page, collector = desktop_page
    page.goto(f"{e2e_workspace.base_url}/interviews/review/?id={sid}&answer={aid}", wait_until="domcontentloaded")
    panel = page.get_by_label("Session scorecard panel")
    expect(panel).to_be_visible()
    badge = page.get_by_test_id("scorecard-weighted-badge")
    expect(badge).to_have_text("Score: Ungraded")

    # Typing hotkey chars inside rationale input must not trigger navigation or review hotkeys.
    page.get_by_role("button", name="Rate System Design 4 of 5").click()
    sys_rationale = page.get_by_label("Rationale for System Design")
    sys_rationale.fill("jkneuf Clear isolation and failover plan")
    page.get_by_role("button", name="Rate Communication 2 of 5").click()
    page.get_by_label("Rationale for Communication").fill("Brief tradeoffs")
    expect(badge).to_have_text("Score: 70.0%")

    # Add an ad-hoc criterion and verify weighted recalculation: (4*3 + 2*1 + 5*2) / (6*5) = 80.0%.
    page.get_by_label("Add criterion").fill("Debugging depth")
    page.get_by_label("Weight", exact=True).fill("2")
    page.get_by_role("button", name="Add criterion").click()
    page.get_by_role("button", name="Rate Debugging depth 5 of 5").click()
    page.get_by_label("Rationale for Debugging depth").fill("Methodical root cause analysis")
    expect(badge).to_have_text("Score: 80.0%")

    page.get_by_role("button", name="Save scorecard").click()
    expect(panel.get_by_text("Scorecard saved.", exact=True)).to_be_visible()

    # Create panel handoff notes across all four categories and delete one.
    notes_to_create = [
        ("observation", "Candidate explained WAL fsync ordering."),
        ("follow_up", "Probe checkpoint throttling on next round."),
        ("decision", "Recommend advancing to architecture panel."),
        ("concern", "Minor hesitation on split-brain quorum."),
    ]
    for category, body in notes_to_create:
        panel.get_by_role("combobox", name="Category", exact=True).select_option(category)
        panel.get_by_role("textbox", name="Handoff note", exact=True).fill(body)
        panel.get_by_role("button", name="Add handoff note").click()
        expect(panel.get_by_text(body, exact=True)).to_be_visible()

    assert_no_horizontal_overflow(page)

    # Reload and verify scorecard ratings, rationales, weighted score, and handoff notes persist.
    page.reload(wait_until="domcontentloaded")
    expect(page.get_by_test_id("scorecard-weighted-badge")).to_have_text("Score: 80.0%")
    expect(page.get_by_role("button", name="Rate System Design 4 of 5")).to_have_attribute("aria-pressed", "true")
    expect(page.get_by_role("button", name="Rate Communication 2 of 5")).to_have_attribute("aria-pressed", "true")
    expect(page.get_by_role("button", name="Rate Debugging depth 5 of 5")).to_have_attribute("aria-pressed", "true")
    expect(page.get_by_role("textbox", name="Rationale for System Design")).to_have_value("jkneuf Clear isolation and failover plan")
    expect(page.get_by_role("textbox", name="Rationale for Debugging depth")).to_have_value("Methodical root cause analysis")
    for _, body in notes_to_create:
        expect(page.get_by_label("Session scorecard panel").get_by_text(body, exact=True)).to_be_visible()

    # Delete the concern note and verify persistence after reload.
    page.get_by_role("button", name="Delete concern note").click()
    expect(page.get_by_text("Minor hesitation on split-brain quorum.")).to_have_count(0)
    page.reload(wait_until="domcontentloaded")
    expect(page.get_by_text("Minor hesitation on split-brain quorum.")).to_have_count(0)
    expect(page.get_by_text("Recommend advancing to architecture panel.")).to_be_visible()

    # Verify collapse/expand toggle state.
    collapse_btn = page.get_by_role("button", name="Collapse")
    collapse_btn.click()
    expect(page.get_by_role("button", name="Expand")).to_have_attribute("aria-expanded", "false")
    page.get_by_role("button", name="Expand").click()
    expect(page.get_by_role("button", name="Collapse")).to_have_attribute("aria-expanded", "true")
    page.evaluate("() => { window.__origDateNow = Date.now; Date.now = () => 1763500000000 }")
    for lbl in ("システム設計", "評価基準"):
        page.get_by_label("Add criterion").fill(lbl)
        page.get_by_role("button", name="Add criterion").click()
        page.get_by_role("button", name=f"Rate {lbl} 5 of 5").click()
    page.evaluate("() => { Date.now = window.__origDateNow }")
    page.get_by_role("button", name="Save scorecard").click()
    expect(panel.get_by_text("Scorecard saved.", exact=True)).to_be_visible()
    collector.assert_clean()

    # Verify CSRF and embedded auth fail-closed gates on scorecard and handoff-note APIs.
    with e2e_workspace.client() as no_csrf:
        no_csrf.headers.pop("X-InterviewCheck", None)
        assert no_csrf.put(
            f"/api/sessions/{sid}/scorecard",
            json={"items": [{"criterion_id": "c1", "criterion_label": "C1", "weight": 1, "rating": 4, "rationale": ""}]},
        ).status_code == 403
        assert no_csrf.post(
            f"/api/sessions/{sid}/handoff-notes",
            json={"category": "observation", "body": "Blocked without header"},
        ).status_code == 403

    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    with e2e_workspace.client() as anon:
        signup_user(anon, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as unauth:
        assert unauth.get(f"/api/sessions/{sid}/scorecard").status_code == 401
        assert unauth.put(
            f"/api/sessions/{sid}/scorecard",
            json={"items": [{"criterion_id": "c1", "criterion_label": "C1", "weight": 1, "rating": 4, "rationale": ""}]},
        ).status_code == 401
        assert unauth.post(
            f"/api/sessions/{sid}/handoff-notes",
            json={"category": "observation", "body": "Blocked unauthenticated"},
        ).status_code == 401


def test_m19_local_draft_recovery_answer_editor_and_evidence(e2e_workspace, desktop_page):
    with e2e_workspace.client() as c:
        _, empty_session, _ = _seed_role_and_session(c, with_answer=False)
        _, review_session, review_answer = _seed_role_and_session(c, with_answer=True)

    page, collector = desktop_page
    empty_sid = empty_session["id"]
    editor_key = f"ic_draft_v1:{empty_sid}:editor:new"

    # AnswerEditor: test local draft buffer -> reload -> restore -> save clears localStorage.
    page.goto(f"{e2e_workspace.base_url}/interviews/review/?id={empty_sid}", wait_until="domcontentloaded")
    page.get_by_role("textbox", name="Question", exact=True).fill("Explain snapshotting")
    page.get_by_role("textbox", name="Candidate answer", exact=True).fill("Copy-on-write checkpoints preserve consistent state.")
    buffered = _wait_local_draft(page, editor_key)
    assert buffered["question"] == "Explain snapshotting"

    page.reload(wait_until="domcontentloaded")
    banner = page.get_by_role("region", name="Local draft recovery")
    expect(banner).to_be_visible()
    expect(banner.locator("time")).to_be_visible()
    banner.get_by_role("button", name="Restore local edits").click()
    expect(banner).to_have_count(0)
    expect(page.get_by_role("textbox", name="Question", exact=True)).to_have_value("Explain snapshotting")
    expect(page.get_by_role("textbox", name="Candidate answer", exact=True)).to_have_value(
        "Copy-on-write checkpoints preserve consistent state."
    )

    page.get_by_role("button", name="Save and compare").click()
    expect(page.get_by_role("heading", name="Explain snapshotting", exact=True)).to_be_visible()
    assert page.evaluate("(k) => window.localStorage.getItem(k)", editor_key) is None

    # AnswerEditor: test isolation from Edit exchange and Discard local copy on a new exchange.
    page.get_by_role("button", name="Add exchange").click()
    page.get_by_role("textbox", name="Question", exact=True).fill("Discarded question")
    page.get_by_role("textbox", name="Candidate answer", exact=True).fill("Discarded local answer")
    _wait_local_draft(page, editor_key)
    page.reload(wait_until="domcontentloaded")
    page.get_by_role("button", name="Edit exchange").click()
    expect(page.get_by_role("region", name="Local draft recovery")).to_have_count(0)
    page.get_by_role("button", name="Cancel").click()
    page.get_by_role("button", name="Add exchange").click()
    discard_banner = page.get_by_role("region", name="Local draft recovery")
    expect(discard_banner).to_be_visible()
    discard_banner.get_by_role("button", name="Discard local copy").click()
    expect(discard_banner).to_have_count(0)
    assert page.evaluate("(k) => window.localStorage.getItem(k)", editor_key) is None

    # Evidence: test local buffer + stale-revision warning + Discard vs Restore + Save review.
    rev_sid = review_session["id"]
    rev_aid = review_answer["id"]
    review_key = f"ic_draft_v1:{rev_sid}:review:{rev_aid}"
    page.goto(f"{e2e_workspace.base_url}/interviews/review/?id={rev_sid}&answer={rev_aid}", wait_until="domcontentloaded")
    page.get_by_role("combobox", name="Review outcome", exact=True).select_option("explained")
    page.get_by_role("textbox", name="Interviewer note", exact=True).fill("Unsaved crash note before revision bump")
    _wait_local_draft(page, review_key)

    # Bump server revision out-of-band so reload detects baseRevision mismatch.
    with e2e_workspace.client() as c:
        patch_res = c.patch(
            f"/api/sessions/{rev_sid}/answers/{rev_aid}",
            json={"disposition": "unresolved", "note": "Server updated note", "expected_revision": 1},
        )
        patch_res.raise_for_status()
        assert patch_res.json()["revision"] == 2

    page.reload(wait_until="domcontentloaded")
    rev_banner = page.get_by_role("region", name="Local draft recovery")
    expect(rev_banner).to_be_visible()
    expect(rev_banner).to_contain_text("Server revision changed (2) since base revision 1.")
    assert_no_horizontal_overflow(page)

    # Restore local edits, save review, and confirm localStorage clears and server updates.
    rev_banner.get_by_role("button", name="Restore local edits").click()
    expect(rev_banner).to_have_count(0)
    expect(page.get_by_role("combobox", name="Review outcome", exact=True)).to_have_value("explained")
    expect(page.get_by_role("textbox", name="Interviewer note", exact=True)).to_have_value("Unsaved crash note before revision bump")
    page.get_by_role("button", name="Save review", exact=True).click()
    expect(page.get_by_text("Review saved", exact=True)).to_be_visible()
    assert page.evaluate("(k) => window.localStorage.getItem(k)", review_key) is None

    # Verify Discard local copy in Evidence clears buffer and keeps saved state.
    page.get_by_role("textbox", name="Interviewer note", exact=True).fill("Temporary discard note")
    _wait_local_draft(page, review_key)
    page.reload(wait_until="domcontentloaded")
    ev_discard = page.get_by_role("region", name="Local draft recovery")
    expect(ev_discard).to_be_visible()
    ev_discard.get_by_role("button", name="Discard local copy").click()
    expect(ev_discard).to_have_count(0)
    expect(page.get_by_role("textbox", name="Interviewer note", exact=True)).to_have_value("Unsaved crash note before revision bump")
    assert page.evaluate("(k) => window.localStorage.getItem(k)", review_key) is None
    collector.assert_clean()


def test_m19_custom_redacted_print_toggles_and_mobile_viewport(e2e_workspace, desktop_page, mobile_page):
    with e2e_workspace.client() as c:
        _, session, answer = _seed_role_and_session(c, with_answer=True)
        sid = session["id"]
        aid = answer["id"]
        c.put(
            f"/api/sessions/{sid}/scorecard",
            json={
                "items": [
                    {
                        "criterion_id": "sys-design",
                        "criterion_label": "System Design",
                        "weight": 3,
                        "rating": 5,
                        "rationale": "Strong durability design",
                    }
                ]
            },
        ).raise_for_status()
        c.post(
            f"/api/sessions/{sid}/handoff-notes",
            json={"category": "decision", "body": "Panel consensus: strong hire signal."},
        ).raise_for_status()

    # Desktop print options & live print HTML checks.
    d_page, d_collector = desktop_page
    d_page.goto(f"{e2e_workspace.base_url}/interviews/review/?id={sid}&answer={aid}", wait_until="domcontentloaded")
    print_link = d_page.get_by_role("link", name="Print or save PDF")
    default_href = print_link.get_attribute("href") or ""
    assert parse_qs(urlsplit(default_href).query) == {
        "include_sources": ["true"],
        "include_scorecard": ["true"],
        "include_handoff_notes": ["false"],
        "redact_candidate": ["false"],
    }

    default_res = d_page.request.get(e2e_workspace.base_url + default_href)
    assert default_res.status == 200
    assert default_res.headers.get("cache-control") == "no-store"
    assert "style-src 'self' 'sha256-" in (default_res.headers.get("content-security-policy") or "")
    default_html = default_res.text()
    assert CANDIDATE_NAME in default_html
    assert RAW_ANSWER_TEXT in default_html
    assert SOURCE_PASSAGE_TEXT in default_html
    assert "Weighted score: 100.0%" in default_html
    assert "Panel handoff notes" not in default_html

    options_btn = d_page.get_by_role("button", name="Print options")
    options_btn.click()
    expect(options_btn).to_have_attribute("aria-expanded", "true")
    options_group = d_page.get_by_role("group", name="Print report options")
    expect(options_group).to_be_visible()
    options_group.get_by_label("Include sources").uncheck()
    options_group.get_by_label("Include handoff notes").check()
    options_group.get_by_label("Redact candidate").check()
    assert_no_horizontal_overflow(d_page)

    custom_href = print_link.get_attribute("href") or ""
    assert parse_qs(urlsplit(custom_href).query) == {
        "include_sources": ["false"],
        "include_scorecard": ["true"],
        "include_handoff_notes": ["true"],
        "redact_candidate": ["true"],
    }
    d_page.keyboard.press("Escape")
    expect(options_group).to_have_count(0)
    expect(options_btn).to_be_focused()

    # Open customized redacted print report in a browser page to verify CSP & HTML output.
    print_page = d_page.context.new_page()
    print_collector = ConsoleErrorCollector()
    print_collector.attach(print_page)
    try:
        resp = print_page.goto(e2e_workspace.base_url + custom_href, wait_until="domcontentloaded")
        assert resp is not None and resp.status == 200
        body_text = print_page.locator("body").inner_text()
        assert "Candidate [Redacted]" in body_text
        assert CANDIDATE_NAME not in body_text
        assert RAW_ANSWER_TEXT not in body_text
        assert SOURCE_PASSAGE_TEXT not in body_text
        assert "Matched passages" in body_text
        assert "Weighted score: 100.0%" in body_text
        assert "Panel handoff notes" in body_text
        assert "Panel consensus: strong hire signal." in body_text
        print_collector.assert_clean()
    finally:
        print_page.close()
    d_collector.assert_clean()

    # Mobile (390x844) checks: scorecard panel, handoff notes, recovery banner, and Reports dropdown.
    m_page, m_collector = mobile_page
    m_page.goto(f"{e2e_workspace.base_url}/interviews/review/?id={sid}&answer={aid}", wait_until="domcontentloaded")
    expect(m_page.get_by_label("Session scorecard panel")).to_be_visible()
    expect(m_page.get_by_test_id("scorecard-weighted-badge")).to_have_text("Score: 100.0%")
    assert_no_horizontal_overflow(m_page)

    m_page.get_by_role("button", name="Reports").click()
    expect(m_page.get_by_role("group", name="Print report options")).to_be_visible()
    m_page.get_by_label("Redact candidate").check()
    m_href = m_page.get_by_role("link", name="Print or save PDF").get_attribute("href") or ""
    assert "redact_candidate=true" in m_href
    assert_no_horizontal_overflow(m_page)

    m_page.get_by_role("textbox", name="Interviewer note", exact=True).fill("Mobile unsaved draft check")
    _wait_local_draft(m_page, f"ic_draft_v1:{sid}:review:{aid}")
    m_page.reload(wait_until="domcontentloaded")
    expect(m_page.get_by_role("region", name="Local draft recovery")).to_be_visible()
    assert_no_horizontal_overflow(m_page)
    m_collector.assert_clean()
