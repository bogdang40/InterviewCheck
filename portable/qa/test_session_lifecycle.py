"""Verify the review workflow through canonical and original shared URLs."""
import re

import httpx
from playwright.sync_api import expect


def test_role_snapshot_pending_exports_and_finish(workspace_url, browser_page, pytestconfig):
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        roles = []
        for team in ("Alpha", "Beta"):
            role = {"name": "Engineer", "description": team + " rotation", "questions": [team + " scenario?"]}
            saved = client.post("/api/roles", json=role)
            saved.raise_for_status()
            roles.append(saved.json())
        page = browser_page
        page.goto(workspace_url + "/#roles")
        # The development server compiles the roles page on its first visit.
        redirect_timeout = 30_000 if pytestconfig.getoption("--frontend") == "dev" else None
        expect(page).to_have_url(re.compile(r"/roles/?$"), timeout=redirect_timeout)
        page.get_by_text("Beta rotation", exact=True).locator("..").locator("..").get_by_role("button", name="Prepare").click()
        expect(page.get_by_label("Saved role template")).to_have_value(roles[1]["id"])
        page.get_by_label("Candidate", exact=True).fill("Workflow fixture")
        page.get_by_label("Assistance policy").fill("Documentation is allowed.")
        page.get_by_role("checkbox").check()
        page.get_by_role("button", name="Start interview").click()
        expect(page).to_have_url(re.compile(r"/interviews/review/\?id=[0-9a-f-]+$"))
        key = page.url.split("id=")[1]
        updated = client.put("/api/roles/" + roles[1]["id"], json={
            "name": "Engineer", "description": "Team update", "questions": ["Updated scenario?"],
        })
        updated.raise_for_status()
        page.reload()
        choices = page.get_by_label("Planned question")
        expect(choices).to_be_visible()
        assert choices.locator("option").all_text_contents() == ["Choose a question", "Beta scenario?"]
        choices.select_option(label="Beta scenario?")
        page.get_by_role("textbox", name="Candidate answer").fill("I would inspect a trace before opening the file.")
        page.get_by_role("button", name="Add source").click()
        page.get_by_label("Source name").fill("Example reference")
        page.get_by_label("Source passage").fill("I would inspect a trace before opening the file.")
        summary = page.get_by_text("Live comparison", exact=True)
        summary.click()
        preview = summary.locator("..")
        expect(preview.get_by_text("Passage match", exact=True)).to_be_visible()
        page.get_by_label("Permitted material").check()
        expect(preview.get_by_text("Limited evidence", exact=True)).to_be_visible()
        assert client.get("/api/sessions/" + key).json()["answer_count"] == 0
        page.get_by_label("Permitted material").uncheck()
        expect(page.get_by_role("button", name="Export report")).to_be_disabled()
        expect(page.get_by_role("button", name="Finish interview")).to_be_disabled()
        page.get_by_role("button", name="Save and compare").click()
        expect(page.get_by_role("link", name="Export report")).to_be_visible()
        context_note = "The candidate explained the first assumption."
        page.get_by_label("Interviewer note").fill(context_note)
        expect(page.get_by_role("button", name="Export report")).to_be_disabled()
        expect(page.get_by_role("link", name="Export report")).to_have_count(0)
        page.once("dialog", lambda dialog: dialog.dismiss())
        page.get_by_role("navigation", name="Workspace").get_by_role("link", name="Interviews", exact=True).click()
        expect(page.get_by_label("Interviewer note")).to_have_value(context_note)
        page.get_by_role("button", name="Save review").click()
        first_answer, = client.get("/api/sessions/" + key).json()["answers"]
        page.get_by_role("button", name="Ask this follow up").click()
        expect(page.get_by_role("textbox", name="Question", exact=True)).to_have_value(first_answer["result"]["follow_up"])
        page.get_by_role("button", name="Cancel", exact=True).click()
        page.get_by_role("button", name="Finish interview").click()
        expect(page.get_by_role("button", name="Reopen interview")).to_be_visible()
        expect(page.get_by_role("button", name="Add exchange")).to_have_count(0)
        finished = client.get("/api/sessions/" + key).json()
        assert finished["ended_at"] and finished["role_id"] == roles[1]["id"]
        assert finished["planned_questions"] == ["Beta scenario?"]
        closed = client.post("/api/sessions/" + key + "/answers", json={
            "question": "More?", "answer": "A later answer outside the completed meeting.",
        })
        assert closed.status_code == 409
        page.goto(workspace_url + "/#session/" + key)
        expect(page).to_have_url(re.compile(r"/interviews/review/\?id=" + key + "$"))
        page.get_by_role("button", name="Reopen interview").click()
        expect(page.get_by_role("button", name="Add exchange")).to_be_visible()
        assert client.get("/api/sessions/" + key).json()["ended_at"] is None
