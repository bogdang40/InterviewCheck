"""Guard individual and bulk edits against unseen assignment changes."""
import httpx
from playwright.sync_api import expect


def assigned_session(client, name):
    sid = client.post("/api/sessions", json={
        "candidate": name, "role": "Engineer", "policy": "Notes permitted.", "consent": True,
    }).raise_for_status().json()["id"]
    path = f"/api/sessions/{sid}/assignment"
    change(client, path, "original@example.test")
    return sid, path


def change(client, path, email, *, priority="high", due=None):
    client.put(path, json={"assignee_email": email, "priority": priority, "due_at": due}).raise_for_status()


def guarded(client, path):
    return client.get(path, params={"include_version": True}).raise_for_status().json()


def test_single_assignment_review_merges_fresh_deadlines_and_rechecks(workspace_url, browser_page, tmp_path):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path = assigned_session(client, "Concurrent assignment")
        page.goto(f"{workspace_url}/interviews/review/?id={sid}")
        bar = page.get_by_role("region", name="Session assignment")
        email = bar.get_by_label("Assignee email")
        expect(email).to_have_value("original@example.test")
        email.fill("mine@example.test")
        first_due = "2030-04-16T08:10:11.123456+00:00"
        change(client, path, "other@example.test", priority="normal", due=first_due)
        bar.get_by_role("button", name="Save assignment").click()
        review = bar.get_by_role("region", name="Assignment conflict")
        latest = review.get_by_role("region", name="Latest assignment")
        proposal = review.get_by_role("region", name="Proposed assignment")
        expect(latest).to_contain_text("other@example.test")
        expect(proposal).to_contain_text("mine@example.test")
        expect(proposal).to_contain_text("Normal priority")
        expect(proposal).to_contain_text(first_due)
        assert guarded(client, path)["assignment"]["assignee_email"] == "other@example.test"

        # A third reviewer changes the same day by a microsecond during the first confirmation.
        second_due = "2030-04-16T08:10:11.123457+00:00"
        change(client, path, "other@example.test", priority="low", due=second_due)
        confirm = review.get_by_role("button", name="Save reviewed assignment")
        confirm.click()
        expect(proposal).to_contain_text(second_due)
        expect(proposal).to_contain_text("Low priority")
        fresh = guarded(client, path)
        assert fresh["assignment"]["assignee_email"] == "other@example.test"
        page.set_viewport_size({"width": 320, "height": 800})
        assert review.evaluate("(el) => el.scrollWidth <= el.clientWidth")
        review.screenshot(path=tmp_path / "assignment-conflict-phone.png")
        with page.expect_response(lambda r: r.request.method == "PUT" and r.url.endswith(path)) as reply:
            confirm.focus()
            page.keyboard.press("Enter")
        assert reply.value.ok and reply.value.request.post_data_json["expected_version"] == fresh["version"]
        expect(review).to_have_count(0)
        saved = guarded(client, path)["assignment"]
        assert (saved["assignee_email"], saved["priority"], saved["due_at"]) == ("mine@example.test", "low", second_due)

        change(client, path, "keep@example.test")
        clear = bar.get_by_role("button", name="Clear assignment", exact=True)
        clear.click()
        expect(latest).to_contain_text("keep@example.test")
        expect(proposal).to_contain_text("Unassigned")
        review.get_by_role("button", name="Use latest assignment").click()
        expect(email).to_have_value("keep@example.test")
        change(client, path, "review-before-clearing@example.test")
        clear.click()
        expect(latest).to_contain_text("review-before-clearing@example.test")
        token = guarded(client, path)["version"]
        with page.expect_response(lambda r: r.request.method == "DELETE" and path in r.url) as cleared:
            review.get_by_role("button", name="Confirm clear assignment").click()
        assert cleared.value.ok and f"expected_version={token}" in cleared.value.url
        expect(review).to_have_count(0)
        assert guarded(client, path)["assignment"] is None


def test_stale_bulk_assignment_requires_reselection(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        a, first_path = assigned_session(client, "Panel One")
        b, second_path = assigned_session(client, "Panel Two")
        page.goto(workspace_url + "/interviews/?queue=high")
        queue = page.get_by_role("region", name="Assignment queues")
        first = queue.get_by_role("checkbox", name="Select Panel One for bulk assignment")
        second = queue.get_by_role("checkbox", name="Select Panel Two for bulk assignment")
        queue.get_by_role("button", name="Select visible").click()
        queue.get_by_label("Bulk assignee email").fill("team@example.test")
        queue.get_by_label("Bulk priority").select_option("low")
        original = {a: guarded(client, first_path)["version"], b: guarded(client, second_path)["version"]}
        change(client, second_path, "other@example.test")
        with page.expect_response(lambda r: r.request.method == "POST" and r.url.endswith("/assignments/bulk")) as failed:
            queue.get_by_role("button", name="Assign selected").click()
        assert failed.value.status == 409
        assert failed.value.request.post_data_json["expected_versions"] == original
        expect(queue.get_by_role("alert")).to_contain_text("No assignments were changed")
        expect(first).not_to_be_checked()
        expect(second).not_to_be_checked()
        expect(queue.get_by_role("button", name="Assign selected")).to_have_count(0)
        assert guarded(client, first_path)["assignment"]["assignee_email"] == "original@example.test"
        assert guarded(client, second_path)["assignment"]["assignee_email"] == "other@example.test"
        second.check()
        expect(queue.get_by_label("Bulk assignee email")).to_have_value("team@example.test")
        expect(queue.get_by_label("Bulk priority")).to_have_value("low")
        token = guarded(client, second_path)["version"]
        with page.expect_response(lambda r: r.request.method == "POST" and r.url.endswith("/assignments/bulk")) as success:
            queue.get_by_role("button", name="Assign selected").click()
        assert success.value.ok
        assert success.value.request.post_data_json["expected_versions"] == {b: token}
        assert guarded(client, second_path)["assignment"]["assignee_email"] == "team@example.test"
        assert guarded(client, first_path)["assignment"]["assignee_email"] == "original@example.test"


def test_missing_versions_disable_browser_assignment_writes(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path = assigned_session(client, "Legacy assignment")
        legacy = client.get(path).raise_for_status().json()
        assert "version" not in legacy
        page.route(f"**{path}?include_version=true", lambda route: route.fulfill(json=legacy))
        page.goto(f"{workspace_url}/interviews/review/?id={sid}")
        bar = page.get_by_role("region", name="Session assignment")
        expect(bar.get_by_role("button", name="Refresh assignment")).to_be_visible()
        expect(bar.get_by_role("button", name="Save assignment")).to_be_disabled()
        expect(bar.get_by_role("button", name="Clear assignment")).to_be_disabled()
        page.unroute(f"**{path}?include_version=true")
        bar.get_by_role("button", name="Refresh assignment").click()
        expect(bar.get_by_role("button", name="Save assignment")).to_be_enabled()

        old_queue = client.get("/api/interviews/assignments", params={"priority": "high"}).raise_for_status().json()
        assert all("assignment_version" not in item for item in old_queue["items"])
        page.route("**/api/interviews/assignments?*", lambda route: route.fulfill(json=old_queue))
        page.goto(workspace_url + "/interviews/?queue=high")
        queue = page.get_by_role("region", name="Assignment queues")
        expect(queue.get_by_role("button", name="Select visible")).to_be_disabled()
        expect(queue.get_by_role("checkbox", name="Select Legacy assignment for bulk assignment")).to_be_disabled()


def test_assignment_conflict_retry_preserves_proposal_after_remote_clear(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path = assigned_session(client, "Deleted assignment")
        page.goto(f"{workspace_url}/interviews/review/?id={sid}")
        bar = page.get_by_role("region", name="Session assignment")
        email = bar.get_by_label("Assignee email")
        email.fill("recover@example.test")
        client.delete(path).raise_for_status()
        endpoint = f"**{path}?include_version=true"
        page.route(endpoint, lambda route: route.fulfill(status=503, json={"detail": "Latest assignment unavailable."}))
        bar.get_by_role("button", name="Save assignment").click()
        expect(bar.get_by_role("alert")).to_contain_text("Latest assignment unavailable.")
        expect(email).to_have_value("recover@example.test")
        expect(bar.get_by_role("button", name="Save assignment")).to_be_disabled()
        assert guarded(client, path)["assignment"] is None
        page.unroute(endpoint)
        review = bar.get_by_role("region", name="Assignment conflict")
        review.get_by_role("button", name="Reload latest assignment").click()
        expect(review.get_by_role("region", name="Latest assignment")).to_contain_text("Unassigned")
        expect(review.get_by_role("region", name="Proposed assignment")).to_contain_text("recover@example.test")
        assert guarded(client, path)["assignment"] is None
        review.get_by_role("button", name="Save reviewed assignment").click()
        expect(review).to_have_count(0)
        assert guarded(client, path)["assignment"]["assignee_email"] == "recover@example.test"


def test_bulk_refreshes_after_selected_interview_enters_trash(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        _, path = assigned_session(client, "Active reviewer assignment")
        removed, _ = assigned_session(client, "Removed interview")
        page.goto(workspace_url + "/interviews/?queue=high")
        queue = page.get_by_role("region", name="Assignment queues")
        queue.get_by_role("button", name="Select visible").click()
        queue.get_by_label("Bulk assignee email").fill("team@example.test")
        client.post(f"/api/sessions/{removed}/trash").raise_for_status()
        queue.get_by_role("button", name="Clear selected assignments").click()
        expect(queue.get_by_role("alert")).to_contain_text("A selected interview is unavailable. No assignments were changed.")
        expect(queue.get_by_role("checkbox", name="Select Removed interview for bulk assignment")).to_have_count(0)
        remaining = queue.get_by_role("checkbox", name="Select Active reviewer assignment for bulk assignment")
        expect(remaining).not_to_be_checked()
        assert guarded(client, path)["assignment"]["assignee_email"] == "original@example.test"
        remaining.check()
        expect(queue.get_by_label("Bulk assignee email")).to_have_value("team@example.test")
