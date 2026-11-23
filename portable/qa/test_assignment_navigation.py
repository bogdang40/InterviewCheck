"""The review route protects all editor drafts once and retains assignments between questions."""
import httpx
from playwright.sync_api import expect


def test_assignment_navigation_guard_and_local_discard(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid = client.post("/api/sessions", json={
            "candidate": "Guard fixture", "role": "Engineer", "policy": "Notes permitted.", "consent": True,
        }).raise_for_status().json()["id"]
        answer_ids = [client.post(f"/api/sessions/{sid}/answers", json={
            "question": question, "answer": "I checked the measurements.",
        }).raise_for_status().json()["id"] for question in ("First question?", "Second question?")]
        path = f"/api/sessions/{sid}/assignment"
        client.put(path, json={"assignee_email": "original@example.test", "priority": "normal"}).raise_for_status()

        prompts = []
        accept = False
        def on_dialog(dialog):
            prompts.append((dialog.type, dialog.message))
            if accept:
                dialog.accept()
            else:
                dialog.dismiss()
        page.on("dialog", on_dialog)
        start = f"{workspace_url}/interviews/review/?id={sid}&answer={answer_ids[0]}"
        page.goto(start)
        bar = page.get_by_role("region", name="Session assignment")
        email = bar.get_by_role("textbox", name="Assignee email")
        expect(email).to_have_value("original@example.test")
        email.fill("draft@example.test")
        discard = bar.get_by_role("button", name="Discard assignment changes")
        expect(discard).to_be_visible()
        expect(page.get_by_role("button", name="Move to Trash")).to_be_disabled()
        expect(page.get_by_role("button", name="Finish interview")).to_be_enabled()
        page.get_by_role("navigation", name="Interview questions").get_by_role("button", name="Second question?", exact=False).click()
        expect(page).to_have_url(f"{workspace_url}/interviews/review/?id={sid}&answer={answer_ids[1]}")
        page.go_back()
        expect(page).to_have_url(start)
        expect(email).to_have_value("draft@example.test")
        assert prompts == []

        leave = page.get_by_role("navigation", name="Workspace").get_by_role("link", name="Overview", exact=True)
        warning = ("confirm", "Discard unsaved interview changes and leave this page?")
        leave.click()
        assert prompts == [warning]
        expect(email).to_have_value("draft@example.test")

        note = page.get_by_role("textbox", name="Interviewer note", exact=True)
        handoff = page.get_by_role("textbox", name="Handoff note", exact=True)
        note.fill("Unfinished evidence note")
        handoff.fill("Unfinished panel note")
        discard.click()
        expect(email).to_be_focused()
        expect(email).to_have_value("original@example.test")
        expect(note).to_have_value("Unfinished evidence note")
        expect(handoff).to_have_value("Unfinished panel note")
        assert client.get(path).json()["assignment"]["assignee_email"] == "original@example.test"
        leave.click()
        assert prompts == [warning, warning]

        email.fill("second@example.test")
        accept = True
        leave.click()
        expect(page).to_have_url(workspace_url + "/")
        assert prompts == [warning, warning, warning]
        assert client.get(path).json()["assignment"]["assignee_email"] == "original@example.test"


def test_assignment_reload_warns_and_save_or_discard_releases_the_guard(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid = client.post("/api/sessions", json={
            "candidate": "Guard release", "role": "Engineer", "policy": "Notes permitted.", "consent": True,
        }).raise_for_status().json()["id"]
        path = f"/api/sessions/{sid}/assignment"
        url = f"{workspace_url}/interviews/review/?id={sid}"
        prompts = []
        def dismiss(dialog):
            prompts.append(dialog.type)
            dialog.dismiss()
        page.on("dialog", dismiss)
        bar = page.get_by_role("region", name="Session assignment")
        email = bar.get_by_role("textbox", name="Assignee email")
        leave = page.get_by_role("navigation", name="Workspace").get_by_role("link", name="Overview", exact=True)
        page.goto(url)
        email.click()
        email.fill("temporary@example.test")
        expect(page.get_by_role("button", name="Move to Trash")).to_be_disabled()
        with page.expect_event("dialog"):
            page.evaluate("setTimeout(() => location.reload(), 0)")
        assert prompts == ["beforeunload"]
        expect(email).to_have_value("temporary@example.test")
        bar.get_by_role("button", name="Discard assignment changes").click()
        expect(page.get_by_role("button", name="Move to Trash")).to_be_enabled()
        assert client.get(path).json()["assignment"] is None
        leave.click()
        expect(page).to_have_url(workspace_url + "/")
        page.goto(url)
        email.fill("saved@example.test")
        bar.get_by_role("button", name="Save assignment").click()
        expect(bar.get_by_role("status")).to_contain_text("Assigned to saved@example.test")
        leave.click()
        expect(page).to_have_url(workspace_url + "/")
        assert prompts == ["beforeunload"]
