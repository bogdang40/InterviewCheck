"""Page through assignments and verify exactly which interview a bulk change affects."""
from datetime import datetime, timedelta, timezone
import re
from urllib.parse import parse_qs, urlparse

import httpx
from playwright.sync_api import expect


def test_due_soon_pages_preserve_archive_filters_and_limit_bulk_updates(workspace_url, browser_page):
    page = browser_page
    deadline = datetime.now(timezone.utc) + timedelta(hours=12)
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sessions = []
        for i in range(13):
            session = client.post("/api/sessions", json={
                "candidate": f"Queue fixture {i:02d}", "role": "Engineer",
                "consent": True, "policy": "Reference manuals permitted.",
            })
            session.raise_for_status()
            sid = session.json()["id"]
            client.put(f"/api/sessions/{sid}/assignment", json={
                "assignee_email": "reviewer@example.test",
                "due_at": (deadline + timedelta(minutes=i)).isoformat(),
            }).raise_for_status()
            sessions.append(sid)

        page.goto(workspace_url + "/interviews/?q=Engineer&sort=candidate")
        queue = page.get_by_role("region", name="Assignment queues")
        queue.get_by_role("button", name=re.compile("^Due soon")).click()
        expect(queue.get_by_role("status")).to_have_text("1 to 12 of 13 assignments")
        queue.get_by_role("checkbox", name="Select Queue fixture 00 for bulk assignment").check()
        forward = queue.get_by_role("button", name="Next assignments")
        forward.focus()
        page.keyboard.press("Enter")
        expect(queue.get_by_role("status")).to_have_text("13 to 13 of 13 assignments")
        expect(queue.get_by_role("status")).to_be_focused()
        expect(queue.get_by_role("button", name="Clear selected assignments")).to_be_disabled()
        expect(queue.get_by_role("checkbox")).to_have_count(1)

        queue.get_by_role("link", name=re.compile("Queue fixture 12")).click()
        expect(page.get_by_role("heading", name="Queue fixture 12")).to_be_visible()
        page.go_back()
        expect(queue.get_by_role("status")).to_have_text("13 to 13 of 13 assignments")
        query = parse_qs(urlparse(page.url).query)
        assert query == {"q": ["Engineer"], "sort": ["candidate"], "queue": ["soon"], "queue_page": ["2"]}
        page.set_viewport_size({"width": 320, "height": 780})
        assert queue.evaluate("(el) => el.scrollWidth <= el.clientWidth")
        queue.get_by_role("button", name="Select visible").click()
        queue.get_by_role("button", name="Clear selected assignments").click()
        expect(queue.get_by_text("1 to 12 of 12 assignments", exact=True)).to_be_visible()
        expect(queue.get_by_text("Cleared assignments for 1 session.", exact=True)).to_be_visible()
        assert "queue_page" not in parse_qs(urlparse(page.url).query)
        for sid in sessions[:-1]:
            assert client.get(f"/api/sessions/{sid}/assignment").json()["assignment"]["assignee_email"] == "reviewer@example.test"
        assert client.get(f"/api/sessions/{sessions[-1]}/assignment").json()["assignment"] is None
