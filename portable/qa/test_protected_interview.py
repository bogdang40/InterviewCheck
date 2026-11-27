"""Retained review records remain readable and cannot reopen private editors."""
import httpx
from playwright.sync_api import expect


def test_retention_blocks_an_open_editor_and_shows_read_only_review(workspace_url, browser_page):
    from api import store
    from api.retention_anonymizer import REDACTED_TEXT, SessionAnonymizer

    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        session = client.post("/api/sessions", json={"candidate": "Panel fixture", "role": "Engineer",
                                                     "policy": "Manual allowed", "consent": True}).raise_for_status().json()
        sid = session["id"]
        answer = client.post(f"/api/sessions/{sid}/answers", json={"question": "Why this approach?",
                                                                   "answer": "Private material."}).raise_for_status().json()
        page = browser_page
        page.goto(workspace_url + f"/interviews/review/?id={sid}&answer={answer['id']}")
        note = page.get_by_label("Interviewer note")
        expect(note).to_be_visible()
        with store.connection(write=True) as db:
            SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=False, actor_email="operator@example.test",
                                           now_iso=store.timestamp())
        note.fill("A stale private entry")
        page.get_by_role("button", name="Save review", exact=True).click()
        expect(page.get_by_role("alert").filter(has_text="protected")).to_be_visible()
        assert "A stale private entry" not in client.get("/api/backups/workspace").raise_for_status().text
        page.on("dialog", lambda dialog: dialog.accept())
        page.reload()
        expect(page.get_by_text("Retention anonymized this interview.", exact=False)).to_be_visible()
        region = page.get_by_role("region", name="Retained exchange")
        expect(region).to_contain_text("Why this approach?")
        expect(region).to_contain_text(REDACTED_TEXT)
        expect(page.get_by_role("button", name="Reports", exact=True)).to_be_enabled()
        expect(page.get_by_label("Interviewer note")).to_have_count(0)
        expect(page.get_by_role("button", name="Save assignment", exact=True)).to_have_count(0)
        expect(page.get_by_role("button", name="Add exchange", exact=True)).to_have_count(0)
        expect(page.get_by_role("button", name="Add handoff note", exact=True)).to_have_count(0)
        expect(page.get_by_role("heading", name="Saved grades")).to_be_visible()
