"""Compare each candidate's saved ratings and explicitly select which review data is shared."""
import httpx
from playwright.sync_api import expect


def test_saved_scorecards_and_rationales_follow_share_choices(workspace_url, browser_page, tmp_path):
    page = browser_page
    private = "Compared the retry counters before changing the rollout."
    ids = []
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        role = client.post("/api/roles", json={
            "name": "Production reviewer", "questions": [],
            "rubric": [{"id": "live", "criterion": "Current template criterion", "weight": 4}],
        }).raise_for_status().json()
        for name in ("Ada", "Bea", "Cleo"):
            ids.append(client.post("/api/sessions", json={
                "candidate": name, "role": role["name"], "role_id": role["id"],
                "policy": "Notes permitted.", "consent": True,
            }).raise_for_status().json()["id"])
        client.put(f"/api/sessions/{ids[0]}/scorecard", json={"items": [
            {"criterion_id": "z", "criterion_label": "Evidence checks", "rating": 3, "weight": 1, "rationale": private},
            {"criterion_id": "a", "criterion_label": "Rollback plan", "rating": 5, "weight": 3, "rationale": ""},
        ]}).raise_for_status()
        client.put(f"/api/sessions/{ids[1]}/scorecard", json={"items": [
            {"criterion_id": "a", "criterion_label": "System design", "rating": 5, "weight": 2, "rationale": ""},
        ]}).raise_for_status()

    url = workspace_url + "/interviews/compare/?ids="
    page.goto(url + ",".join(ids))
    scores = page.get_by_role("checkbox", name="Include saved scorecards")
    rationales = page.get_by_role("checkbox", name="Include reviewer rationales")
    report = page.get_by_role("region", name="Saved interview scorecards")
    print_link = page.get_by_role("link", name="Print or save PDF")
    expect(page.get_by_role("heading", name="Candidates (3)")).to_be_visible()
    expect(scores).not_to_be_checked()
    expect(rationales).to_be_disabled()
    expect(report).to_have_count(0)
    expect(page.get_by_text("Current guidance from the shared role definition.")).to_be_visible()

    def shared_reports():
        print_url = print_link.get_attribute("href")
        html = page.request.get(workspace_url + print_url)
        assert html.ok
        with page.expect_download() as event:
            page.get_by_role("button", name="Download Markdown dossier").click()
        return html.text(), event.value.path().read_text(encoding="utf-8")

    for export in shared_reports():
        assert "Evidence checks" not in export and private not in export
    scores.focus()
    page.keyboard.press("Space")
    ada, bea, cleo = (report.get_by_role("article", name=name) for name in ("Ada", "Bea", "Cleo"))
    expect(ada).to_contain_text("90% weighted score across 2 rated criteria")
    expect(bea).to_contain_text("100% weighted score across 1 rated criterion")
    expect(cleo).to_contain_text("No saved ratings.")
    assert report.get_by_role("heading", level=3).all_text_contents() == ["Ada", "Bea", "Cleo"]
    rows = ada.get_by_role("listitem")
    expect(rows.nth(0)).to_contain_text("Evidence checks")
    expect(rows.nth(0)).to_contain_text("Rating 3 of 5 · Weight 1")
    expect(rows.nth(1)).to_contain_text("Rollback plan")
    expect(bea.get_by_role("listitem")).to_contain_text("System design")
    expect(report).not_to_contain_text("Current template criterion")
    expect(report).not_to_contain_text(private)
    assert "include_rationales" not in print_link.get_attribute("href")
    for export in shared_reports():
        assert "Evidence checks" in export and private not in export

    rationales.check()
    expect(ada).to_contain_text(private)
    assert "include_rationales=true" in print_link.get_attribute("href")
    for export in shared_reports():
        assert "Evidence checks" in export and private in export
    page.set_viewport_size({"width": 320, "height": 800})
    assert report.evaluate("(el) => el.scrollWidth <= el.clientWidth")
    assert bea.bounding_box()["y"] > ada.bounding_box()["y"]
    report.screenshot(path=tmp_path / "saved-scorecards-phone.png")

    scores.uncheck()
    expect(rationales).not_to_be_checked()
    expect(rationales).to_be_disabled()
    expect(report).to_have_count(0)
    scores.check()
    expect(ada).to_be_visible()
    expect(ada).not_to_contain_text(private)
    rationales.check()
    expect(ada).to_contain_text(private)
    page.evaluate("(url) => history.pushState(null, '', url)", url + ",".join(ids[::-1]))
    expect(scores).not_to_be_checked()
    expect(report).to_have_count(0)
    expect(rationales).to_be_disabled()
    page.go_back()
    expect(page).to_have_url(url + ",".join(ids))
    expect(scores).not_to_be_checked()
    expect(report).to_have_count(0)
    assert "include_scorecards" not in print_link.get_attribute("href")
