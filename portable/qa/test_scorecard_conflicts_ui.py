import httpx
from playwright.sync_api import expect


def open_scorecard(client, page, url):
    rubric = [{"id": key, "criterion": key.title()} for key in ("design", "testing", "communication")]
    role = client.post("/api/roles", json={"name": "Review engineer", "policy": "Manual permitted.",
                                           "rubric": rubric}).raise_for_status().json()
    session = client.post("/api/sessions", json={"candidate": "Fixture", "role": role["name"], "role_id": role["id"],
                                                  "consent": True}).raise_for_status().json()
    sid = session["id"]
    page.goto(f"{url}/interviews/review/?id={sid}")
    panel = page.get_by_label("Session scorecard panel")
    expect(panel.get_by_role("button", name="Rate Design 1 of 5")).to_be_visible()
    return panel, f"/api/sessions/{sid}/scorecard"


def item(key, rating, rationale):
    return {"criterion_id": key, "criterion_label": key.title(), "weight": 1, "rating": rating, "rationale": rationale}


def change_saved(client, path, rows):
    version = client.get(path).raise_for_status().json()["version"]
    return client.put(path, json={"items": rows, "expected_version": version}).raise_for_status().json()


def test_scorecard_refresh_merges_disjoint_edits_and_requires_each_overlap_choice(workspace_url, browser_page):
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        panel, path = open_scorecard(client, browser_page, workspace_url)
        save = panel.get_by_role("button", name="Save scorecard", exact=True)
        panel.get_by_role("button", name="Rate Design 3 of 5").click()
        panel.get_by_label("Rationale for Design").fill("My design rationale.")
        handoff = panel.get_by_label("Handoff note", exact=True)
        handoff.fill("Unposted handoff.")
        theirs = item("testing", 4, "Saved by the second reviewer.")
        change_saved(client, path, [theirs])
        save.click()
        expect(panel.get_by_text("Saved scores refreshed. Review the combined scorecard before saving.")).to_be_visible()
        expect(panel.get_by_label("Rationale for Testing")).to_have_value(theirs["rationale"])
        expect(handoff).to_have_value("Unposted handoff.")
        assert client.get(path).json()["items"][0]["rating"] is None
        save.click()
        expect(panel.get_by_text("Scorecard saved.", exact=True)).to_be_visible()
        assert [r["rating"] for r in client.get(path).json()["items"]] == [3, 4, None]

        panel.get_by_role("button", name="Rate Design 5 of 5").click()
        panel.get_by_role("button", name="Rate Testing 1 of 5").click()
        panel.get_by_label("Rationale for Testing").fill("My new testing rationale.")
        second_design = item("design", 2, "Current design feedback.")
        second_testing = item("testing", 2, "Current testing feedback.")
        change_saved(client, path, [second_design, second_testing])
        save.click()
        design = panel.get_by_role("group", name="Resolve changes to Design")
        testing = panel.get_by_role("group", name="Resolve changes to Testing")
        expect(design.get_by_text(second_design["rationale"])).to_be_visible()
        expect(design.get_by_text("My design rationale.")).to_be_visible()
        expect(testing.get_by_text(second_testing["rationale"])).to_be_visible()
        expect(testing.get_by_text("My new testing rationale.")).to_be_visible()
        expect(design.get_by_role("button", name="Use saved score")).to_be_focused()
        expect(save).to_be_disabled()
        design.get_by_role("button", name="Use saved score").press("Enter")
        expect(save).to_be_disabled()
        testing.get_by_role("button", name="Keep my draft").press("Enter")
        expect(save).to_be_focused()
        assert [r["rating"] for r in client.get(path).json()["items"]] == [2, 2, None]
        save.click()
        expect(panel.get_by_text("Scorecard saved.", exact=True)).to_be_visible()
        result = client.get(path).raise_for_status().json()
        assert [(r["rating"], r["rationale"]) for r in result["items"][:2]] == [
            (2, second_design["rationale"]), (1, "My new testing rationale."),
        ]
        assert result["handoff_notes"] == []
        expect(handoff).to_have_value("Unposted handoff.")
        handoff.fill("")


def test_scorecard_incomplete_edits_keep_focus_and_can_be_discarded(workspace_url, browser_page):
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        panel, path = open_scorecard(client, browser_page, workspace_url)
        save = panel.get_by_role("button", name="Save scorecard", exact=True)
        panel.get_by_role("button", name="Rate Design 4 of 5").click()
        rationale = panel.get_by_label("Rationale for Testing")
        rationale.fill("Keep this pending observation.")
        save.click()
        expect(panel.get_by_role("button", name="Rate Testing 1 of 5")).to_be_focused()
        expect(rationale).to_have_value("Keep this pending observation.")
        assert all(r["rating"] is None for r in client.get(path).json()["items"])
        panel.get_by_role("button", name="Rate Testing 3 of 5").click()
        new = panel.get_by_label("Add criterion", exact=True)
        new.fill("Extra criterion")
        panel.get_by_role("button", name="Add criterion", exact=True).click()
        save.click()
        expect(panel.get_by_role("button", name="Rate Extra criterion 1 of 5")).to_be_focused()
        panel.get_by_role("button", name="Discard new criterion Extra criterion").click()
        new.fill("Unadded entry")
        save.click()
        expect(new).to_be_focused()
        panel.get_by_role("button", name="Discard entry").click()
        save.click()
        expect(panel.get_by_text("Scorecard saved.", exact=True)).to_be_visible()
        rows = client.get(path).raise_for_status().json()["items"]
        assert [r["rating"] for r in rows] == [4, 3, None]
        assert rows[1]["rationale"] == "Keep this pending observation."
