"""The comparison preserves exact counts and prompt attribution in its compact layout."""
import re

import httpx
from playwright.sync_api import expect


def test_compact_counts_and_keyboard_jumps_keep_question_context(workspace_url, browser_page, tmp_path):
    page = browser_page
    planned = "What protects the last confirmed write?"
    asked = "How did you verify that the last write survived?"
    passage = "The oldest active snapshot pins tombstones across every replica until compaction completes."
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        role = client.post("/api/roles", json={
            "name": "Recovery engineer", "questions": [planned],
            "rubric": [{"id": "recovery", "criterion": "Measures recovery", "weight": 1}],
        }).raise_for_status().json()
        ids = [client.post("/api/sessions", json={
            "candidate": candidate, "role": role["name"], "role_id": role["id"], "policy": "Manual permitted.", "consent": True,
        }).raise_for_status().json()["id"] for candidate in ("Ada", "Bea")]
        route = f"/api/sessions/{ids[0]}/answers"
        answer = client.post(route, json={
            "question": planned, "planned_slot": 1, "answer": passage, "references": [{"label": "Reference", "text": passage}],
        }).raise_for_status().json()
        client.patch(f"{route}/{answer['id']}", json={"disposition": "explained", "note": "Verified."}).raise_for_status()
        client.post(f"/api/sessions/{ids[1]}/answers", json={
            "question": asked, "planned_slot": 1, "answer": "I inspected the retention log.",
        }).raise_for_status()

    page.set_viewport_size({"width": 320, "height": 800})
    page.goto(workspace_url + "/interviews/compare/?ids=" + ",".join(ids))
    candidates = page.get_by_role("region", name="Candidates (2)")
    card = candidates.get_by_role("article", name="Ada")
    expect(card.get_by_text(re.compile(r" · 1 answer$"))).to_be_visible()
    expect(card.get_by_text("1 answer with a passage match · 1 explained", exact=True)).to_be_visible()
    expect(candidates.get_by_role("article", name="Bea")).to_contain_text("1 answer with limited evidence · 1 pending disposition")
    details = card.locator("details")
    expect(details.get_by_text("Limited evidence", exact=True)).not_to_be_visible()
    details.locator("summary").focus()
    page.keyboard.press("Enter")
    expect(details.get_by_text("Limited evidence", exact=True)).to_be_visible()
    counts = details.evaluate("(el) => Object.fromEntries([...el.querySelectorAll('dt')].map(term => [term.textContent, Number(term.nextElementSibling.textContent)]))")
    assert counts == {"Passage match": 1, "No passage match": 0, "Limited evidence": 0,
                      "Pending": 0, "Explained": 1, "Unresolved": 0, "Disclosed": 0}
    page.keyboard.press("Enter")
    assert not details.evaluate("(el) => el.open")

    jumps = page.get_by_role("navigation", name="Comparison sections")
    expect(jumps.get_by_role("link", name="Scorecards")).to_have_count(0)
    page.get_by_role("checkbox", name="Include saved scorecards").check()
    jumps.get_by_role("link", name="Scorecards").focus()
    page.keyboard.press("Enter")
    expect(page.get_by_role("heading", name="Saved interview scorecards")).to_be_focused()
    jumps.get_by_role("link", name="Questions").focus()
    page.keyboard.press("Enter")
    heading = page.get_by_role("heading", name="Question-slot matrix")
    expect(heading).to_be_focused()
    expect(heading).to_be_in_viewport(ratio=1)
    matrix = page.get_by_role("table")
    expect(matrix.get_by_text(planned, exact=True)).to_have_count(1)
    row_heading = matrix.get_by_role("rowheader", name="Question 1 " + planned)
    expect(row_heading).to_be_visible()
    cells = matrix.get_by_role("cell")
    expect(cells.nth(0).get_by_text("Ada", exact=True)).to_be_visible()
    expect(cells.nth(0).locator(".status.match")).to_have_text("Passage match")
    expect(cells.nth(1).get_by_text("Bea", exact=True)).to_be_visible()
    expect(cells.nth(1).get_by_text("Recorded question", exact=True)).to_be_visible()
    expect(cells.nth(1)).to_contain_text(asked)
    assert cells.nth(1).get_attribute("headers").split() == [
        row_heading.get_attribute("id"), matrix.get_by_role("columnheader", name="Bea").get_attribute("id")]
    assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
    page.screenshot(path=tmp_path / "comparison-questions-phone.png")
