import httpx
import pytest
from playwright.sync_api import expect


def grade(cid, label, weight, rating, rationale):
    return {"criterion_id": cid, "criterion_label": label, "weight": weight, "rating": rating, "rationale": rationale}


def new_session(client):
    role = client.post("/api/roles", json={"name": "Engineer", "policy": "Manual permitted", "rubric": [
        {"id": "system", "criterion": "Current template wording", "weight": 2},
    ]}).raise_for_status().json()
    session = client.post("/api/sessions", json={"candidate": "Fixture", "role": role["name"],
                                                "role_id": role["id"], "consent": True}).raise_for_status().json()
    return session["id"], f"/api/sessions/{session['id']}/scorecard"


def save_remote(client, path, scores):
    version = client.get(path).raise_for_status().json()["version"]
    return client.put(path, json={"items": scores, "expected_version": version}).raise_for_status().json()


def test_removal_is_reversible_and_last_grade_can_be_cleared(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path = new_session(client)
        system = grade("system", "Earlier wording", 8, 4, "Saved rationale")
        custom = grade("custom", "Custom criterion", 1, 5, "Custom rationale")
        save_remote(client, path, [system, custom])
        page.goto(f"{workspace_url}/interviews/review/?id={sid}")
        panel = page.get_by_label("Session scorecard panel")
        rationale = panel.get_by_label("Rationale for Earlier wording")
        rationale.fill("Locally edited rationale\nwith evidence")
        remove = panel.get_by_role("button", name="Remove saved rating for Earlier wording")
        remove.click()
        undo = panel.get_by_role("button", name="Undo removal of Earlier wording")
        expect(undo).to_be_focused()
        expect(page.get_by_test_id("scorecard-weighted-badge")).to_have_text("Score: 100.0%")
        undo.press("Enter")
        expect(remove).to_be_focused()
        expect(rationale).to_have_value("Locally edited rationale\nwith evidence")
        expect(panel.get_by_role("button", name="Rate Earlier wording 4 of 5")).to_have_attribute("aria-pressed", "true")
        remove.click()
        panel.get_by_role("button", name="Remove saved rating for Custom criterion").click()
        expect(page.get_by_test_id("scorecard-weighted-badge")).to_have_text("Score: Ungraded")
        assert [r["rationale"] for r in client.get(path).json()["items"]] == ["Saved rationale", "Custom rationale"]
        with page.expect_response(lambda r: r.request.method == "PUT" and r.url.endswith(path)) as complete:
            panel.get_by_role("button", name="Save scorecard", exact=True).click()
        assert complete.value.ok and complete.value.request.post_data_json["items"] == []
        expect(panel.get_by_text("Scorecard saved.", exact=True)).to_be_visible()
        page.reload(wait_until="domcontentloaded")
        expect(panel.get_by_label("Rationale for Current template wording")).to_have_value("")
        expect(panel.get_by_role("button", name="Rate Current template wording 4 of 5")).to_have_attribute("aria-pressed", "false")
        expect(panel.get_by_text("Custom criterion", exact=True)).to_have_count(0)
        state = client.get(path).raise_for_status().json()
        assert state["weighted_score_pct"] is None
        assert [(r["criterion_id"], r["weight"], r["rating"], r["rationale"]) for r in state["items"]] == [
            ("system", 2, None, ""),
        ]


def test_concurrent_score_correction_requires_choice_and_keeps_new_grade(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path = new_session(client)
        original = grade("system", "Saved design", 3, 4, "First reviewer.")
        save_remote(client, path, [original])
        page.goto(f"{workspace_url}/interviews/review/?id={sid}")
        panel = page.get_by_label("Session scorecard panel")
        save = panel.get_by_role("button", name="Save scorecard", exact=True)
        remove = panel.get_by_role("button", name="Remove saved rating for Saved design")
        remove.click()
        unrelated = grade("extra", "New grade", 1, 5, "Independent reviewer.")
        changed = {**original, "rating": 3, "rationale": "Edited by reviewer B."}
        save_remote(client, path, [changed, unrelated])
        save.click()
        conflict = panel.get_by_role("group", name="Resolve changes to Saved design")
        expect(conflict.get_by_text("Edited by reviewer B.")).to_be_visible()
        expect(conflict.get_by_text("Remove the rating and rationale.")).to_be_visible()
        expect(save).to_be_disabled()
        conflict.get_by_role("button", name="Use saved score").click()
        expect(panel.get_by_label("Rationale for Saved design")).to_have_value("Edited by reviewer B.")
        remove.click()
        changed["rationale"] = "Another remote correction."
        before = save_remote(client, path, [changed, unrelated])
        save.click()
        expect(conflict.get_by_text("Another remote correction.")).to_be_visible()
        conflict.get_by_role("button", name="Keep removal").press("Enter")
        expect(save).to_be_focused()
        assert client.get(path).json()["version"] == before["version"]
        save.click()
        expect(panel.get_by_text("Scorecard saved.", exact=True)).to_be_visible()
        after = client.get(path).raise_for_status().json()
        assert after["items"][0]["rating"] is None and after["items"][0]["rationale"] == ""
        assert after["items"][1] == before["items"][1]


def test_already_cleared_remote_scores_resolve_without_reposting(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path = new_session(client)
        save_remote(client, path, [grade("system", "Scored", 7, 5, "Graded"), grade("extra", "Ad hoc", 1, 2, "")])
        page.goto(f"{workspace_url}/interviews/review/?id={sid}")
        panel = page.get_by_label("Session scorecard panel")
        for title in ("Scored", "Ad hoc"):
            panel.get_by_role("button", name=f"Remove saved rating for {title}").click()
        current = save_remote(client, path, [])
        panel.get_by_role("button", name="Save scorecard", exact=True).click()
        expect(panel.get_by_text("The saved scorecard already reflects your changes.")).to_be_visible()
        expect(panel.get_by_label("Rationale for Current template wording")).to_have_value("")
        expect(panel.get_by_text("Ad hoc", exact=True)).to_have_count(0)
        expect(panel.get_by_role("button", name="Keep removal")).to_have_count(0)
        assert client.get(path).json()["version"] == current["version"]


def test_removing_last_visible_score_keeps_a_concurrent_new_rating(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path = new_session(client)
        original = grade("system", "Design", 3, 3, "Initial review")
        save_remote(client, path, [original])
        page.goto(f"{workspace_url}/interviews/review/?id={sid}")
        panel = page.get_by_label("Session scorecard panel")
        panel.get_by_role("button", name="Remove saved rating for Design").click()
        late = grade("new", "Remote addition", 2, 4, "Second review")
        latest = save_remote(client, path, [original, late])
        save = panel.get_by_role("button", name="Save scorecard", exact=True)
        save.click()
        expect(panel.get_by_text("Saved scores refreshed. Review the combined scorecard before saving.")).to_be_visible()
        expect(panel.get_by_role("button", name="Undo removal of Design")).to_be_visible()
        expect(panel.get_by_role("button", name="Keep removal")).to_have_count(0)
        expect(page.get_by_test_id("scorecard-weighted-badge")).to_have_text("Score: 80.0%")
        assert client.get(path).json()["version"] == latest["version"]
        save.click()
        expect(panel.get_by_text("Scorecard saved.", exact=True)).to_be_visible()
        after = client.get(path).raise_for_status().json()
        assert after["items"][0]["rating"] is None
        assert after["items"][1] == latest["items"][1]


@pytest.mark.parametrize("choice", [None, "Use saved score", "Keep my draft"])
def test_undo_after_keep_removal_cannot_reintroduce_stale_rationale(workspace_url, browser_page, choice):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path = new_session(client)
        original = grade("system", "Design", 3, 4, "First reviewer.")
        save_remote(client, path, [original])
        page.goto(f"{workspace_url}/interviews/review/?id={sid}")
        panel = page.get_by_label("Session scorecard panel")
        reason = panel.get_by_label("Rationale for Design")
        if choice:
            reason.fill("My pending edit.")
        panel.get_by_role("button", name="Remove saved rating for Design").click()
        current = save_remote(client, path, [{**original, "rating": 5, "rationale": "Second reviewer."}])
        save = panel.get_by_role("button", name="Save scorecard", exact=True)
        save.click()
        conflict = panel.get_by_role("group", name="Resolve changes to Design")
        conflict.get_by_role("button", name="Keep removal").click()
        panel.get_by_role("button", name="Undo removal of Design").click()
        if choice:
            expect(conflict.get_by_text("Second reviewer.")).to_be_visible()
            expect(conflict.get_by_text("My pending edit.")).to_be_visible()
            expect(save).to_be_disabled()
            conflict.get_by_role("button", name=choice).press("Enter")
        else:
            expect(conflict).to_have_count(0)
        assert client.get(path).json()["version"] == current["version"]
        expected = (4, "My pending edit.") if choice == "Keep my draft" else (5, "Second reviewer.")
        expect(reason).to_have_value(expected[1])
        expect(panel.get_by_role("button", name=f"Rate Design {expected[0]} of 5")).to_have_attribute("aria-pressed", "true")
        save.click()
        expect(panel.get_by_text("Scorecard saved.", exact=True)).to_be_visible()
        row, = client.get(path).json()["items"]
        assert (row["rating"], row["rationale"]) == expected
