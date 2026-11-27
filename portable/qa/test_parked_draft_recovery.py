"""Local edits can be restored only into the parked draft lifetime that produced them."""
from datetime import datetime, timezone
import json

import httpx
from playwright.sync_api import expect

from test_deferred_questions_ui import keep_custom, open_queue, review_url, seed


def wait_for_buffer(page, sid, draft, text):
    key = f"ic_draft_v1:{sid}:editor:saved:{draft['id']}:life:{draft['recovery_fingerprint']}"
    page.wait_for_function(
        "([key, text]) => JSON.parse(localStorage.getItem(key))?.text === text",
        arg=[key, text],
    )


def test_same_id_recreated_linked_draft_cannot_offer_predecessor_text(workspace_url, browser_page):
    page = browser_page
    page.on("dialog", lambda d: d.accept())
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as c:
        sid, path, (parent, _) = seed(c)
        page.goto(review_url(workspace_url, sid, parent["id"]))
        queue = open_queue(page)
        keep_custom(queue)
        queue.get_by_role("button", name="Open answer draft").click()
        editor = page.get_by_role("textbox", name="Candidate answer", exact=True)
        expect(editor).to_be_visible()
        old = c.get(path + "/draft").raise_for_status().json()
        old_text = "Private text for the former parked draft."
        editor.fill(old_text)
        wait_for_buffer(page, sid, old, old_text)
        resume = page.get_by_role("button", name="Resume draft", exact=True)
        recovery = page.get_by_role("region", name="Local draft recovery")
        page.reload()
        resume.click()
        recovery.get_by_role("button", name="Restore local edits").click()
        expect(editor).to_have_value(old_text)
        assert c.get(path + "/draft").raise_for_status().json() == old
        c.post(path + "/draft/discard", json={"id": old["id"], "expected_revision": old["revision"],
               "deferred_question": old["deferred_question"], "deferred_draft_token": old["deferred_draft_token"]}).raise_for_status()
        new = c.put(path + "/draft", json={"id": old["id"], "expected_revision": 0, "question": old["question"],
                    "answer": old["answer"], "references": old["references"], "parent_answer_id": old["parent_answer_id"],
                    "deferred_question": old["deferred_question"]}).raise_for_status().json()
        for key in ("id", "revision", "question", "answer", "parent_answer_id", "references", "deferred_question"):
            assert new[key] == old[key]
        assert new["recovery_fingerprint"] != old["recovery_fingerprint"]

        legacy_text = "Private text buffered before draft lifetime tracking."
        legacy_key = f"ic_draft_v1:{sid}:editor:saved:{new['id']}"
        page.evaluate("([k,v]) => localStorage.setItem(k,v)", [legacy_key, json.dumps({
            "text": legacy_text, "draftId": new["id"], "baseRevision": new["revision"],
            "savedAt": datetime.now(timezone.utc).isoformat(),
        })])
        page.reload()
        resume.click()
        expect(editor).to_have_value(new["answer"])
        expect(recovery).to_have_count(0)
        unlinked = page.get_by_role("region", name="Unlinked local draft")
        expect(unlinked).to_be_visible()
        expect(unlinked.get_by_label("Complete local draft (JSON)")).to_have_count(0)
        unlinked.get_by_role("button", name="Inspect local copy").click()
        assert json.loads(unlinked.get_by_label("Complete local draft (JSON)").input_value())["text"] == legacy_text
        expect(editor).to_have_value(new["answer"])
        assert c.get(path + "/draft").json() == new

        current_text = "Recoverable edits for the replacement only."
        editor.fill(current_text)
        wait_for_buffer(page, sid, new, current_text)
        # The fingerprint is non-authorizing. Neither the queue token nor either draft write token goes to storage.
        raw = page.evaluate("JSON.stringify(Object.entries(localStorage))")
        for private in (old["deferred_draft_token"], new["deferred_draft_token"], new["deferred_question"]["version"]):
            assert private not in raw
        page.reload()
        resume.click()
        recovery.get_by_role("button", name="Restore local edits").click()
        expect(editor).to_have_value(current_text)
        assert c.get(path + "/draft").json() == new
