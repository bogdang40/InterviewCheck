"""Exercise panel review through the Roles queue and saved exchange with real account roles."""
from collections import Counter
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


def sign_out_other_tab(page, sibling, collector, base, sid, aid, reason):
    collector.assert_clean()
    protected = base + f"/api/calibration/sessions/{sid}/answers/{aid}/panel"
    permitted_reads = {protected, protected + "/edit", protected + "/private", base + "/api/integrations/account",
                       base + f"/api/sessions/{sid}/ats"}
    denials, errors, writes = [], [], []

    def response(event):
        if event.status >= 400:
            denials.append((event.request.method, event.url, event.status, event.request.resource_type))

    def console(event):
        if event.type == "error":
            errors.append((event.text, event.location.get("url")))

    def request(event):
        if event.method not in ("GET", "HEAD", "OPTIONS"):
            # Redirecting this tab to a public page can record a signed-out page visit.
            if (event.method == "POST" and event.url == base + "/api/usage/visit"
                    and event.post_data_json in ({"page": "signin"}, {"page": "home"})):
                return
            writes.append((event.method, event.url))

    page.on("response", response)
    page.on("console", console)
    page.on("request", request)
    try:
        sibling.get_by_role("button", name="Sign out", exact=True).click()
        expect(sibling.get_by_role("button", name="Sign in", exact=True)).to_be_visible()
        expect(reason).to_have_count(0, timeout=15_000)
        page.wait_for_load_state("networkidle", timeout=15_000)
    finally:
        page.remove_listener("request", request)
        page.remove_listener("console", console)
        page.remove_listener("response", response)

    assert not writes and not collector.page_errors and not collector.server_errors
    assert all(method == "GET" and url in permitted_reads and status == 401 and resource in ("xhr", "fetch")
               for method, url, status, resource in denials), denials
    responses = Counter(url for _, url, _, _ in denials)
    assert [text for text, _ in errors] == collector.console_errors
    for text, url in errors:
        assert re.fullmatch(r"Failed to load resource: the server responded with a status of 401 \(Unauthorized\)", text), text
        assert responses[url] > 0, (url, denials)
        responses[url] -= 1
    # The following administrator sign-in starts with the normal strict collector.
    collector.console_errors.clear()


def test_private_panel_draft_disappears_across_browser_account_switch(e2e_workspace, desktop_page):
    from e2e_suite.harness import signup_user
    from e2e_suite.test_m23_alerts_calibration_e2e import BOOTSTRAP_SECRET

    second_email = "second-chair-browser@example.test"
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL, second_email), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    with e2e_workspace.client() as first, e2e_workspace.client() as second:
        signup_user(first, email=ADMIN_EMAIL, password=PASS, admin_secret=BOOTSTRAP_SECRET)
        signup_user(second, email=second_email, password=PASS, admin_secret=BOOTSTRAP_SECRET)
        login_user(first, email=ADMIN_EMAIL, password=PASS)
        login_user(second, email=second_email, password=PASS)
        role = _create_role(first, name="Private operator change", questions=["Explain the release."])
        sid, (aid,) = _seed_session(first, role=role, candidate="Fixture", questions=["Explain the release."])
        answer = f"/api/sessions/{sid}/answers/{aid}"
        for user, opinion in ((first, "explained"), (second, "unresolved")):
            user.patch(answer, json={"disposition": opinion, "note": "Original opinion."}).raise_for_status()

    page, collector = desktop_page
    base = e2e_workspace.base_url
    _sign_in_browser(page, base, ADMIN_EMAIL)
    url = base + f"/interviews/review/?id={sid}&answer={aid}#panel-discussion"
    page.goto(url, wait_until="domcontentloaded")
    panel = page.locator("#panel-discussion")
    reason = panel.get_by_label("Reason for this panel decision")
    panel.get_by_label("Discussion action").select_option("discussion_complete")
    reason.fill("Private chair history")
    panel.get_by_role("button", name="Record panel decision").click()
    expect(panel.get_by_text("Panel decision recorded.")).to_be_visible()
    panel.get_by_role("button", name="Read private panel notes").click()
    expect(panel.get_by_text("Private chair history", exact=True)).to_be_visible()
    panel.get_by_label("Discussion action").select_option("reopened")
    reason.fill("Private A draft")
    expect(panel.get_by_role("button", name="Record panel decision")).to_be_enabled()

    # The login cookie is shared by browser tabs. The cross-tab listener must clear
    # A's private editor even while the first page is left open at its original URL.
    sibling = page.context.new_page()
    try:
        sibling.goto(base + "/account/", wait_until="domcontentloaded")
        # A new cookie for the same administrator also invalidates a private panel editor.
        edit_url = base + f"/api/calibration/sessions/{sid}/answers/{aid}/panel/edit"
        previous = page.request.get(edit_url).json()["editor"]
        rotate = sibling.get_by_role("form", name="Change password")
        rotate.get_by_label("Current password").fill(PASS)
        rotate.get_by_label("New password", exact=True).fill(PASS + "-rotated")
        rotate.get_by_label("Confirm new password").fill(PASS + "-rotated")
        with page.expect_response(lambda res: res.url == edit_url and res.request.method == "GET") as rechecked:
            rotate.get_by_role("button", name="Update password").click()
        expect(rotate.get_by_role("status")).to_contain_text("Password updated and session rotated.")
        assert rechecked.value.ok and rechecked.value.json()["editor"] != previous
        expect(reason).to_have_value("")
        expect(panel.get_by_text("Private chair history", exact=True)).to_have_count(0)
        expect(panel.get_by_label("Discussion action")).to_have_value("")
        # Now verify the distinct switch to B with another unsaved draft and visible private history.
        panel.get_by_role("button", name="Read private panel notes").click()
        expect(panel.get_by_text("Private chair history", exact=True)).to_be_visible()
        panel.get_by_label("Discussion action").select_option("reopened")
        reason.fill("Private A draft")
        sign_out_other_tab(page, sibling, collector, base, sid, aid, reason)
        _sign_in_browser(sibling, base, second_email)
        # The application can return this tab to its sign-in gate on logout.
        if not page.url.startswith(base + "/interviews/review"):
            page.goto(url, wait_until="domcontentloaded")
        expect(reason).to_be_visible(timeout=15_000)
        expect(reason).to_have_value("")
        expect(panel.get_by_text("Private chair history", exact=True)).to_have_count(0)
        expect(panel.get_by_label("Discussion action")).to_have_value("")
        panel.get_by_label("Discussion action").select_option("reopened")
        reason.fill("Independent B note")
        panel.get_by_role("button", name="Record panel decision").click()
        expect(panel.get_by_text("Panel decision recorded.")).to_be_visible()
        result = page.request.get(base + f"/api/calibration/sessions/{sid}/answers/{aid}/panel/private").json()
        assert [(event["actor_email"], event["rationale"]) for event in result["history"]] == [
            (second_email, "Independent B note"), (ADMIN_EMAIL, "Private chair history")]
        assert "Private A draft" not in str(result)
        collector.assert_clean()
    finally:
        sibling.close()
