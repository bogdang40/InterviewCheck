"""Read exactly what changed between two saved role plans."""
import os
from pathlib import Path

from playwright.sync_api import expect

HEADERS = {"X-InterviewCheck": "1"}


def test_keyboard_comparison_keeps_selected_revisions_during_edits(workspace_url, browser_page, tmp_path):
    page = browser_page
    page.set_viewport_size({"width": 320, "height": 780})
    api = page.request
    roles = workspace_url + "/api/roles"
    initial = {"name": "Engineer", "description": "First definition", "policy": "Paper manual",
               "questions": ["Explain the alert.", "Which page matters?", "Explain the alert."],
               "rubric": [{"id": "signals", "criterion": "Evidence", "weight": 2,
                           "expected_signals": ["First signal"], "red_flags": ["Guessing"]},
                          {"id": "other", "criterion": "Response", "weight": 1}],
               "permitted_sources": [{"label": "Runbook", "text": "Original material"}]}
    saved = api.post(roles, headers=HEADERS, data=initial)
    assert saved.ok
    v1 = saved.json()
    path = roles + "/" + v1["id"]
    modified = {**initial, "questions": initial["questions"][1:],
                "rubric": [initial["rubric"][1], {**initial["rubric"][0], "expected_signals": ["Measured signal"]}],
                "permitted_sources": [{"label": "Runbook", "text": "Changed material"}]}
    v2 = api.put(path, headers=HEADERS, data={**modified, "version": v1["version"]}).json()
    v3 = api.put(path, headers=HEADERS, data={**modified, "version": v2["version"], "questions": ["Unrelated live question"]}).json()
    assert v3["version_number"] == 3

    mutations = []
    page.on("request", lambda request: mutations.append(request.method) if "/api/roles" in request.url and request.method != "GET" else None)
    page.goto(workspace_url + "/roles/?role=" + v1["id"])
    entry = page.get_by_role("button", name="Preview interviewer guide for revision 1").locator("..")
    inspect = entry.get_by_role("button", name="Inspect diff")
    inspect.focus()
    inspect.press("Enter")
    section = page.get_by_role("region", name="Revision comparison")
    expect(section).to_contain_text("Diff vs live v3")
    select = section.get_by_label("Compare revision 1 with")
    select.focus()
    select.press("Home")
    select.press("ArrowDown")
    expect(select).to_have_value("2")
    expect(section).to_contain_text("Comparing v1 with v2")
    order = section.get_by_role("region", name="Question order")
    expect(order.get_by_role("group", name="Revision 1").get_by_role("listitem")).to_have_text(initial["questions"])
    expect(order.get_by_role("group", name="Revision 2").get_by_role("listitem")).to_have_text(modified["questions"])
    expect(order).to_contain_text("2 times in v1 and 1 time in v2")
    grading = section.get_by_role("region", name="Grading changes")
    expect(grading).to_contain_text("Criterion order changed.")
    expect(grading).to_contain_text("First signal")
    expect(grading).to_contain_text("Measured signal")
    expect(grading).not_to_contain_text("Weight 2")
    expect(section).not_to_contain_text("Original material")
    disclosure = section.get_by_text("Compare permitted materials", exact=True)
    disclosure.focus()
    disclosure.press("Enter")
    expect(section).to_contain_text("Original material")
    expect(section).to_contain_text("Changed material")
    expect(section).not_to_contain_text("Unrelated live question")
    assert section.evaluate("el => el.scrollWidth <= el.clientWidth + 1")
    out = Path(os.getenv("INTERVIEWCHECK_E2E_SCREENSHOT_DIR", tmp_path))
    out.mkdir(exist_ok=True, parents=True)
    section.screenshot(path=out / "role-revision-comparison-phone.png")

    v4 = api.put(path, headers=HEADERS, data={**modified, "version": v3["version"], "questions": ["Fourth revision only"]}).json()
    assert v4["version_number"] == 4
    expect(section).to_contain_text("Comparing v1 with v2")
    expect(section).not_to_contain_text("Fourth revision only")
    select.select_option("1")
    expect(section).to_contain_text("No content changes between these revisions.")
    assert api.get(path).json()["version"] == v4["version"]
    assert not mutations
