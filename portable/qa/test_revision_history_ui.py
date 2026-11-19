"""Exercise saved revision selection without changing the editable assessment."""
import httpx
from playwright.sync_api import expect


def exchange(client, sid, question):
    return client.post(f"/api/sessions/{sid}/answers", json={
        "question": question, "answer": "Compare the fixture measurements before making a decision.",
        "references": [{"label": "Bench manual", "text": "Record the fixture measurements."}],
    }).raise_for_status().json()["id"]


def session(client):
    return client.post("/api/sessions", json={
        "candidate": "History fixture", "role": "Test engineer", "consent": True, "policy": "Manual permitted.",
    }).raise_for_status().json()["id"]


def test_history_keeps_stale_review_draft_and_returns_keyboard_focus(workspace_url, browser_page, tmp_path):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid = session(client)
        aid = exchange(client, sid, "Which measurement comes first?")
        path = f"/api/sessions/{sid}/answers/{aid}"
        url = workspace_url + f"/interviews/review/?id={sid}&answer={aid}"
        page.goto(url)
        note = page.get_by_role("textbox", name="Interviewer note", exact=True)
        note.fill("Unsaved observation from the first view.")
        other = page.context.new_page()
        try:
            other.goto(url)
            other.get_by_role("textbox", name="Interviewer note", exact=True).fill("Observation saved in the other view.")
            other.get_by_role("button", name="Save review", exact=True).click()
            expect(other.get_by_text("Review saved", exact=True)).to_be_visible()
        finally:
            other.close()
        page.get_by_role("button", name="Save review", exact=True).click()
        expect(page.get_by_role("button", name="Reload saved exchange")).to_be_visible()

        requested = []
        page.on("request", lambda req: requested.append(req.method) if "/history" in req.url else None)
        trigger = page.get_by_role("button", name="Revision history", exact=True)
        trigger.focus()
        trigger.press("Enter")
        history = page.get_by_role("region", name="Saved revision history")
        expect(history.get_by_role("heading", name="Current revision 2")).to_be_visible()
        expect(history.get_by_text("Observation saved in the other view.")).to_be_visible()
        expect(history.get_by_text("The editor has revision 1. The latest saved revision is 2.")).to_be_visible()
        picker = history.get_by_label("Saved revision", exact=True)
        trigger.press("Tab")
        expect(picker).to_be_focused()
        # Native select typeahead chooses the earlier revision on each platform.
        picker.press("e")
        expect(history.get_by_role("heading", name="Earlier revision 1")).to_be_visible()
        expect(history.get_by_text("Operator unknown · Save time unknown")).to_be_visible()
        expect(history.get_by_text("No saved note.", exact=True)).to_be_visible()
        expect(note).to_have_value("Unsaved observation from the first view.")
        history.get_by_text("Saved evidence", exact=True).click()
        expect(history.get_by_text("Bench manual", exact=True)).to_be_visible()
        history.scroll_into_view_if_needed()
        page.screenshot(path=tmp_path / "history-desktop.png")
        page.set_viewport_size({"width": 320, "height": 800})
        expect(page.locator("html")).to_have_css("color-scheme", "dark")
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        history.scroll_into_view_if_needed()
        page.screenshot(path=tmp_path / "history-mobile.png")
        history.get_by_role("button", name="Close history").press("Enter")
        expect(trigger).to_be_focused()
        expect(note).to_have_value("Unsaved observation from the first view.")
        assert requested and set(requested) == {"GET"}
        assert client.get(path).raise_for_status().json()["note"] == "Observation saved in the other view."


def test_delayed_snapshot_cannot_replace_another_answer(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid = session(client)
        first = exchange(client, sid, "First fixture question?")
        second = exchange(client, sid, "Second fixture question?")
        path = f"/api/sessions/{sid}/answers/{first}"
        client.patch(path, json={"expected_revision": 1, "disposition": "pending", "note": "First saved note."}).raise_for_status()
        held = []
        page.route("**" + path + "/history/1", lambda route: held.append(route))
        page.goto(workspace_url + f"/interviews/review/?id={sid}&answer={first}")
        trigger = page.get_by_role("button", name="Revision history")
        trigger.click()
        picker = page.get_by_label("Saved revision", exact=True)
        with page.expect_request("**" + path + "/history/1"):
            picker.select_option("1")
        expect(page.get_by_role("status").filter(has_text="Loading saved revision")).to_be_visible()
        page.get_by_role("navigation", name="Interview questions").get_by_role("button", name="02", exact=False).click()
        trigger.click()
        history = page.get_by_role("region", name="Saved revision history")
        expect(history.get_by_text("Second fixture question?", exact=True)).to_be_visible()
        assert held and second in page.url
        route, = held
        with page.expect_request_finished(lambda req: req.url.endswith(path + "/history/1")):
            route.fulfill(response=route.fetch())
        expect(history.get_by_text("First fixture question?", exact=True)).to_have_count(0)
        expect(history.get_by_text("Second fixture question?", exact=True)).to_be_visible()


def test_history_paging_retains_focus_and_recovers_a_failed_snapshot(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid = session(client)
        aid = exchange(client, sid, "How did the fixture change?")
        path = f"/api/sessions/{sid}/answers/{aid}"
        for revision in range(1, 22):
            client.patch(path, json={
                "expected_revision": revision, "note": f"Saved observation {revision}.", "disposition": "pending",
            }).raise_for_status()
        detail_url = "**" + path + "/history/2"
        page.route(detail_url, lambda route: route.fulfill(status=503, json={"detail": "Fixture service unavailable."}), times=1)
        page.goto(workspace_url + f"/interviews/review/?id={sid}&answer={aid}")
        page.get_by_role("button", name="Revision history").click()
        history = page.get_by_role("region", name="Saved revision history")
        expect(history.get_by_role("heading", name="Current revision 22")).to_be_visible()
        history.get_by_role("button", name="Older revisions").press("Enter")
        picker = history.get_by_label("Saved revision", exact=True)
        expect(picker).to_be_focused()
        expect(history.get_by_role("alert")).to_have_text("Fixture service unavailable.")
        history.get_by_role("button", name="Retry saved revision").click()
        expect(history.get_by_role("heading", name="Earlier revision 2")).to_be_visible()
        expect(history.get_by_text("Saved observation 1.")).to_be_visible()
        history.get_by_role("button", name="Newer revisions").press("Enter")
        expect(picker).to_be_focused()
        expect(history.get_by_role("heading", name="Current revision 22")).to_be_visible()
