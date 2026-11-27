"""Exercise panel review through the Roles queue and saved exchange with real account roles."""
import re

from playwright.sync_api import expect

from e2e_suite.harness import assert_no_horizontal_overflow, login_user
from e2e_suite.test_m23_alerts_calibration_e2e import (
    ADMIN_EMAIL, BOB_EMAIL, PASS, _create_role, _seed_session, _setup_users, _sign_in_browser,
)


def test_panel_chair_records_private_reason_and_member_sees_process_only(e2e_workspace, desktop_page, mobile_page):
    _setup_users(e2e_workspace)
    with e2e_workspace.client() as chair, e2e_workspace.client() as member:
        login_user(chair, email=ADMIN_EMAIL, password=PASS)
        login_user(member, email=BOB_EMAIL, password=PASS)
        role = _create_role(chair, name="Panel fixture", questions=["Explain the release."])
        sid, (aid,) = _seed_session(chair, role=role, candidate="Panel candidate", questions=["Explain the release."])
        answer = f"/api/sessions/{sid}/answers/{aid}"
        for client, opinion in ((chair, "explained"), (member, "unresolved")):
            client.patch(answer, json={"disposition": opinion, "note": "Original evidence."}).raise_for_status()
        original = chair.get(answer).raise_for_status().json()

    page, _ = desktop_page
    base = e2e_workspace.base_url
    _sign_in_browser(page, base, ADMIN_EMAIL)
    page.goto(base + "/roles/", wait_until="domcontentloaded")
    queue = page.get_by_role("region", name="Reviewer calibration disagreement queue")
    expect(queue).to_contain_text("Awaiting panel review")
    queue.get_by_role("link", name="Review exchange").click()
    panel = page.locator("#panel-discussion")
    expect(panel.get_by_role("button", name="Record panel decision")).to_be_visible()
    panel.get_by_label("Discussion action").select_option("follow_up_required")
    panel.get_by_label("Reason for this panel decision").fill("Private chair explanation for follow up.")
    panel.get_by_role("button", name="Record panel decision").click()
    expect(panel.get_by_text("Panel decision recorded.")).to_be_visible()
    panel.get_by_label("Discussion action").select_option("discussion_complete")
    panel.get_by_label("Reason for this panel decision").fill("Private chair explanation for closure.")
    panel.get_by_role("button", name="Record panel decision").click()
    expect(panel.get_by_text("2 recorded changes.")).to_be_visible()
    panel.get_by_role("button", name="Read private panel notes").click()
    expect(panel.get_by_text("Private chair explanation for closure.")).to_be_visible()
    assert_no_horizontal_overflow(page)
    panel.screenshot(path=e2e_workspace.screenshot_dir / "panel_discussion_desktop.png")

    phone, _ = mobile_page
    _sign_in_browser(phone, base, BOB_EMAIL)
    phone.goto(base + "/roles/", wait_until="domcontentloaded")
    results = phone.get_by_role("region", name="Reviewer calibration disagreement queue")
    expect(results.get_by_text("No panel discussions match these filters.")).to_be_visible()
    results.get_by_label("Filter panel discussions").select_option("completed")
    expect(results).to_contain_text("Discussion completed")
    results.get_by_role("link", name="Review exchange").click()
    discussion = phone.locator("#panel-discussion")
    expect(discussion.get_by_text("2 recorded changes.")).to_be_visible()
    expect(discussion.get_by_role("button", name="Record panel decision")).to_have_count(0)
    expect(discussion.get_by_text(re.compile("Private chair explanation"))).to_have_count(0)
    assert_no_horizontal_overflow(phone)
    discussion.screenshot(path=e2e_workspace.screenshot_dir / "panel_discussion_phone.png")
    with e2e_workspace.client() as member:
        login_user(member, email=BOB_EMAIL, password=PASS)
        assert member.get(answer).json() == original
