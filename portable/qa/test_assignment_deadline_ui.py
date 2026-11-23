import httpx
import pytest
from playwright.sync_api import expect


ORIGINAL = "2030-03-09T17:30:00.123456-07:00"
UTC = "2030-03-10T00:30:00.123456+00:00"


def create_assigned(client, candidate):
    session = client.post("/api/sessions", json={
        "candidate": candidate, "role": "Engineer", "policy": "Manual permitted", "consent": True,
    }).raise_for_status().json()
    path = f"/api/sessions/{session['id']}/assignment"
    result = client.put(path, json={
        "assignee_email": "first@example.test", "priority": "high", "due_at": ORIGINAL,
    }).raise_for_status().json()["assignment"]
    assert result["due_at"] == UTC
    return session["id"], path


@pytest.mark.parametrize("timezone", [None, "America/Los_Angeles"])
def test_assignment_date_edits_preserve_exact_deadline(workspace_url, qa_browser, timezone):
    from api import store

    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path = create_assigned(client, "Deadline fixture")
        expected = UTC
        if timezone:
            # Earlier stores can contain a valid timestamp with its original offset.
            with store.connection(write=True) as db:
                db.execute("UPDATE session_assignments SET due_at=? WHERE session_id=?", (ORIGINAL, sid))
            expected = ORIGINAL
        context = qa_browser.new_context(timezone_id=timezone)
        try:
            page = context.new_page()
            page.goto(f"{workspace_url}/interviews/review/?id={sid}")
            bar = page.get_by_label("Session assignment")
            date = bar.get_by_label("Due date (UTC)", exact=True)
            expect(date).to_have_value("2030-03-10")
            expect(bar.locator("time")).to_have_attribute("datetime", expected)
            expect(bar.locator("time")).to_contain_text("UTC")

            def submit():
                with page.expect_response(lambda r: r.request.method == "PUT" and r.url.endswith(path)) as pending:
                    bar.get_by_role("button", name="Save assignment").click()
                assert pending.value.ok
                return pending.value.request.post_data_json["due_at"]

            bar.get_by_label("Priority", exact=True).select_option("normal")
            assert submit() == expected
            bar.get_by_label("Assignee email").fill("second@example.test")
            date.fill("2030-03-11")
            date.fill("2030-03-10")
            assert submit() == expected
            saved = client.get(path).raise_for_status().json()["assignment"]
            assert (saved["assignee_email"], saved["priority"], saved["due_at"]) == ("second@example.test", "normal", expected)

            for day in ("2030-03-11", "", "2030-03-13"):
                date.fill(day)
                assert submit() == (f"{day}T23:59:59Z" if day else None)
                assert client.get(path).json()["assignment"]["due_at"] == (f"{day}T23:59:59+00:00" if day else None)
        finally:
            context.close()


def test_bulk_assignment_replaces_selected_deadlines(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        records = [create_assigned(client, name) for name in ("Bulk Alpha", "Bulk Beta")]
        page.goto(f"{workspace_url}/interviews/?queue=high")
        queue = page.get_by_role("region", name="Assignment queues")
        for day in ("2030-03-10", ""):
            for name in ("Bulk Alpha", "Bulk Beta"):
                queue.get_by_role("checkbox", name=f"Select {name} for bulk assignment").check()
            queue.get_by_label("Bulk assignee email").fill("team@example.test")
            queue.get_by_label("Bulk priority").select_option("high")
            queue.get_by_label("Bulk due date (UTC)").fill(day)
            with page.expect_response(lambda r: r.request.method == "POST" and r.url.endswith("/assignments/bulk")) as pending:
                queue.get_by_role("button", name="Assign selected").click()
            assert pending.value.ok
            expect(queue.get_by_label("Bulk due date (UTC)")).to_have_count(0)
            for _, path in records:
                expected = f"{day}T23:59:59+00:00" if day else None
                assert client.get(path).json()["assignment"]["due_at"] == expected
