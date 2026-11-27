"""A pending question handoff follows the current queue and the interview's read permission."""
from urllib.parse import parse_qs, urlsplit

import pytest
from playwright.sync_api import expect

from e2e_suite.question_handoff_fixture import (
    PRIVATE, SHARED, Observed, controls, disabled_transfer, records, show_preview, state, toggle,
)

pytestmark = pytest.mark.tier3


def add_retention_hold(ws, sid, answer):
    from api import store
    from api.retention_anonymizer import SessionAnonymizer

    with store.connection(ws.review_db, write=True) as db:
        SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=False, actor_email="fixture@example.test",
                                       now_iso=store.timestamp())
        # A synthetic historical copy contains the former answer alongside the erasure receipt.
        db.execute("UPDATE answers SET answer=? WHERE session_id=? AND id=?", (answer["answer"], sid, answer["id"]))


@pytest.mark.parametrize("scenario", ["unsupported", "fallback_hold", "reload_hold"])
def test_pending_read_distinguishes_missing_capability_from_private_interview(e2e_workspace, desktop_page, scenario):
    ws = e2e_workspace
    page, collector = desktop_page
    with records(ws, page, 2) as (_, sid, path, parents, _items):
        observed = Observed(page, ws.base_url, path)
        queue, handoff = controls(page, ws.base_url, sid, parents[0])
        toggle(page, queue, 1, SHARED)
        if scenario == "unsupported":
            action = handoff.get_by_role("button", name="Preview selected questions")
            missing = observed.preview_path
        else:
            show_preview(page, handoff, observed, f"1. {SHARED}\n")
            add_retention_hold(ws, sid, parents[0])
            if scenario == "fallback_hold":
                action = handoff.get_by_role("button", name="Copy text", exact=True)
                missing = observed.verify_path
            else:
                action = queue.get_by_role("button", name="Reload questions")
                missing = None
        if missing:
            # Simulate just the absent handoff endpoint. The permission check reaches the actual API.
            page.route(ws.base_url + missing, lambda route: route.fulfill(status=404, json={"detail": "Not Found"}))
        before = state(ws.review_db, sid)
        collector.assert_clean()
        with page.expect_response(lambda r: r.request.method == "GET" and urlsplit(r.url).path == path + "/deferred-questions"
                                  and parse_qs(urlsplit(r.url).query).get("status") == ["pending"]) as checked:
            action.click()
        reply = checked.value
        candidate = page.get_by_role("heading", name=PRIVATE["candidate"], exact=True)
        if scenario == "unsupported":
            assert reply.status == 200 and reply.json()["pending_count"] == 2
            expect(handoff.get_by_role("alert")).to_contain_text("does not support pending question handoffs")
            expect(candidate).to_be_visible()
            expect(queue.get_by_text(SHARED, exact=True)).to_be_visible()
            allowed_errors = ("404",)
        else:
            assert reply.status == 409 and reply.headers.get("x-interviewcheck-conflict") == "interview-privacy"
            expect(page.get_by_role("region", name="Interview access changed")).to_be_visible()
            expect(candidate).to_have_count(0)
            expect(queue).to_have_count(0)
            for text in (SHARED, parents[0]["answer"], PRIVATE["draft"]):
                expect(page.locator("main")).not_to_contain_text(text)
            allowed_errors = ("404", "409") if missing else ("409",)
        expect(page.get_by_role("textbox", name="Exact handoff text")).to_have_count(0)
        disabled_transfer(page, handoff)
        calls = [route for route, _ in observed.calls]
        assert calls == ([observed.preview_path, observed.verify_path] if scenario == "fallback_hold" else [observed.preview_path])
        assert observed.downloads == [] and page.evaluate("window.handoffCopies") == []
        assert state(ws.review_db, sid) == before
        observed.assert_private()
        assert not collector.page_errors and not collector.server_errors
        assert all(any(status in msg for status in allowed_errors) for msg in collector.console_errors), collector.console_errors
        collector.reset()


def test_local_dismissal_updates_only_the_selected_question(e2e_workspace, desktop_page):
    ws = e2e_workspace
    page, collector = desktop_page
    with records(ws, page, 14) as (client, sid, path, parents, items):
        observed = Observed(page, ws.base_url, path)
        queue, handoff = controls(page, ws.base_url, sid, parents[0])
        before = state(ws.review_db, sid)
        later = items[13]["question"]
        next_page = queue.get_by_role("button", name="Next questions")
        toggle(page, queue, 1, SHARED)
        next_page.click()
        toggle(page, queue, 2, SHARED)
        toggle(page, queue, 1, later)
        queue.get_by_role("button", name="Previous questions").click()
        approved = show_preview(page, handoff, observed, f"1. {SHARED}\n2. {SHARED}\n3. {later}\n")

        def dismiss(item):
            row = queue.get_by_role("listitem", name="Deferred question from exchange 1", exact=True)
            row = row.filter(has=page.get_by_text(item["question"], exact=True))
            with page.expect_response(lambda r: r.request.method == "PATCH" and
                                      urlsplit(r.url).path == path + "/deferred-questions/" + item["id"]) as changed:
                row.get_by_role("button", name="Dismiss question").click()
            assert changed.value.status == 200 and changed.value.json()["status"] == "dismissed"

        dismiss(items[1])
        expect(queue.get_by_text(items[1]["question"], exact=True)).to_have_count(0)
        expect(handoff.get_by_role("textbox", name="Exact handoff text")).to_have_value(approved["text"])
        expect(handoff.get_by_role("button", name="Copy text", exact=True)).to_be_enabled()
        collection = path + "/deferred-questions"
        # Dismissing an earlier question moves the duplicate from exchange 2 onto page one.
        sibling = queue.get_by_role("listitem", name="Deferred question from exchange 2", exact=True)
        expect(sibling.get_by_role("checkbox")).to_be_checked()
        # The acknowledged dismissal must take effect even while the next list reply is pending.
        page.evaluate("""path => {
            const send = window.fetch.bind(window);
            const displayList = new Promise(resolve => { window.releaseQueueRead = resolve; });
            window.fetch = async (input, init) => {
                const url = new URL(input instanceof Request ? input.url : input, location.href);
                if (url.pathname !== path || (init?.method ?? 'GET') !== 'GET') return send(input, init);
                window.fetch = send;
                const reply = await send(input, init);
                await displayList;
                return reply;
            };
        }""", collection)
        dismiss(items[0])
        expect(handoff.get_by_text("2 of 50 questions selected", exact=True)).to_be_visible()
        expect(handoff.get_by_role("textbox", name="Exact handoff text")).to_have_count(0)
        disabled_transfer(page, handoff)
        assert [route for route, _ in observed.calls] == [observed.preview_path]
        page.evaluate("window.releaseQueueRead()")
        expect(sibling.get_by_role("checkbox")).to_be_checked()
        next_page.click()
        last = queue.get_by_role("listitem").filter(has=page.get_by_text(later, exact=True))
        expect(last.get_by_role("checkbox")).to_be_checked()
        show_preview(page, handoff, observed, f"1. {SHARED}\n2. {later}\n")
        selected_ids = {r["id"] for r in observed.calls[-1][1]["items"]}
        assert selected_ids == {items[10]["id"], items[13]["id"]}
        assert [r for r, _ in observed.calls] == [observed.preview_path, observed.preview_path]
        assert observed.workspace_writes == [("PATCH", collection + "/" + item["id"]) for item in (items[1], items[0])]
        after = state(ws.review_db, sid)
        assert after["deferred"] != before["deferred"]
        assert {key: value for key, value in after.items() if key != "deferred"} == {
            key: value for key, value in before.items() if key != "deferred"}
        assert client.get(collection + "/" + items[10]["id"]).raise_for_status().json()["status"] == "pending"
        assert not observed.external and not observed.downloads and page.evaluate("window.handoffCopies") == []
        collector.assert_clean()
