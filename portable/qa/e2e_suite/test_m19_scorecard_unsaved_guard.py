"""Unsaved scorecard edits block finishing and exporting, and ask before the page is left."""
import re

from playwright.sync_api import expect

from e2e_suite.test_m19_scorecard_recovery_print import _seed_role_and_session


def test_unsaved_scorecard_rating_blocks_finish_and_guards_navigation(e2e_workspace, desktop_page):
    with e2e_workspace.client() as c:
        _, session, answer = _seed_role_and_session(c, with_answer=True)
    page, _ = desktop_page
    page.goto(f"{e2e_workspace.base_url}/interviews/review/?id={session['id']}&answer={answer['id']}",
              wait_until="domcontentloaded")
    finish = page.get_by_role("button", name="Finish interview")
    expect(page.get_by_label("Session scorecard panel")).to_be_visible()
    expect(finish).to_be_enabled()

    page.get_by_role("button", name="Rate System Design 4 of 5").click()
    expect(finish).to_be_disabled()
    expect(page.get_by_role("status").filter(has_text="Save or discard your changes")).to_be_visible()

    prompts = []
    page.once("dialog", lambda dialog: (prompts.append(dialog.message), dialog.dismiss()))
    page.get_by_role("navigation", name="Workspace").get_by_role("link", name="Overview", exact=True).click()
    assert prompts == ["Discard unsaved interview changes and leave this page?"]
    expect(page).to_have_url(re.compile(r"/interviews/review/"))
    expect(page.get_by_role("button", name="Rate System Design 4 of 5")).to_have_attribute("aria-pressed", "true")

    page.get_by_role("button", name="Save scorecard").click()
    expect(page.get_by_text("Scorecard saved.", exact=True)).to_be_visible()
    expect(finish).to_be_enabled()
