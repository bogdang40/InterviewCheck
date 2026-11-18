import re

import httpx
from playwright.sync_api import expect


def test_archive_filters_return_to_the_same_results_and_keyboard_link(workspace_url, browser_page, tmp_path):
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        settings = {
            "candidate": "Archive target",
            "role": "Network engineer",
            "policy": "Public sources only.",
            "consent": True,
        }
        sid = client.post("/api/sessions", json=settings).json()["id"]
        source = "The sender buffers telemetry records until the collector releases an acknowledgment."
        item = client.post(
            f"/api/sessions/{sid}/answers",
            json={
                "question": "Why buffer the stream?",
                "answer": source,
                "references": [{"label": "Design note", "text": source}],
            },
        ).json()
        client.post(f"/api/sessions/{sid}/finish").raise_for_status()
        for i in range(7):
            client.post("/api/sessions", json={**settings, "candidate": f"Recent {i}"}).raise_for_status()

    page = browser_page
    hydration = []
    page.on(
        "console",
        lambda msg: (
            hydration.append(msg.text[:150]) if msg.type == "error" and "hydrat" in msg.text.lower() else None
        ),
    )
    page.goto(workspace_url)
    queue = page.get_by_role("region", name="Review queue")
    link = queue.get_by_role("link", name="Review Archive target", exact=True)
    expect(link).to_have_attribute("href", f"/interviews/review/?id={sid}&answer={item['id']}")
    expect(link).to_have_accessible_description(re.compile(r"Network engineer.*Finished.*1 pending"))
    page.screenshot(path=tmp_path / "queue-desktop.png", full_page=True)
    assert not hydration
    page.get_by_role("link", name="View all pending").click()
    filters = [("Capture status", "finished"), ("Sort interviews", "oldest")]
    for label, value in filters:
        page.get_by_label(label).select_option(value)
    page.get_by_role("searchbox", name="Search interviews").press_sequentially("ARCHIVE network")
    page.wait_for_url(re.compile(r".*q=ARCHIVE\+network.*"))
    expect(page.get_by_role("status").filter(has_text="1 of 8 shown")).to_be_visible()
    result = page.get_by_role("link", name="Review Archive target", exact=True)
    result.focus()
    page.keyboard.press("Enter")
    expect(page).to_have_url(re.compile(re.escape(f"/interviews/review/?id={sid}&answer={item['id']}")))
    page.go_back()
    expect(page.get_by_role("searchbox", name="Search interviews")).to_have_value("ARCHIVE network")
    expect(page.get_by_label("Evidence review")).to_have_value("pending")
    expect(page.get_by_label("Capture status")).to_have_value("finished")
    expect(page.get_by_label("Sort interviews")).to_have_value("oldest")
    page.set_viewport_size({"width": 320, "height": 850})
    expect(page.get_by_role("heading", name="All interviews")).to_be_visible()
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    page.screenshot(path=tmp_path / "archive-mobile.png", full_page=True)
    page.get_by_role("button", name="Clear filters").click()
    expect(page.get_by_role("status").filter(has_text="8 of 8 shown")).to_be_visible()


def test_archive_page_is_bounded_and_role_deep_link_focuses_its_record(workspace_url, browser_page):
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        rid = client.post(
            "/api/roles", json={"name": "Timing verifier", "questions": ["How do clocks drift?"]}
        ).json()["id"]
        for i in range(28):
            client.post(
                "/api/sessions",
                json={
                    "candidate": f"Case {i:02}",
                    "role": "Research",
                    "consent": True,
                    "policy": "Notes permitted.",
                },
            ).raise_for_status()
        page = browser_page
        page.goto(workspace_url + "/interviews/?sort=candidate")
        rows = page.get_by_role("list").get_by_role("link")
        expect(rows).to_have_count(25)
        page.get_by_role("button", name="Next page").click()
        expect(rows).to_have_count(3)
        expect(rows.first).to_have_accessible_name("Open Case 25")
        rows.first.click()
        expect(page.get_by_role("heading", name="Case 25")).to_be_visible()
        page.go_back()
        expect(page).to_have_url(re.compile(r"page=2"))
        expect(rows).to_have_count(3)
        page.get_by_role("searchbox", name="Search interviews").fill("Case 07")
        expect(rows).to_have_count(1)
        expect(rows.first).to_have_accessible_name("Open Case 07")
        page.goto(workspace_url + "/roles/?role=" + rid)
        expect(page.get_by_role("heading", name="Timing verifier")).to_be_focused()
        expect(page.get_by_text("1. How do clocks drift?")).to_be_visible()
