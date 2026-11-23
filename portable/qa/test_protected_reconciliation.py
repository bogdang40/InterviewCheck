"""Protected editors discard stale data after denial; retrying re-reads and never replays a write."""
import re

import httpx
from playwright.sync_api import expect
import pytest


def seed(client):
    sid = client.post("/api/sessions", json={
        "candidate": "Scoped recovery fixture", "role": "Engineer", "policy": "Manual permitted.", "consent": True,
    }).raise_for_status().json()["id"]
    return f"/api/sessions/{sid}", sid


def assign(client, base, email):
    client.put(base + "/assignment", json={
        "assignee_email": email, "priority": "high", "due_at": "2030-09-17T08:12:30Z",
    }).raise_for_status()


def score(client, base, label, rationale):
    client.put(base + "/scorecard", json={"items": [{
        "criterion_id": "recorded", "criterion_label": label, "weight": 3, "rating": 4, "rationale": rationale,
    }]}).raise_for_status()


@pytest.mark.parametrize(("resource", "direct", "status"), [
    ("assignment", False, 401), ("assignment", False, 404), ("assignment", True, 403),
    ("scorecard", False, 403), ("scorecard", False, 404), ("scorecard", False, 501), ("scorecard", True, 403),
])
def test_protected_editor_requires_explicit_authorized_read(workspace_url, browser_page, resource, direct, status):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        base, sid = seed(client)
        old_email, new_email = "private-earlier@example.test", "fresh-authorized@example.test"
        old_label, old_reason = "Private earlier criterion", "Private stored rationale."
        new_label, new_reason = "Authorized current criterion", "Current approved rationale."
        assign(client, base, old_email)
        score(client, base, old_label, old_reason)
        page.goto(f"{workspace_url}/interviews/review/?id={sid}")
        assignments = page.get_by_role("region", name="Session assignment")
        scores = page.get_by_role("region", name="Session scorecard panel")
        badge = scores.get_by_test_id("scorecard-weighted-badge")
        note = scores.get_by_role("textbox", name="Handoff note", exact=True)
        note.fill("An independent handoff draft.")
        path = base + "/" + resource
        is_assignment = resource == "assignment"
        region = assignments if is_assignment else scores
        def save_other_reviewers_change():
            if is_assignment:
                assign(client, base, new_email)
            else:
                score(client, base, new_label, new_reason)
        local = "local-proposal@example.test" if is_assignment else "Private unsaved score rationale."
        field = assignments.get_by_label("Assignee email") if is_assignment else scores.get_by_label("Rationale for " + old_label)
        field.fill(local)
        save_name = "Clear assignment" if is_assignment and direct else "Save assignment" if is_assignment else "Save scorecard"
        if not direct:
            # The real guarded write returns 409, then the authoritative reconciliation read fails.
            save_other_reviewers_change()

        reads, writes = [], []
        failures = [503] if direct else [status, 503]
        def intercept(route):
            if route.request.method == "GET":
                reads.append(route.request.url)
                if failures:
                    return route.fulfill(status=failures.pop(0), json={"detail": "Fixture read unavailable."})
            else:
                writes.append(route.request.method)
                if direct:
                    return route.fulfill(status=status, json={"detail": "Fixture author-only write refusal."})
            route.continue_()
        page.route(re.compile(re.escape(path) + r"(?:\?|$)"), intercept)
        region.get_by_role("button", name=save_name, exact=True).click()
        retry = region.get_by_role("button", name="Reload assignment" if is_assignment else "Reload scorecard")
        expect(retry).to_be_enabled()
        assert len(writes) == 1 and len(reads) == (0 if direct else 1)
        if direct:
            expect(region.get_by_role("alert")).to_contain_text("change was refused")

        def assert_hidden():
            if is_assignment:
                expect(assignments.get_by_label("Assignee email")).to_have_count(0)
                expect(assignments.get_by_role("button", name="Clear assignment")).to_have_count(0)
                assert all(text not in assignments.inner_html() for text in (old_email, local, "2030-09-17"))
                expect(scores.get_by_label("Rationale for " + old_label)).to_have_value(old_reason)
            else:
                expect(scores.get_by_role("group", name="Rubric scores")).to_have_count(0)
                expect(scores.get_by_role("button", name="Save scorecard")).to_have_count(0)
                expect(badge).to_have_count(0)
                assert all(text not in scores.inner_html() for text in (old_label, old_reason, local))
                expect(assignments.get_by_label("Assignee email")).to_have_value(old_email)
            expect(note).to_have_value("An independent handoff draft.")

        assert_hidden()
        retry.click()
        expect(region.get_by_text(re.compile("Fixture read unavailable"))).to_be_visible()
        assert_hidden()
        assert len(writes) == 1
        if direct:
            save_other_reviewers_change()
        retry.click()
        if is_assignment:
            expect(assignments.get_by_label("Assignee email")).to_have_value(new_email)
        else:
            expect(scores.get_by_label("Rationale for " + new_label)).to_have_value(new_reason)
            expect(badge).to_have_text("Score: 80.0%")
        expect(note).to_have_value("An independent handoff draft.")
        assert len(writes) == 1 and len(reads) == (2 if direct else 3)


def test_temporary_scorecard_reconciliation_failure_keeps_draft(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        base, sid = seed(client)
        score(client, base, "Design", "Original rationale.")
        page.goto(f"{workspace_url}/interviews/review/?id={sid}")
        scores = page.get_by_role("region", name="Session scorecard panel")
        rationale = scores.get_by_label("Rationale for Design")
        rationale.fill("Local proposal.")
        score(client, base, "Design", "Concurrent proposal.")
        path = base + "/scorecard"
        reads, writes = [], []
        def intercept(route):
            if route.request.method == "GET":
                reads.append(route.request.url)
                if len(reads) == 1:
                    return route.fulfill(status=503, json={"detail": "Temporary read failure."})
            else:
                writes.append(route.request.method)
            route.continue_()
        page.route(re.compile(re.escape(path) + r"(?:\?|$)"), intercept)
        save = scores.get_by_role("button", name="Save scorecard")
        save.click()
        expect(scores.get_by_role("alert")).to_contain_text("Temporary read failure.")
        expect(save).to_be_disabled()
        expect(rationale).to_have_value("Local proposal.")
        expect(scores.get_by_test_id("scorecard-weighted-badge")).to_have_text("Score: 80.0% · Unsaved")
        scores.get_by_role("button", name="Refresh saved scorecard").click()
        conflict = scores.get_by_role("group", name="Resolve changes to Design")
        expect(conflict).to_contain_text("Concurrent proposal.")
        expect(conflict).to_contain_text("Local proposal.")
        conflict.get_by_role("button", name="Use saved score").click()
        expect(rationale).to_have_value("Concurrent proposal.")
        assert len(reads) == 2 and writes == ["PUT"]


def test_legacy_notes_share_the_scorecards_read_authorization(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        base, sid = seed(client)
        score(client, base, "Legacy grade", "Saved rationale.")
        path = base + "/scorecard"
        note_path = base + "/handoff-notes"
        old = client.post(note_path, json={"category": "decision", "body": "Earlier private panel note."}).raise_for_status().json()
        deny_read = False
        writes = []
        def legacy(route):
            if route.request.method != "GET":
                writes.append(route.request.method)
                route.fulfill(status=403, json={"detail": "Write refused."})
            elif deny_read:
                route.fulfill(status=402, json={"detail": "Entitlement inactive."})
            else:
                # A server predating paged handoff notes returns the full list from this same endpoint.
                route.fulfill(json=client.get(path).raise_for_status().json())
        page.route(re.compile(re.escape(path) + r"(?:\?|$)"), legacy)
        page.goto(f"{workspace_url}/interviews/review/?id={sid}")
        scores = page.get_by_role("region", name="Session scorecard panel")
        notes = scores.get_by_role("region", name="Panel handoff notes")
        note = notes.get_by_role("textbox", name="Handoff note", exact=True)
        note.fill("Private legacy draft.")
        expect(notes.get_by_text(old["body"], exact=True)).to_be_visible()
        scores.get_by_label("Rationale for Legacy grade").fill("Changed.")
        scores.get_by_role("button", name="Save scorecard").click()
        retry = scores.get_by_role("button", name="Reload scorecard")
        expect(retry).to_be_visible()
        expect(note).to_have_value("Private legacy draft.")
        deny_read = True
        retry.click()
        expect(notes).to_have_count(0)
        assert old["body"] not in scores.inner_html() and "Private legacy draft." not in scores.inner_html()
        client.delete(note_path + "/" + old["id"]).raise_for_status()
        client.post(note_path, json={"category": "decision", "body": "Freshly authorized note."}).raise_for_status()
        deny_read = False
        retry.click()
        expect(notes.get_by_text("Freshly authorized note.", exact=True)).to_be_visible()
        expect(note).to_have_value("")
        assert writes == ["PUT"]
