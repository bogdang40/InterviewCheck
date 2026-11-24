"""A recorded zero and an absent denominator stay distinct on role and cohort dashboards."""
import httpx
from playwright.sync_api import expect


def test_review_denominators_and_frozen_question_labels(workspace_url, browser_page, tmp_path):
    from api import store

    page = browser_page
    old, revised, fallback = "Check the queue.", "Check the journal.", "Recorded historical wording."
    private_answer = "Private calibration answer fixture."
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        role = client.post("/api/roles", json={"name": "Calibration fixture", "questions": [old]}).raise_for_status().json()
        client.post("/api/roles", json={"name": "Empty fixture", "questions": ["Future question?"]}).raise_for_status()
        def session(name, asked, tag):
            sid = client.post("/api/sessions", json={
                "candidate": name, "role": role["name"], "role_id": role["id"], "policy": "Notes allowed.", "consent": True,
            }).raise_for_status().json()["id"]
            answer = client.post(f"/api/sessions/{sid}/answers", json={
                "planned_slot": 1, "question": asked, "answer": private_answer,
            }).raise_for_status().json()["id"]
            client.post("/api/interviews/bulk/tag", json={"session_ids": [sid], "add": [tag], "remove": []}).raise_for_status()
            return sid, answer
        session("Awaiting review", "What did you check?", "awaiting")
        client.put(f"/api/roles/{role['id']}", json={"name": role["name"], "questions": [revised]}).raise_for_status()
        sid, answer = session("Reviewed", "What did you check?", "reviewed")
        client.patch(f"/api/sessions/{sid}/answers/{answer}", json={"disposition": "unresolved", "note": "Private calibration note."}).raise_for_status()
        legacy, _ = session("Historical", fallback, "awaiting")
        # Older retained records can have a numbered answer without a recoverable plan.
        with store.connection(write=True) as db:
            db.execute("UPDATE session_context SET questions='[]' WHERE session_id=?", (legacy,))

    page.goto(workspace_url + "/data/")
    cohort = page.get_by_role("region", name="Cohort analytics and scorecard calibration")
    explained = cohort.get_by_text("Explained answers", exact=True).locator("..")
    expect(explained).to_contain_text("0.0%")
    expect(explained).to_contain_text("0 of 1 reviewed")
    tags = cohort.get_by_role("table", name="Cohort review outcomes by tag")
    expect(tags.get_by_role("row").filter(has_text="awaiting")).to_contain_text("No reviewed answers")
    expect(tags.get_by_role("row").filter(has=page.get_by_role("button", name="reviewed", exact=True))).to_contain_text("0.0% (0 of 1)")
    tags.get_by_role("button", name="awaiting", exact=True).click()
    expect(explained).to_contain_text("No reviewed answers")
    expect(explained).not_to_contain_text("%")

    page.goto(workspace_url + "/roles/")
    panel = page.get_by_role("region", name="Role calibration analytics")
    empty = panel.get_by_role("group", name="Review outcomes for Empty fixture")
    expect(empty).to_contain_text("No reviewed answers")
    expect(empty.get_by_text("No answers", exact=True)).to_be_visible()
    expect(empty).not_to_contain_text("0.0%")
    target = panel.get_by_role("group", name="Review outcomes for Calibration fixture")
    expect(target).to_contain_text("0.0% (0 of 1)")
    target.get_by_role("button", name="Inspect calibration").click()
    questions = target.get_by_role("list", name="Question breakdown")
    rows = questions.get_by_role("listitem")
    expect(rows).to_have_count(3)
    old_row = rows.filter(has_text=old)
    expect(old_row).to_contain_text("Question 1 · Saved plan")
    expect(old_row).to_contain_text("No reviewed answers")
    new_row = rows.filter(has_text=revised)
    expect(new_row).to_contain_text("Question 1 · Saved plan")
    expect(new_row).to_contain_text("Explained 0.0% (0 of 1)")
    expect(new_row).to_contain_text("Unresolved or disclosed 100.0% (1 of 1)")
    expect(rows.filter(has_text=fallback)).to_contain_text("Question 1 · Recorded wording")
    expect(panel).not_to_contain_text(private_answer)
    expect(panel).not_to_contain_text("Private calibration note.")
    expect(panel).not_to_contain_text("Pass rate")
    page.set_viewport_size({"width": 320, "height": 800})
    assert questions.evaluate("(el) => el.scrollWidth <= el.clientWidth")
    questions.screenshot(path=tmp_path / "question-review-outcomes-phone.png")


def test_older_cohort_reply_shows_available_percentages_without_inventing_counts(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        for tag in ("observed", "pending"):
            sid = client.post("/api/sessions", json={
                "candidate": tag, "role": "Engineer", "policy": "Manual permitted.", "consent": True,
            }).raise_for_status().json()["id"]
            aid = client.post(f"/api/sessions/{sid}/answers", json={
                "question": "Which readings?", "answer": "I checked the receiver.",
            }).raise_for_status().json()["id"]
            if tag == "observed":
                client.patch(f"/api/sessions/{sid}/answers/{aid}", json={"disposition": "explained", "note": "Recorded."}).raise_for_status()
            client.post("/api/interviews/bulk/tag", json={"session_ids": [sid], "add": [tag], "remove": []}).raise_for_status()
        legacy = client.get("/api/analytics/cohorts").raise_for_status().json()
    for key in ("explained_count", "concern_count"):
        del legacy["summary"][key]
    for row in legacy["tag_breakdown"]:
        for key in ("explained_count", "reviewed_count"):
            del row[key]
    page.route("**/api/analytics/cohorts", lambda route: route.fulfill(json=legacy))
    page.goto(workspace_url + "/data/")
    cohort = page.get_by_role("region", name="Cohort analytics and scorecard calibration")
    explained = cohort.get_by_text("Explained answers", exact=True).locator("..")
    expect(explained).to_contain_text("100.0%")
    expect(explained).not_to_contain_text(" of ")
    tags = cohort.get_by_role("table", name="Cohort review outcomes by tag")
    observed = tags.get_by_role("row").filter(has=page.get_by_role("button", name="observed"))
    expect(observed.get_by_role("cell").nth(2)).to_have_text("100.0%")
    unknown = tags.get_by_role("row").filter(has=page.get_by_role("button", name="pending"))
    expect(unknown.get_by_role("cell").nth(2)).to_have_text("Unavailable")
    expect(cohort).not_to_contain_text("undefined")
