"""Locate review work through the dashboard and persisted archive filters."""

from urllib.parse import parse_qs, urlsplit

import httpx
from playwright.sync_api import expect


def create_session(client, candidate):
    created = client.post(
        "/api/sessions",
        json={
            "candidate": candidate,
            "role": "Reliability engineer",
            "policy": "Operator references are permitted when declared.",
            "consent": True,
        },
    )
    created.raise_for_status()
    return created.json()["id"]


def answer(client, session, question, phrase, *, comparable=True):
    response = client.post(
        f"/api/sessions/{session}/answers",
        json={
            "question": question,
            "answer": phrase,
            "references": [{"label": "Example", "text": phrase}] if comparable else [],
        },
    )
    response.raise_for_status()
    return response.json()


def test_queue_opens_exact_answer_and_filters_survive_return(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        first = create_session(client, "Lake archived")
        common = (
            "Calibrate the receiver under three cold baselines before comparing the recorded packet counts."
        )
        previous = answer(client, first, "Which signal matters?", common)
        reviewed = client.patch(
            f"/api/sessions/{first}/answers/{previous['id']}",
            json={
                "disposition": "explained",
                "note": "The candidate derived the measurement.",
            },
        )
        reviewed.raise_for_status()
        target = answer(client, first, "Which sample do you use?", common)
        client.post(f"/api/sessions/{first}/finish").raise_for_status()
        other = create_session(client, "Lake active")
        answer(client, other, "Why repeat it?", common)
        clear = create_session(client, "Lake finished")
        answer(client, clear, "How does recovery work?", common, comparable=False)
        client.post(f"/api/sessions/{clear}/finish").raise_for_status()

        page.goto(workspace_url)
        expect(page.get_by_role("heading", name="Review queue", exact=True)).to_be_visible()
        page.locator(f'a[href*="id={first}"][href*="answer={target["id"]}"]').first.click()
        expect(page.get_by_role("heading", name="Which sample do you use?", exact=True)).to_be_visible()
        assert parse_qs(urlsplit(page.url).query)["answer"] == [target["id"]]
        page.reload()
        expect(page.get_by_role("heading", name="Which sample do you use?", exact=True)).to_be_visible()

        path = "/interviews/?q=Lake&status=finished&review=pending&sort=oldest"
        page.goto(workspace_url + path)
        expect(page.get_by_text("Lake archived", exact=True)).to_be_visible()
        expect(page.get_by_text("Lake active", exact=True)).to_have_count(0)
        expect(page.get_by_text("Lake finished", exact=True)).to_have_count(0)
        page.get_by_text("Lake archived", exact=True).click()
        expect(page.get_by_role("heading", name="Lake archived", exact=True)).to_be_visible()
        page.go_back()
        expect(page.get_by_text("Lake archived", exact=True)).to_be_visible()
        assert parse_qs(urlsplit(page.url).query) == parse_qs(urlsplit(path).query)


def test_stale_draft_cannot_advance_or_replace_newer_review(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid = create_session(client, "Cedar review")
        phrase = "The amber receiver needs three independent readings before the final comparison."
        current = answer(client, sid, "Why take another reading?", phrase)
        following = answer(client, sid, "When would you stop?", phrase)
        url = workspace_url + f"/interviews/review/?id={sid}&answer={current['id']}"
        page.goto(url)
        other = page.context.new_page()
        try:
            other.goto(url)
            page.get_by_label("Interviewer note").fill("My unsaved comparison.")
            other.get_by_label("Interviewer note").fill("The second interviewer checked the hardware.")
            other.get_by_label("Review outcome").select_option("explained")
            other.get_by_role("button", name="Save review", exact=True).click()
            expect(other.get_by_text("Review saved", exact=True)).to_be_visible()
            page.get_by_label("Review outcome").select_option("unresolved")
            page.get_by_role("button", name="Save and review next").click()
            expect(page.get_by_role("button", name="Reload saved exchange")).to_be_visible()
            assert parse_qs(urlsplit(page.url).query)["answer"] == [current["id"]]
            expect(page.get_by_label("Interviewer note")).to_have_value("My unsaved comparison.")
            path = f"/api/sessions/{sid}/answers/{current['id']}"
            assert client.get(path).json()["note"] == "The second interviewer checked the hardware."
            page.get_by_role("button", name="Reload saved exchange").click()
            expect(
                page.get_by_text("The second interviewer checked the hardware.", exact=True)
            ).to_be_visible()
            page.get_by_role("button", name="Keep editing my draft").click()
            expect(page.get_by_label("Interviewer note")).to_have_value("My unsaved comparison.")
            page.get_by_label("Interviewer note").fill("Both observations reconciled.")
            page.get_by_role("button", name="Save and review next").click()
            expect(page.get_by_role("heading", name="When would you stop?", exact=True)).to_be_visible()
            assert parse_qs(urlsplit(page.url).query)["answer"] == [following["id"]]
            assert client.get(path).json()["note"] == "Both observations reconciled."
        finally:
            other.close()


def test_phone_navigator_and_unicode_source_attribution(workspace_url, browser_page):
    page = browser_page
    page.set_viewport_size({"width": 390, "height": 844})
    phrase = "Compare the amber receiver against three cold baselines before recording the final interval"
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        key = create_session(client, "Phone fixture")
        first = answer(client, key, "What do you do first?", "Capture a local trace.", comparable=False)
        saved = client.post(
            f"/api/sessions/{key}/answers",
            json={
                "question": "Which interval matters?",
                "answer": "🔧 Start here. " + phrase + ".",
                "references": [
                    {"label": "Calibration", "text": "Keep all the spare adapters in a separate case."},
                    {"label": "Calibration", "text": "📘 Inspector: " + phrase + "."},
                ],
            },
        )
        saved.raise_for_status()
        page.goto(workspace_url + f"/interviews/review/?id={key}&answer={first['id']}")
        picker = page.get_by_role("combobox", name="Selected question")
        expect(picker).to_be_visible()
        picker.select_option(saved.json()["id"])
        expect(page.get_by_role("heading", name="Which interval matters?", exact=True)).to_be_visible()
        expect(page.locator("article > .transcript-text mark")).to_have_text(phrase)
        sources = page.get_by_text("Source texts (2)", exact=True).locator("..")
        sources.locator("summary").click()
        expect(sources.locator("mark")).to_have_count(1)
        expect(sources.locator("mark")).to_have_text(phrase)
        assert sources.locator("mark").locator("..").inner_text().startswith("📘 Inspector:")
        page.get_by_label("Interviewer note").fill("Pending mobile note.")
        expect(picker).to_be_disabled()
        page.get_by_role("button", name="Discard review changes").click()
        expect(picker).to_be_enabled()
        assert page.evaluate("document.documentElement.scrollWidth") <= 390
