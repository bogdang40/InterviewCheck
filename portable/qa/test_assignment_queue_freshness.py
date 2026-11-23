"""Automatic queue refresh preserves an operator's selection, draft and keyboard focus."""
from datetime import datetime, timedelta, timezone
import re
from urllib.parse import parse_qs, urlsplit

import httpx
from playwright.sync_api import expect


def create(client, name):
    sid = client.post("/api/sessions", json={
        "candidate": name, "role": "Engineer", "consent": True, "policy": "Reference allowed.",
    }).raise_for_status().json()["id"]
    path = f"/api/sessions/{sid}/assignment"
    client.put(path, json={"assignee_email": "reviewer@example.test", "priority": "high"}).raise_for_status()
    return sid, path


def test_deadline_refresh_moves_an_idle_row_and_returns_removed_focus(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        _, path = create(client, "Deadline refresh")
        page.goto(workspace_url + "/interviews/?queue=soon")
        queue = page.get_by_role("region", name="Assignment queues")
        empty = queue.get_by_text("No sessions in this assignment queue.", exact=True)
        expect(empty).to_be_visible()
        due = datetime.now(timezone.utc) + timedelta(seconds=4)
        client.put(path, json={"assignee_email": "reviewer@example.test", "priority": "high", "due_at": due.isoformat()}).raise_for_status()
        queue.get_by_role("button", name="Refresh queue").click()
        link = queue.get_by_role("link", name=re.compile("Deadline refresh"))
        expect(link).to_be_visible()
        link.focus()
        expect(empty).to_be_focused(timeout=12_000)
        expect(link).to_have_count(0)
        expect(queue.get_by_role("button", name=re.compile(r"^Overdue\s+1$"))).to_be_visible()
        expect(queue.get_by_role("button", name=re.compile(r"^Due soon\s+0$"))).to_be_visible()


def test_late_background_refresh_freezes_selection_and_keeps_focus(workspace_url, browser_page):
    page = browser_page
    page.add_init_script("""
      const original = window.fetch.bind(window);
      window.fetch = async (input, init) => {
        const url = new URL(input instanceof Request ? input.url : input, location.href);
        if (url.pathname !== "/api/interviews/assignments" || !window.holdQueueRead) return original(input, init);
        window.holdQueueRead = false;
        const response = await original(input, {...init, signal: undefined});
        await response.clone().text();
        await new Promise(resolve => {
          document.documentElement.dataset.queueHeld = "true";
          document.addEventListener("release-held-queue", resolve, {once:true});
        });
        return response;
      };
    """)
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        _, path = create(client, "Selected before reply")
        create(client, "Still in queue")
        page.goto(workspace_url + "/interviews/?queue=high")
        queue = page.get_by_role("region", name="Assignment queues")
        selected = queue.get_by_role("checkbox", name="Select Selected before reply for bulk assignment")
        expect(selected).to_be_visible()
        client.delete(path).raise_for_status()
        page.evaluate("() => { window.holdQueueRead = true; window.dispatchEvent(new Event('pageshow')); }")
        expect(page.locator("html")).to_have_attribute("data-queue-held", "true")
        selected.check()
        email = queue.get_by_label("Bulk assignee email")
        email.fill("proposed@example.test")
        page.evaluate("document.dispatchEvent(new Event('release-held-queue'))")
        notice = queue.get_by_role("status").filter(has_text="Queue may have changed")
        expect(notice).to_be_visible()
        expect(selected).to_be_checked()
        expect(email).to_be_focused()
        expect(email).to_have_value("proposed@example.test")
        queue.get_by_role("button", name="Refresh and reselect").click()
        expect(selected).to_have_count(0)
        expect(queue.get_by_role("navigation", name="Assignment queue pages").get_by_role("status")).to_be_focused()
        expect(notice).to_have_count(0)
        queue.get_by_role("checkbox", name="Select Still in queue for bulk assignment").check()
        expect(email).to_have_value("proposed@example.test")


def test_background_error_keeps_rows_and_other_tab_save_refreshes_queue(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, _ = create(client, "Cross tab reviewer")
        page.goto(workspace_url + "/interviews/?queue=high")
        queue = page.get_by_role("region", name="Assignment queues")
        link = queue.get_by_role("link", name=re.compile("Cross tab reviewer"))
        expect(link).to_be_visible()
        link.focus()
        page.route("**/api/interviews/assignments?*", lambda route: route.fulfill(status=503, json={"detail": "Read unavailable."}))
        page.evaluate("window.dispatchEvent(new Event('pageshow'))")
        expect(queue.get_by_text("Could not refresh the queue. Read unavailable.", exact=True)).to_be_visible()
        expect(link).to_be_focused()
        page.unroute("**/api/interviews/assignments?*")

        other = page.context.new_page()
        try:
            other.goto(f"{workspace_url}/interviews/review/?id={sid}")
            form = other.get_by_role("region", name="Session assignment")
            form.get_by_label("Assignee email").fill("updated@example.test")
            form.get_by_role("button", name="Save assignment").click()
            expect(form.get_by_role("status")).to_contain_text("Assigned to updated@example.test")
            page.bring_to_front()
            expect(link).to_contain_text("updated@example.test")
            expect(queue.get_by_text("Could not refresh the queue.", exact=False)).to_have_count(0)
        finally:
            other.close()


def test_deselecting_last_row_resumes_one_deferred_refresh(workspace_url, browser_page):
    page = browser_page
    reads = []
    page.on("request", lambda req: reads.append(req.url) if urlsplit(req.url).path == "/api/interviews/assignments" else None)
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        _, path = create(client, "Resume reviewer")
        page.goto(workspace_url + "/interviews/?queue=high")
        queue = page.get_by_role("region", name="Assignment queues")
        box = queue.get_by_role("checkbox", name="Select Resume reviewer for bulk assignment")
        box.check()
        queue.get_by_label("Bulk assignee email").fill("retained@example.test")
        count = len(reads)
        client.put(path, json={"assignee_email": "fresh@example.test", "priority": "high"}).raise_for_status()
        page.evaluate("() => { for (let i=0; i<5; i++) window.dispatchEvent(new Event('pageshow')); }")
        notice = queue.get_by_role("status").filter(has_text="Queue may have changed")
        expect(notice).to_have_count(1)
        assert len(reads) == count
        box.uncheck()
        expect(queue.get_by_role("link", name=re.compile("Resume reviewer"))).to_contain_text("fresh@example.test")
        expect(notice).to_have_count(0)
        assert len(reads) == count + 1
        box.check()
        expect(queue.get_by_label("Bulk assignee email")).to_have_value("retained@example.test")


def test_background_page_clamp_returns_removed_pager_focus(workspace_url, browser_page):
    page = browser_page
    reads = []
    page.on("request", lambda req: reads.append(req.url) if urlsplit(req.url).path == "/api/interviews/assignments" else None)
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        for number in range(13):
            create(client, f"Pager fixture {number}")
        page.goto(workspace_url + "/interviews/?queue=high&queue_page=2")
        queue = page.get_by_role("region", name="Assignment queues")
        row = queue.get_by_role("link", name=re.compile("Pager fixture"))
        expect(row).to_have_count(1)
        sid = parse_qs(urlsplit(row.get_attribute("href")).query)["id"][0]
        pager = queue.get_by_role("button", name="Previous assignments")
        pager.focus()
        expect(pager).to_be_focused()
        count = len(reads)
        client.delete(f"/api/sessions/{sid}/assignment").raise_for_status()
        page.evaluate("window.dispatchEvent(new Event('pageshow'))")
        expect(queue.get_by_text("1 to 12 of 12 assignments", exact=True)).to_be_focused()
        expect(pager).to_have_count(0)
        assert "queue_page" not in parse_qs(urlsplit(page.url).query)
        assert len(reads) == count + 1


def test_denied_background_read_clears_private_rows_and_selection(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        create(client, "Private queue fixture")
    page.goto(workspace_url + "/interviews/?queue=high")
    queue = page.get_by_role("region", name="Assignment queues")
    box = queue.get_by_role("checkbox", name="Select Private queue fixture for bulk assignment")
    expect(box).to_be_visible()
    pending = []
    page.route("**/api/interviews/assignments?*", lambda route: pending.append(route))
    with page.expect_request(lambda req: urlsplit(req.url).path == "/api/interviews/assignments"):
        page.evaluate("window.dispatchEvent(new Event('pageshow'))")
    box.check()
    email = queue.get_by_label("Bulk assignee email")
    email.fill("private-draft@example.test")
    pending[0].fulfill(status=403, json={"detail": "Fixture access denied."})
    expect(queue.get_by_role("alert")).to_contain_text("Fixture access denied.")
    expect(queue.get_by_role("link", name="Account")).to_be_visible()
    expect(queue.get_by_role("link", name=re.compile("Private queue fixture"))).to_have_count(0)
    expect(email).to_have_count(0)
    expect(queue.get_by_role("button", name=re.compile(r"^High priority\s*0$"))).to_be_visible()
    page.unroute("**/api/interviews/assignments?*")
    queue.get_by_role("button", name="Retry").click()
    expect(box).not_to_be_checked()
    box.check()
    expect(email).to_have_value("")
