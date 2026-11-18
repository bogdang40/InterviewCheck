"""A probe and its selected plan slot keep identities when their words change."""

import csv
import io
import httpx
from playwright.sync_api import expect


def test_edited_probe_keeps_parent_through_draft_and_reports(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as c:
        repeated = "Which baseline was different?"
        role = c.post(
            "/api/roles",
            json={"name": "Engineer", "description": "Calibration.", "questions": [repeated, repeated]},
        )
        role.raise_for_status()
        session = c.post(
            "/api/sessions",
            json={
                "candidate": "Lineage fixture",
                "role": "Engineer",
                "role_id": role.json()["id"],
                "policy": "Notes allowed.",
                "consent": True,
            },
        )
        session.raise_for_status()
        sid = session.json()["id"]
        path = "/api/sessions/" + sid
        page.goto(workspace_url + "/interviews/review/?id=" + sid)
        picker = page.get_by_role("combobox", name="Planned question", exact=True)
        picker.select_option("2")
        expect(page.get_by_role("textbox", name="Question", exact=True)).to_have_value(repeated)
        page.get_by_label("Candidate answer").fill("We took another reading from the optical reference.")
        page.get_by_role("button", name="Save and compare").click()
        page.get_by_role("button", name="Ask this follow up").click()
        page.get_by_role("textbox", name="Question", exact=True).fill("What assumption changed the outcome?")
        page.get_by_role("button", name="Save draft", exact=True).click()
        expect(page.get_by_role("button", name="Resume draft")).to_be_visible()
        (parent,) = c.get(path).json()["answers"]
        assert parent["planned_slot"] == 2
        assert c.get(path + "/draft").json()["parent_answer_id"] == parent["id"]
        page.reload()
        page.get_by_role("button", name="Resume draft").click()
        page.get_by_label("Candidate answer").fill("The second measurement was below the control limit.")
        page.get_by_role("button", name="Save and compare").click()
        page.get_by_role("button", name="Parent question 1", exact=True).click()
        expect(page.get_by_role("heading", name=repeated, exact=True)).to_be_visible()
        _, child = c.get(path).json()["answers"]
        assert child["parent_answer_id"] == parent["id"] and child["planned_slot"] is None
        brief = c.get(path + "/brief").json()["markdown"]
        assert repeated not in brief and parent["id"] not in brief
        source = c.get("/api/exports/interviews.csv").content.decode("utf-8-sig")
        rows = list(csv.DictReader(io.StringIO(source)))
        assert rows[1]["Parent exchange ID"] == parent["id"]
        assert rows[0]["Planned slot"] == "2"
        assert (
            "Question origin" in c.get(path + "/report").text
            and "Question origin" in c.get(path + "/print").text
        )
