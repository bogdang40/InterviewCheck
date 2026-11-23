"""The review route protects all editor drafts once and retains assignments between questions."""
import json
from uuid import uuid4

import httpx
from playwright.sync_api import Error as PlaywrightError, expect
import pytest


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
        email = bar.get_by_role("combobox", name="Assignee email", exact=True)
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
        email = bar.get_by_role("combobox", name="Assignee email", exact=True)
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


@pytest.mark.parametrize("handoff_draft", [False, True], ids=["exchange-only", "independent-handoff"])
def test_document_navigation_when_saved_exchange_first_appears(workspace_url, browser_page, handoff_draft):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid = client.post("/api/sessions", json={
            "candidate": "Saved exchange fixture", "role": "Engineer", "policy": "Notes permitted.", "consent": True,
        }).raise_for_status().json()["id"]
        page.goto(f"{workspace_url}/interviews/review/?id={sid}")
        question = "Which measurement did you check?"
        answer = "I checked the sample interval."
        page.get_by_role("textbox", name="Question", exact=True).fill(question)
        page.get_by_role("textbox", name="Candidate answer", exact=True).fill(answer)
        save = page.get_by_role("button", name="Save and compare", exact=True)
        handoff = page.get_by_role("textbox", name="Handoff note", exact=True)
        dialogs = []

        def dismiss(dialog):
            dialogs.append(dialog.type)
            dialog.dismiss()

        page.on("dialog", dismiss)
        if handoff_draft:
            handoff.fill("Independent unfinished handoff.")
        else:
            page.route(f"**/api/sessions/{sid}/answers", lambda route: route.fulfill(
                status=503, json={"detail": "Temporary fixture save failure."},
            ), times=1)
            save.click()
            expect(page.get_by_role("alert").filter(has_text="Temporary fixture save failure.")).to_be_visible()
            with page.expect_event("dialog"):
                page.evaluate("() => setTimeout(() => location.assign('/roles/'), 0)")
            assert dialogs == ["beforeunload"]
            dialogs.clear()

        # Measure the guard at the first commit. Use a trusted click for the separate document departure.
        page.evaluate("""answer => {
            const observer = new MutationObserver(() => {
                if (document.querySelector('article.evidence > .transcript-text')?.textContent !== answer) return;
                observer.disconnect();
                const check = new Event('beforeunload', { cancelable: true });
                window.dispatchEvent(check);
                const depart = document.createElement('button');
                depart.type = 'button';
                depart.textContent = 'Leave fixture document';
                depart.dataset.guardAtCommit = String(check.defaultPrevented);
                depart.addEventListener('click', () => location.assign('/roles/'), {once: true});
                document.body.append(depart);
            });
            observer.observe(document.body, {childList: true, subtree: true});
        }""", answer)
        save.click()
        depart = page.get_by_role("button", name="Leave fixture document", exact=True)
        guard = depart.get_attribute("data-guard-at-commit")
        try:
            assert guard == ("true" if handoff_draft else "false")
            if handoff_draft:
                with page.expect_event("dialog"):
                    depart.click()
                assert dialogs == ["beforeunload"]
                expect(handoff).to_have_value("Independent unfinished handoff.")
            else:
                depart.click()
                expect(page).to_have_url(workspace_url + "/roles/")
                assert dialogs == []
        except (AssertionError, PlaywrightError) as failure:
            raise AssertionError(f"Saved exchange departure: guard_at_commit={guard}, dialogs={dialogs}, url={page.url}") from failure
        stored = client.get(f"/api/sessions/{sid}").raise_for_status().json()["answers"]
        assert [(item["question"], item["answer"]) for item in stored] == [(question, answer)]


def test_unconfirmed_exchange_save_keeps_the_editor_and_local_recovery(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid = client.post("/api/sessions", json={
            "candidate": "Unconfirmed reply fixture", "role": "Engineer", "policy": "Notes permitted.", "consent": True,
        }).raise_for_status().json()["id"]
        path = f"/api/sessions/{sid}/answers"
        writes = []

        def unconfirmed(route):
            writes.append(route.request.post_data_json["id"])
            response = route.fetch()
            assert response.ok
            if len(writes) == 1:
                route.fulfill(status=204)
            else:
                route.fulfill(json={**response.json(), "id": str(uuid4())})

        page.route("**" + path, unconfirmed)
        page.goto(f"{workspace_url}/interviews/review/?id={sid}")
        question = page.get_by_role("textbox", name="Question", exact=True)
        answer = page.get_by_role("textbox", name="Candidate answer", exact=True)
        save = page.get_by_role("button", name="Save and compare", exact=True)
        question.fill("What did you measure?")
        answer.fill("The sample interval.")
        for attempt in (1, 2):
            with page.expect_response(lambda res: res.url == workspace_url + path and res.request.method == "POST"):
                save.click()
            expect(page.get_by_role("alert").filter(has_text="The server did not confirm this exchange.")).to_be_visible()
            expect(save).to_be_enabled()
            expect(question).to_have_value("What did you measure?")
            expect(answer).to_have_value("The sample interval.")
            assert page.evaluate("() => !window.dispatchEvent(new Event('beforeunload', {cancelable: true}))")
            raw = page.evaluate("key => localStorage.getItem(key)", f"ic_draft_v1:{sid}:editor:new")
            assert raw and json.loads(raw)["text"] == "The sample interval."
            assert len(writes) == attempt and len(set(writes)) == 1
        records = client.get(f"/api/sessions/{sid}").raise_for_status().json()["answers"]
        assert [item["id"] for item in records] == [writes[0]]
