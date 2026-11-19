"""Playwright E2E tests for M7 opt-in semantic similarity and AI judge workbench UI."""
import json

from fastapi import HTTPException
from playwright.sync_api import expect
import pytest

from api import scoring_hooks
from e2e_suite.harness import assert_no_horizontal_overflow, login_user, signup_user

ADMIN_EMAIL = "admin-m7-ai@example.test"
BOOTSTRAP_SECRET = "m7-ai-bootstrap-secret-1234"
ADMIN_PASS = "Synthetic-M7-AI-Pass-1"


def _setup_workspace(e2e_workspace) -> str:
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
        sess = c.post(
            "/api/sessions",
            json={
                "candidate": "Grace Hopper",
                "role": "Distributed Systems Engineer",
                "policy": "Official RFC documentation is permitted.",
                "consent": True,
            },
        )
        sess.raise_for_status()
        return sess.json()["id"]


def _register_model(client, *, slug: str, display_name: str, capability: str, model_id: str, api_key: str) -> None:
    client.post(
        "/api/admin/models",
        json={
            "slug": slug,
            "display_name": display_name,
            "provider": "openai",
            "capability": capability,
            "model_id": model_id,
            "apiKey": api_key,
            "is_default": True,
        },
    ).raise_for_status()


def _sign_in(page, base_url: str) -> None:
    page.goto(base_url + "/account/", wait_until="domcontentloaded")
    expect(page.get_by_label("Operator email")).to_be_visible(timeout=20_000)
    page.get_by_label("Operator email").fill(ADMIN_EMAIL)
    page.get_by_label("Password", exact=True).fill(ADMIN_PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(ADMIN_EMAIL)).to_be_visible()


def test_m7_semantic_similarity_gating_opt_in_dirty_boundary_and_errors(e2e_workspace, desktop_page, monkeypatch):
    # Without an embedding model, the semantic button stays hidden even with answer and non-permitted source.
    sid = _setup_workspace(e2e_workspace)
    page, collector = desktop_page
    _sign_in(page, e2e_workspace.base_url)
    page.goto(f"{e2e_workspace.base_url}/interviews/review/?id={sid}", wait_until="domcontentloaded")
    expect(page.get_by_label("Question")).to_be_visible(timeout=20_000)
    page.get_by_label("Question").fill("Explain Raft leader election.")
    page.get_by_label("Candidate answer").fill("Followers start an election after a randomized timeout.")
    page.get_by_role("button", name="Add source").click()
    page.get_by_label("Source name").fill("External Blog")
    page.get_by_label("Source passage").fill("Followers start an election after a randomized timeout.")
    page.locator("details", has_text="Live comparison").locator("summary").click()
    expect(page.get_by_role("button", name="Check semantic similarity")).to_have_count(0)

    # Cancel unsaved new exchange, register an embedding model, and save an exchange via API.
    page.get_by_role("button", name="Cancel").click()
    with e2e_workspace.client() as c:
        login_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS)
        _register_model(
            c,
            slug="m7-embed",
            display_name="M7 Embedder",
            capability="embedding",
            model_id="text-embedding-3-small",
            api_key="sk-m7-embed-1111",
        )
        saved = c.post(
            f"/api/sessions/{sid}/answers",
            json={
                "question": "How does Raft guarantee log safety?",
                "answer": "Only candidates with the most up-to-date log can win leader election.",
                "references": [
                    {
                        "label": "Permitted Notes",
                        "text": "Official terminology allowed during interview.",
                        "permitted": True,
                    },
                    {
                        "label": "Unpermitted Cheatsheet",
                        "text": "Candidates must hold an up-to-date log to win the election.",
                        "permitted": False,
                    },
                ],
            },
        )
        saved.raise_for_status()
        answer_id = saved.json()["id"]

    semantic_calls: list[dict] = []
    mode = {"outcome": "ok"}

    async def fake_fetch(provider, method, url, **kwargs):
        assert "embeddings" in url
        semantic_calls.append(kwargs.get("json", {}))
        if mode["outcome"] == "429":
            raise HTTPException(429, "Quota exceeded")
        if mode["outcome"] == "503":
            raise HTTPException(503, "Embedding upstream unavailable")
        inputs = kwargs["json"]["input"]
        assert len(inputs) == 2  # Answer + 1 non-permitted reference (permitted excluded).
        return {
            "data": [
                {"index": 0, "embedding": [1.0, 0.0, 0.0]},
                {"index": 1, "embedding": [0.8, 0.6, 0.0]},
            ]
        }

    monkeypatch.setattr(scoring_hooks, "fetch_json", fake_fetch)

    page.goto(f"{e2e_workspace.base_url}/interviews/review/?id={sid}&answer={answer_id}", wait_until="domcontentloaded")
    expect(page.get_by_role("button", name="Edit exchange")).to_be_visible(timeout=20_000)
    page.get_by_role("button", name="Edit exchange").click()
    expect(page.get_by_role("heading", name="Edit exchange")).to_be_visible()

    live_details = page.locator("details", has_text="Live comparison")
    live_details.locator("summary").click()
    expect(live_details).to_have_attribute("open", "")
    sem_btn = page.get_by_role("button", name="Check semantic similarity")
    expect(sem_btn).to_be_visible()
    # Opening Live comparison or typing never auto-triggers POST /api/scoring/semantic.
    page.wait_for_timeout(500)
    assert len(semantic_calls) == 0

    # Verify gating: clearing answer hides button; only-permitted source hides button.
    orig_answer = page.get_by_label("Candidate answer").input_value()
    page.get_by_label("Candidate answer").fill("   ")
    expect(sem_btn).to_have_count(0)
    page.get_by_label("Candidate answer").fill(orig_answer)
    expect(sem_btn).to_be_visible()

    unpermitted_check = page.get_by_label("Permitted material").nth(1)
    unpermitted_check.check()
    expect(sem_btn).to_have_count(0)
    unpermitted_check.uncheck()
    expect(sem_btn).to_be_visible()
    assert len(semantic_calls) == 0
    # Back on original saved values -> AnswerEditor is NOT dirty.
    expect(page.get_by_text("Save or discard your changes before switching questions, finishing or exporting.")).to_have_count(0)

    # Explicit click triggers POST /api/scoring/semantic and preserves clean dirty state & sources.
    sem_btn.click()
    expect(page.locator(".semantic-panel").get_by_text("SEMANTIC SIMILARITY", exact=True)).to_be_visible()
    expect(page.locator(".semantic-panel").get_by_text("OpenAI · text-embedding-3-small", exact=True)).to_be_visible()
    expect(page.locator(".semantic-panel").get_by_text("Unpermitted Cheatsheet", exact=True)).to_be_visible()
    expect(page.locator(".semantic-panel").get_by_text("0.800", exact=True)).to_be_visible()
    expect(page.locator(".semantic-panel").get_by_text("Permitted Notes")).to_have_count(0)
    assert len(semantic_calls) == 1
    assert page.get_by_text("Save or discard your changes before switching questions, finishing or exporting.").count() == 0
    expect(page.get_by_label("Source name").nth(1)).to_have_value("Unpermitted Cheatsheet")
    expect(unpermitted_check).not_to_be_checked()

    # Verify 429 and 503 surface cleanly via role="alert" without crashing or dirtying state.
    mode["outcome"] = "429"
    sem_btn.click()
    expect(page.locator(".semantic-panel p[role='alert']")).to_contain_text("Quota exceeded")
    assert not collector.page_errors and not collector.server_errors
    page.wait_for_timeout(150)
    assert all("429" in msg for msg in collector.console_errors), collector.console_errors
    collector.reset()

    mode["outcome"] = "503"
    collector.ignore_server_5xx = True
    sem_btn.click()
    expect(page.locator(".semantic-panel p[role='alert']")).to_contain_text("Embedding upstream unavailable")
    page.wait_for_timeout(150)
    collector.ignore_server_5xx = False
    assert not collector.page_errors
    collector.reset()
    assert_no_horizontal_overflow(page)


def test_m7_ai_judge_review_follow_up_no_auto_save_and_workbench_selectors(e2e_workspace, desktop_page, monkeypatch):
    # Without a judge model configured, "Run AI review check" is not rendered.
    sid = _setup_workspace(e2e_workspace)
    phrase = "Compare the amber receiver against three cold baselines before recording the final interval"
    with e2e_workspace.client() as c:
        login_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS)
        ans_res = c.post(
            f"/api/sessions/{sid}/answers",
            json={
                "question": "Which interval matters?",
                "answer": "Start here. " + phrase + ".",
                "references": [
                    {"label": "Calibration", "text": "Spare adapters stay separate."},
                    {"label": "Inspector", "text": "Reference: " + phrase + "."},
                ],
            },
        )
        ans_res.raise_for_status()
        saved_answer = ans_res.json()
        answer_id = saved_answer["id"]
        deterministic_follow_up = saved_answer["result"]["follow_up"]

    page, collector = desktop_page
    _sign_in(page, e2e_workspace.base_url)
    page.goto(f"{e2e_workspace.base_url}/interviews/review/?id={sid}&answer={answer_id}", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Which interval matters?", exact=True)).to_be_visible(timeout=20_000)
    expect(page.get_by_role("button", name="Run AI review check")).to_have_count(0)

    # Register judge model and reload workbench so judgeAvailable === true.
    with e2e_workspace.client() as c:
        login_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS)
        _register_model(
            c,
            slug="m7-judge",
            display_name="M7 Judge",
            capability="judge",
            model_id="gpt-4o",
            api_key="sk-m7-judge-2222",
        )

    judge_calls: list[dict] = []
    judge_mode = {"outcome": "ok"}

    async def fake_judge_fetch(provider, method, url, **kwargs):
        assert "chat/completions" in url
        judge_calls.append(kwargs.get("json", {}))
        if judge_mode["outcome"] == "429":
            raise HTTPException(429, "Judge rate limit exceeded")
        if judge_mode["outcome"] == "503":
            raise HTTPException(503, "Judge upstream overloaded")
        return {
            "choices": [
                {
                    "finish_reason": "stop",
                    "message": {
                        "content": json.dumps(
                            {
                                "likelihood": 84,
                                "confidence": "high",
                                "evidence": [
                                    "Verbatim 13-word calibration sequence matches Inspector source.",
                                    "Terminology mirrors reference phrasing closely.",
                                ],
                                "follow_up_questions": [
                                    "Why are three cold baselines required before recording the interval?",
                                    "How would you adjust the calibration under thermal drift?",
                                ],
                            }
                        )
                    },
                }
            ]
        }

    monkeypatch.setattr(scoring_hooks, "fetch_json", fake_judge_fetch)

    page.goto(f"{e2e_workspace.base_url}/interviews/review/?id={sid}&answer={answer_id}", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Which interval matters?", exact=True)).to_be_visible(timeout=20_000)
    # Existing QA selectors must remain intact.
    expect(page.locator("article > .transcript-text mark")).to_have_text(phrase)
    sources_details = page.get_by_text("Source texts (2)", exact=True).locator("..")
    sources_details.locator("summary").click()
    expect(sources_details.locator("mark")).to_have_text(phrase)

    # Judge never runs automatically on page load.
    page.wait_for_timeout(300)
    assert len(judge_calls) == 0

    judge_section = page.get_by_role("region", name="AI review check")
    run_btn = judge_section.get_by_role("button", name="Run AI review check")
    expect(run_btn).to_be_visible(timeout=20_000)

    # Error paths (429 and 503) render role="alert" inside judge panel.
    judge_mode["outcome"] = "429"
    run_btn.click()
    expect(judge_section.locator("p[role='alert']")).to_contain_text("Judge rate limit exceeded")
    assert not collector.page_errors and not collector.server_errors
    page.wait_for_timeout(150)
    assert all("429" in msg for msg in collector.console_errors), collector.console_errors
    collector.reset()

    judge_mode["outcome"] = "503"
    collector.ignore_server_5xx = True
    run_btn.click()
    expect(judge_section.locator("p[role='alert']")).to_contain_text("Judge upstream overloaded")
    page.wait_for_timeout(150)
    collector.ignore_server_5xx = False
    collector.reset()

    # Success path renders likelihood, confidence, model label, evidence, and follow-up buttons.
    judge_mode["outcome"] = "ok"
    run_btn.click()
    expect(judge_section.get_by_text("Assistance likelihood: 84%")).to_be_visible()
    expect(judge_section.get_by_text("high", exact=True)).to_be_visible()
    expect(judge_section.get_by_text("OpenAI · gpt-4o")).to_be_visible()
    expect(judge_section.get_by_text("Verbatim 13-word calibration sequence matches Inspector source.")).to_be_visible()
    ai_q = "Why are three cold baselines required before recording the interval?"
    ai_q_btn = judge_section.get_by_role("button", name=ai_q)
    expect(ai_q_btn).to_be_visible()
    assert len(judge_calls) == 3

    # Clicking AI judge does NOT modify or auto-save disposition, note, or result.
    with e2e_workspace.client() as c:
        login_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS)
        persisted = c.get(f"/api/sessions/{sid}/answers/{answer_id}").json()
        assert persisted["disposition"] == "pending"
        assert persisted["note"] == ""
        assert persisted["result"] == saved_answer["result"]

    # Clicking AI follow-up button seeds AnswerEditor Question without saving review fields.
    ai_q_btn.click()
    expect(page.get_by_role("heading", name="Add an exchange")).to_be_visible()
    expect(page.get_by_role("textbox", name="Question")).to_have_value(ai_q)
    page.get_by_role("button", name="Cancel").click()

    # Deterministic "Ask this follow up" still seeds result.follow_up.
    page.get_by_role("button", name="Ask this follow up").click()
    expect(page.get_by_role("heading", name="Add an exchange")).to_be_visible()
    expect(page.get_by_role("textbox", name="Question")).to_have_value(deterministic_follow_up)
    page.get_by_role("button", name="Cancel").click()

    with e2e_workspace.client() as c:
        login_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS)
        after = c.get(f"/api/sessions/{sid}/answers/{answer_id}").json()
        assert after["disposition"] == "pending"
        assert after["note"] == ""
        assert after["result"] == saved_answer["result"]

    assert_no_horizontal_overflow(page)
    collector.assert_clean()
