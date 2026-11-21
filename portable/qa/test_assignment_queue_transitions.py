"""A late queue reply cannot make previously selected interviews actionable."""
from datetime import datetime, timedelta, timezone
import re

import httpx
from playwright.sync_api import expect


def test_obsolete_queue_reply_cannot_restore_rows_or_selections(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sessions = {}
        for name in ("Unassigned fixture", "High fixture", "Due fixture", "Trashed fixture"):
            form = {"candidate": name, "role": "Triage", "policy": "Manual allowed.", "consent": True}
            sessions[name] = client.post("/api/sessions", json=form).raise_for_status().json()["id"]
        due = (datetime.now(timezone.utc) + timedelta(hours=12)).isoformat()
        assignments = (
            ("High fixture", "high", None),
            ("Due fixture", "low", due),
            ("Trashed fixture", "high", due),
        )
        for name, priority, deadline in assignments:
            client.put(f"/api/sessions/{sessions[name]}/assignment", json={
                "assignee_email": "example@example.test", "priority": priority, "due_at": deadline,
            }).raise_for_status()
        client.post(f"/api/sessions/{sessions['Trashed fixture']}/trash").raise_for_status()

    # Keep a real high-priority response pending even after the later navigation aborts it.
    page.add_init_script("""
        const realFetch = window.fetch.bind(window)
        window.fetch = async (input, init) => {
          const url = new URL(input instanceof Request ? input.url : input, location.href)
          if (url.pathname !== "/api/interviews/assignments" || url.searchParams.get("priority") !== "high")
            return realFetch(input, init)
          const response = await realFetch(input, { ...init, signal: undefined })
          await response.clone().text()
          await new Promise(resolve => {
            document.addEventListener("release-high-response", resolve, { once: true })
            document.documentElement.dataset.highResponse = "held"
          })
          return response
        }
    """)
    page.goto(workspace_url + "/interviews/?queue=unassigned")
    region = page.get_by_role("region", name="Assignment queues")
    assign = region.get_by_role("button", name="Assign selected")
    region.get_by_role("checkbox", name="Select Unassigned fixture for bulk assignment").check()
    expect(assign).to_be_enabled()
    region.get_by_role("button", name=re.compile("^High priority")).click()
    expect(page.locator("html")).to_have_attribute("data-high-response", "held")
    expect(assign).to_have_count(0)
    region.get_by_role("button", name=re.compile("^Due soon")).click()
    due_row = region.get_by_role("link", name=re.compile("Due fixture"))
    expect(due_row).to_be_visible()
    expect(assign).to_have_count(0)
    page.evaluate("""async () => {
        document.dispatchEvent(new Event("release-high-response"))
        await new Promise(requestAnimationFrame)
    }""")
    expect(due_row).to_be_visible()
    expect(region.get_by_text("High fixture", exact=True)).to_have_count(0)
    expect(region.get_by_text("Trashed fixture", exact=True)).to_have_count(0)
    expect(assign).to_have_count(0)

    region.get_by_role("checkbox", name="Select Due fixture for bulk assignment").check()
    assignee = "new-reviewer@example.test"
    region.get_by_label("Bulk assignee email").fill(assignee)
    assign.click()
    expect(region.get_by_text(f"Assigned 1 session to {assignee}.")).to_be_visible()
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        for name, expected in (("Unassigned fixture", None), ("Due fixture", assignee)):
            result = client.get(f"/api/sessions/{sessions[name]}/assignment").raise_for_status().json()
            email = (result["assignment"] or {}).get("assignee_email")
            assert email == expected
