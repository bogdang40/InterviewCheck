import httpx
import pytest
from playwright.sync_api import expect


@pytest.mark.parametrize(("weights", "expected"), [((11, 5), "26.2%"), ((13, 3), "23.8%")])
def test_live_and_saved_scores_show_the_same_tenth(workspace_url, browser_page, weights, expected):
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        criteria = [
            {"id": "first", "criterion": "First", "weight": weights[0]},
            {"id": "second", "criterion": "Second", "weight": weights[1]},
            {"id": "extra", "criterion": "Optional", "weight": 100},
        ]
        role = client.post("/api/roles", json={"name": "Engineer", "policy": "Notes allowed.", "rubric": criteria}).raise_for_status().json()
        sid = client.post("/api/sessions", json={"candidate": "Rounding fixture", "role": role["name"],
                          "role_id": role["id"], "consent": True}).raise_for_status().json()["id"]
    page = browser_page
    page.goto(f"{workspace_url}/interviews/review/?id={sid}")
    badge = page.get_by_test_id("scorecard-weighted-badge")
    expect(badge).to_have_text("Score: Ungraded")
    page.get_by_role("button", name="Rate First 1 of 5").click()
    page.get_by_role("button", name="Rate Second 2 of 5").click()
    expect(badge).to_have_text("Score: " + expected)
    page.get_by_role("button", name="Save scorecard", exact=True).click()
    expect(page.get_by_role("status").filter(has_text="Scorecard saved.")).to_be_visible()
    page.reload()
    expect(badge).to_have_text("Score: " + expected)
