"""Verify that the grading instructions displayed to the reviewer belong to this interview."""
import httpx
from playwright.sync_api import expect


def test_original_rubric_guides_review_after_the_template_changes(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        rubric = [{"id": "design", "criterion": "System design", "weight": 3,
                   "expected_signals": ["Explains an independent rollback."], "red_flags": ["No verification step."]}]
        role = client.post("/api/roles", json={"name": "Role fixture", "policy": "Manuals", "rubric": rubric}).raise_for_status().json()
        form = {"candidate": "Rubric fixture", "role": role["name"], "role_id": role["id"], "consent": True}
        first = client.post("/api/sessions", json=form).raise_for_status().json()
        updated = client.put("/api/roles/" + role["id"], json={**role, "rubric": []}).raise_for_status().json()
        second = client.post("/api/sessions", json={**form, "role_version": updated["version"]}).raise_for_status().json()
        page.goto(workspace_url + "/interviews/review/?id=" + first["id"])
        summary = page.get_by_text("Rubric at interview start · Role version 1", exact=True)
        expect(summary).to_be_visible()
        summary.focus()
        page.keyboard.press("Enter")
        expect(page.get_by_text("Explains an independent rollback.")).to_be_visible()
        expect(page.get_by_text("No verification step.")).to_be_visible()
        page.get_by_role("button", name="Rate System design 4 of 5").click()
        page.get_by_role("button", name="Save scorecard", exact=True).click()
        expect(page.get_by_text("Scorecard saved.", exact=True)).to_be_visible()
        expect(summary).to_be_visible()
        result = client.get("/api/sessions/" + first["id"] + "/scorecard").raise_for_status().json()
        assert result["weighted_score_pct"] == 80 and result["items"][0]["weight"] == 3
        page.goto(workspace_url + "/interviews/review/?id=" + second["id"])
        expect(page.get_by_text("Rubric at interview start · Role version 2. No criteria were recorded at this revision.")).to_be_visible()
        expect(page.get_by_role("button", name="Rate System design 4 of 5")).to_have_count(0)
