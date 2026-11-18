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
