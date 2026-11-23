"""Local draft recovery follows the saved draft or published exchange it belongs to."""
from datetime import datetime, timezone
import json
from uuid import uuid4

import httpx
from playwright.sync_api import expect


def create_session(client, name):
    return client.post("/api/sessions", json={
        "candidate": name, "role": "Engineer", "policy": "Notes permitted.", "consent": True,
    }).raise_for_status().json()["id"]


def save_draft(client, route, text):
    return client.put(route, json={
        "id": str(uuid4()), "question": "Describe the test.", "answer": text,
        "references": [], "expected_revision": 0,
    }).raise_for_status().json()


def test_resumed_local_copy_stays_with_its_saved_draft(workspace_url, browser_page):
    page = browser_page
    page.on("dialog", lambda dialog: dialog.accept())
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid = create_session(client, "Saved draft recovery")
        route = f"/api/sessions/{sid}/draft"
        first = save_draft(client, route, "First saved answer.")
        page.goto(f"{workspace_url}/interviews/review/?id={sid}")
        resume = page.get_by_role("button", name="Resume draft")
        answer = page.get_by_role("textbox", name="Candidate answer")
        resume.click()
        answer.fill("Unsaved wording for the first draft.")
        page.reload()
        resume.click()
        recovery = page.get_by_role("region", name="Local draft recovery")
        recovery.get_by_role("button", name="Restore local edits").click()
        expect(answer).to_be_focused()
        expect(answer).to_have_value("Unsaved wording for the first draft.")
        assert client.get(route).raise_for_status().json()["answer"] == "First saved answer."

        client.post(route + "/discard", json={"id": first["id"], "expected_revision": first["revision"]}).raise_for_status()
        second = save_draft(client, route, "Replacement draft.")
        assert second["revision"] == first["revision"] and second["id"] != first["id"]
        page.reload()
        resume.click()
        expect(answer).to_have_value("Replacement draft.")
        expect(recovery).to_have_count(0)
        assert page.evaluate("""(sid) => Object.entries(localStorage).filter(([key]) =>
          key.startsWith('ic_draft_v1:' + sid + ':')).map(([, value]) => JSON.parse(value).draftId)
        """, sid) == [first["id"]]


def test_unlinked_copy_is_private_and_can_be_recovered_as_a_file(workspace_url, browser_page, tmp_path):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid = create_session(client, "Unlinked draft recovery")
        other = create_session(client, "Separate interview")
        route = f"/api/sessions/{sid}/draft"
        draft = save_draft(client, route, "Current saved answer.")
        legacy = {
            "text": "Private unlinked answer.", "question": "Private unlinked question?",
            "baseRevision": draft["revision"], "savedAt": datetime.now(timezone.utc).isoformat(),
            "origin": {"planned_slot": 2}, "sources": [
                {"label": "Private manual", "text": "Read this passage.", "permitted": True},
                {"label": "計測🧪" * 60, "text": "", "permitted": False},
            ],
        }
        page.goto(workspace_url + "/sample/")
        page.evaluate("([key, value]) => localStorage.setItem(key, value)", [f"ic_draft_v1:{sid}:editor:new", json.dumps(legacy)])
        page.goto(f"{workspace_url}/interviews/review/?id={sid}")
        page.get_by_role("button", name="Resume draft").click()
        answer = page.get_by_role("textbox", name="Candidate answer")
        expect(answer).to_have_value("Current saved answer.")
        expect(page.get_by_role("region", name="Local draft recovery")).to_have_count(0)
        unlinked = page.get_by_role("region", name="Unlinked local draft")
        inspect = unlinked.get_by_role("button", name="Inspect local copy")
        expect(inspect).to_have_attribute("aria-expanded", "false")
        expect(unlinked.get_by_role("textbox")).to_have_count(0)
        inspect.focus()
        page.keyboard.press("Enter")
        copy = unlinked.get_by_role("textbox", name="Complete local draft (JSON)")
        assert json.loads(copy.input_value()) == legacy
        expect(copy).to_have_attribute("readonly", "")
        page.set_viewport_size({"width": 320, "height": 800})
        assert unlinked.evaluate("(el) => el.scrollWidth <= el.clientWidth")
        unlinked.screenshot(path=tmp_path / "unlinked-draft-copy.png")
        page.evaluate("Object.defineProperty(navigator, 'clipboard', {value: undefined, configurable: true})")
        unlinked.get_by_role("button", name="Copy draft", exact=True).click()
        expect(unlinked.get_by_role("status")).to_contain_text("Draft text selected.")
        expect(copy).to_be_focused()
        assert copy.evaluate("(el) => el.selectionStart === 0 && el.selectionEnd === el.value.length")
        with page.expect_download() as event:
            unlinked.get_by_role("button", name="Download JSON").click()
        assert json.loads(event.value.path().read_text(encoding="utf-8")) == legacy
        assert client.get(route).raise_for_status().json() == draft
        unlinked.get_by_role("button", name="Discard unlinked copy").click()
        expect(unlinked).to_have_count(0)
        expect(answer).to_be_focused()
        expect(answer).to_have_value("Current saved answer.")
        page.get_by_role("button", name="Cancel", exact=True).click()

        # Moving to Trash clears only this browser's copies for the successfully moved interview.
        key = f"ic_draft_v1:{sid}:review:{uuid4()}"
        other_key = f"ic_draft_v1:{other}:editor:new"
        page.evaluate("([a, b, v]) => { localStorage.setItem(a, v); localStorage.setItem(b, v); }",
                      [key, other_key, json.dumps(legacy)])
        endpoint = f"**/api/sessions/{sid}/trash"
        page.route(endpoint, lambda route: route.fulfill(status=409, json={"detail": "Fixture move failed."}))
        page.get_by_role("button", name="Move to Trash").click()
        confirm = page.get_by_role("button", name="Confirm move to Trash")
        confirm.click()
        expect(page.get_by_text("Fixture move failed.", exact=True)).to_be_visible()
        assert page.evaluate("(key) => localStorage.getItem(key) !== null", key)
        page.unroute(endpoint)
        confirm.click()
        expect(page).to_have_url(workspace_url + "/trash/")
        assert page.evaluate("(key) => localStorage.getItem(key)", key) is None
        assert json.loads(page.evaluate("(key) => localStorage.getItem(key)", other_key)) == legacy


def test_review_recovery_actions_preserve_a_newer_local_write(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid = create_session(client, "Review copy race")
        answer = client.post(f"/api/sessions/{sid}/answers", json={
            "question": "How did you check?", "answer": "I measured twice.",
        }).raise_for_status().json()
    key = f"ic_draft_v1:{sid}:review:{answer['id']}"
    first = {"text": "Original review copy", "savedAt": datetime.now(timezone.utc).isoformat()}
    page.goto(workspace_url + "/sample/")
    page.evaluate("([key, value]) => localStorage.setItem(key, value)", [key, json.dumps(first)])
    page.goto(f"{workspace_url}/interviews/review/?id={sid}&answer={answer['id']}")
    banner = page.get_by_role("region", name="Local draft recovery")
    note = page.get_by_role("textbox", name="Interviewer note")
    expect(banner).to_be_visible()
    # Later writes land after the banner appears and immediately before each click handler runs.
    write_before_click = """([key, value]) => {
      document.addEventListener("click", () => localStorage.setItem(key, value), {capture: true, once: true});
    }"""
    newer = {**first, "text": "Updated elsewhere", "savedAt": datetime.now(timezone.utc).isoformat()}
    page.evaluate(write_before_click, [key, json.dumps(newer)])
    banner.get_by_role("button", name="Restore local edits").click()
    expect(note).to_have_value("")
    expect(banner).to_be_visible()
    latest = {**newer, "text": "Most recent review copy", "savedAt": datetime.now(timezone.utc).isoformat()}
    page.evaluate(write_before_click, [key, json.dumps(latest)])
    banner.get_by_role("button", name="Discard local copy").click()
    assert json.loads(page.evaluate("(key) => localStorage.getItem(key)", key)) == latest
    expect(note).to_be_focused()
