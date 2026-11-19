import re

from playwright.sync_api import expect


def test_template_materials_are_editable_before_notice_and_preserved_for_preview(
    workspace_url, browser_page, tmp_path
):
    page = browser_page
    passage = "Discard the blue calibration disk when the paper seal separates from the housing."
    page.goto(workspace_url + "/roles/")
    page.get_by_role("button", name="Add role").click()
    page.get_by_label("Role name", exact=True).fill("Kit engineer")
    page.get_by_label("Assistance policy", exact=True).fill("The test manual is permitted.")
    page.get_by_role("button", name="Add permitted source").click()
    page.get_by_label("Permitted source name").fill("Test manual")
    page.get_by_label("Permitted source text").fill(passage)
    page.get_by_role("button", name="Save role").click()
    page.get_by_role("button", name="Prepare").click()
    expect(page.get_by_label("Assistance policy")).to_have_value("The test manual is permitted.")
    expect(page.get_by_label("Permitted source text")).to_have_value(passage)
    page.get_by_label("Candidate", exact=True).fill("Kit participant")
    notice = page.get_by_role("checkbox", name=re.compile("candidate knows"))
    notice.check()
    page.get_by_label("Permitted source name").fill("Session manual")
    expect(notice).not_to_be_checked()
    notice.check()
    page.get_by_role("button", name="Start interview").click()
    page.get_by_role("textbox", name="Question", exact=True).fill("Explain the recovery procedure.")
    page.get_by_label("Candidate answer").fill(passage)
    page.get_by_role("button", name="Add source", exact=True).click()
    page.get_by_label("Source name", exact=True).fill("Comparison answer")
    page.get_by_label("Source passage").fill(passage)
    live = page.get_by_text("Live comparison", exact=True)
    live.click()
    expect(live.locator("..").get_by_text("No passage match", exact=True)).to_be_visible()
    page.get_by_role("button", name="Save and compare").click()
    expect(page.get_by_text("No passage match", exact=True).first).to_be_visible()
    page.screenshot(path=tmp_path / "role-snapshot-review.png", full_page=True)


def test_role_changes_across_editor_and_setup_tabs(workspace_url, browser_page, tmp_path):
    page = browser_page
    template = {"name": "Fixture engineer", "policy": "Use the manual.", "questions": ["Old question?"]}
    response = page.request.post(workspace_url + "/api/roles", data=template, headers={"X-InterviewCheck": "1"})
    assert response.ok
    role_id = response.json()["id"]
    page.goto(workspace_url + "/roles/")
    writer = page.context.new_page()
    writer.goto(workspace_url + "/roles/")
    setup = page.context.new_page()
    try:
        setup.goto(workspace_url + "/interviews/new/")
        setup.get_by_label("Saved role template").select_option(role_id)
        candidate = setup.get_by_label("Candidate", exact=True)
        candidate.fill("Fixture participant")
        notice = setup.get_by_role("checkbox", name=re.compile("candidate knows"))
        notice.check()
        for tab in (page, writer):
            tab.get_by_role("button", name="Edit role").click()
        page.get_by_role("textbox", name="Description", exact=True).fill("Draft from the first tab")
        writer.get_by_label("Assistance policy").fill("Use the checklist.")
        writer.get_by_label("Planned questions, one per line").fill("New question?")
        writer.get_by_role("button", name="Save role").click()
        expect(writer.get_by_role("button", name="Add role")).to_be_visible()

        page.get_by_role("button", name="Save role").click()
        expect(page.locator("form").get_by_role("alert")).to_contain_text("saved role changed")
        expect(page.get_by_role("textbox", name="Description", exact=True)).to_have_value("Draft from the first tab")
        page.screenshot(path=tmp_path / "role-edit-conflict.png", full_page=True)
        page.get_by_role("button", name="Keep edits as a new role").click()
        page.get_by_role("button", name="Save role").click()
        expect(page.get_by_role("button", name="Edit role")).to_have_count(2)
        roles = page.request.get(workspace_url + "/api/roles").json()
        copied, = [row for row in roles if row["id"] != role_id]
        assert copied["description"] == "Draft from the first tab" and copied["questions"] == ["Old question?"]

        setup.get_by_role("button", name="Start interview").click()
        expect(setup.locator("form").get_by_role("alert")).to_contain_text("saved role changed")
        expect(notice).not_to_be_checked()
        assert page.request.get(workspace_url + "/api/sessions").json() == []
        setup.get_by_role("button", name="Replace setup with saved role").click()
        expect(candidate).to_have_value("Fixture participant")
        expect(setup.get_by_label("Assistance policy")).to_have_value("Use the checklist.")
        setup.get_by_text("Planned questions (1)", exact=True).click()
        expect(setup.get_by_text("New question?", exact=True)).to_be_visible()
        expect(notice).not_to_be_checked()
        notice.check()
        setup.get_by_role("button", name="Start interview").click()
        expect(setup.get_by_role("heading", name="Fixture participant")).to_be_visible()
        summary, = page.request.get(workspace_url + "/api/sessions").json()
        saved = page.request.get(workspace_url + "/api/sessions/" + summary["id"]).json()
        assert saved["role_id"] == role_id and saved["planned_questions"] == ["New question?"]
        assert saved["policy"] == "Use the checklist."
    finally:
        writer.close()
        setup.close()


def test_discard_stale_role_edits_and_continue_on_phone(workspace_url, browser_page, tmp_path):
    page = browser_page
    page.set_viewport_size({"width": 320, "height": 780})
    route = workspace_url + "/api/roles"
    headers = {"X-InterviewCheck": "1"}
    initial = page.request.post(route, data={"name": "Inspector"}, headers=headers).json()
    page.goto(workspace_url + "/roles/")
    page.get_by_role("button", name="Edit role").click()
    page.get_by_role("textbox", name="Description", exact=True).fill("Local changes")
    detail = route + "/" + initial["id"]
    assert page.request.put(detail, data={**initial, "name": "Lead inspector"}, headers=headers).ok
    page.get_by_role("button", name="Save role").click()
    reload = page.get_by_role("button", name="Discard edits and load saved role")
    expect(reload).to_be_enabled()
    reload.scroll_into_view_if_needed()
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    page.screenshot(path=tmp_path / "role-conflict-phone.png")
    reload.click()
    expect(page.get_by_label("Role name")).to_have_value("Lead inspector")
    expect(page.get_by_role("textbox", name="Description", exact=True)).to_have_value("")
    page.get_by_role("textbox", name="Description", exact=True).fill("Edited after reload")
    page.get_by_role("button", name="Save role").click()
    expect(page.get_by_text("Edited after reload", exact=True)).to_be_visible()
    assert page.request.get(detail).json()["name"] == "Lead inspector"
