"""Local buffers must not bring back undone work or survive removal from another tab."""
from datetime import datetime, timezone
import json

import httpx
from playwright.sync_api import expect


def new_session(client):
    return client.post("/api/sessions", json={
        "candidate": "Test reviewer", "role": "Engineer", "policy": "Manual permitted.", "consent": True,
    }).raise_for_status().json()["id"]


def hold_draft_timer(page):
    # Leave the debounced write pending until the real pagehide handler flushes it.
    page.evaluate("""() => {
      const original = window.setTimeout.bind(window);
      window.setTimeout = (callback, delay, ...args) => original(callback, delay === 400 ? 60000 : delay, ...args);
    }""")


def stored(page, key):
    return page.evaluate("key => localStorage.getItem(key)", key)


def check_undo(page, field, key):
    finish = page.get_by_role("button", name="Finish interview", exact=True)
    hold_draft_timer(page)
    field.fill("Private local edit.")
    expect(finish).to_be_disabled()
    assert stored(page, key) is None
    field.fill("")
    expect(finish).to_be_enabled()
    page.evaluate("window.dispatchEvent(new Event('pagehide'))")
    assert stored(page, key) is None

    field.fill("Another local edit.")
    expect(finish).to_be_disabled()
    page.evaluate("window.dispatchEvent(new Event('pagehide'))")
    assert json.loads(stored(page, key))["text"] == "Another local edit."
    field.fill("")
    expect(finish).to_be_enabled()
    assert stored(page, key) is None
    page.reload()
    expect(field).to_have_value("")
    expect(page.get_by_role("region", name="Local draft recovery")).to_have_count(0)


def test_undo_clears_pending_and_written_edits_in_both_editors(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid = new_session(client)
        path = f"/api/sessions/{sid}/answers"
        url = f"{workspace_url}/interviews/review/?id={sid}"
        page.goto(url)
        check_undo(page, page.get_by_role("textbox", name="Candidate answer", exact=True), f"ic_draft_v1:{sid}:editor:new")
        aid = client.post(path, json={"question": "What did you test?", "answer": "A synthetic answer."}).raise_for_status().json()["id"]
        page.goto(url + "&answer=" + aid)
        check_undo(page, page.get_by_role("textbox", name="Interviewer note", exact=True), f"ic_draft_v1:{sid}:review:{aid}")


def test_trash_in_one_tab_invalidates_another_tabs_unwritten_draft(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, other = new_session(client), new_session(client)
    url = f"{workspace_url}/interviews/review/?id={sid}"
    key, other_key = (f"ic_draft_v1:{i}:editor:new" for i in (sid, other))
    page.goto(url)
    field = page.get_by_role("textbox", name="Candidate answer", exact=True)
    expect(field).to_be_visible()
    hold_draft_timer(page)
    keep = json.dumps({"text": "Different interview", "savedAt": datetime.now(timezone.utc).isoformat()})
    page.evaluate("([key, value]) => localStorage.setItem(key, value)", [other_key, keep])
    field.fill("Unwritten text.")
    expect(page.get_by_role("button", name="Finish interview")).to_be_disabled()
    assert stored(page, key) is None
    other_page = page.context.new_page()
    try:
        other_page.goto(url)
        other_page.get_by_role("button", name="Move to Trash").click()
        other_page.get_by_role("button", name="Confirm move to Trash").click()
        expect(other_page).to_have_url(workspace_url + "/trash/")
        page.evaluate("window.dispatchEvent(new Event('pagehide'))")
        assert stored(page, key) is None and stored(page, other_key) == keep
    finally:
        other_page.close()
