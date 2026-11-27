"""A user can transfer only the pending questions whose current versions they selected."""
from urllib.parse import urlsplit

import pytest
from playwright.sync_api import expect

from e2e_suite.harness import assert_no_horizontal_overflow
from e2e_suite.question_handoff_fixture import (
    EMAIL, HEADERS, PRIVATE, SECOND, SHARED, Observed, controls, disabled_transfer, records, show_preview, state, toggle,
)

pytestmark = pytest.mark.tier3


def test_scoped_handoff_keyboard_paging_exact_clipboard_and_file(e2e_workspace, mobile_page):
    page, collector = mobile_page
    ws = e2e_workspace
    with records(ws, page, 12) as (client, sid, path, parents, items):
        observation = Observed(page, ws.base_url, path)
        queue, handoff = controls(page, ws.base_url, sid, parents[0])
        before = state(ws.review_db, sid)
        assert before["votes"][0] == 2 and before["drafts"][0] == 1 and before["scorecard"][0] == 1
        disabled_transfer(page, handoff)
        expect(handoff.get_by_role("button", name="Preview selected questions", exact=True).and_(page.locator(":enabled"))).to_have_count(0)
        expect(handoff.get_by_role("textbox", name="Exact handoff text")).to_have_count(0)
        expect(queue.get_by_role("checkbox", checked=True)).to_have_count(0)

        next_page = queue.get_by_role("button", name="Next questions")
        next_page.focus()
        page.keyboard.press("Enter")
        expect(toggle(page, queue, 2, SHARED)).to_be_checked()
        previous = queue.get_by_role("button", name="Previous questions")
        previous.focus()
        page.keyboard.press("Enter")
        expect(toggle(page, queue, 1, SHARED)).to_be_checked()
        expect(toggle(page, queue, 1, SECOND)).to_be_checked()
        next_page.click()
        expect(queue.get_by_role("checkbox", name="Include question from exchange 2", exact=True)).to_be_checked()
        previous.click()
        assert observation.calls == [] and observation.downloads == [] and page.evaluate("window.handoffCopies") == []
        disabled_transfer(page, handoff)

        expected_text = f"1. {SHARED}\n2. {SECOND}\n3. {SHARED}\n"
        approved = show_preview(page, handoff, observation, expected_text)
        chosen = [items[i] for i in (0, 3, 10)]
        private = [*PRIVATE.values(), EMAIL, sid, *[r["id"] for r in parents], *[r["id"] for r in items],
                   *[p["question"] for p in parents], *[p["answer"] for p in parents],
                   *[r["question"] for r in items if r not in chosen]]
        assert all(value not in approved["text"] for value in private)
        assert len(observation.calls) == 1 and len(observation.downloads) == 0 and page.evaluate("window.handoffCopies") == []
        assert state(ws.review_db, sid) == before
        assert_no_horizontal_overflow(page)
        handoff.screenshot(path=ws.screenshot_dir / "pending-question-handoff-phone.png")

        unselected = items[7]
        client.patch(path + "/deferred-questions/" + unselected["id"], json={"action": "dismiss",
                     "expected_version": unselected["version"]}).raise_for_status()
        after_peer = state(ws.review_db, sid)
        with page.expect_response(lambda r: urlsplit(r.url).path == observation.verify_path) as copy_check:
            handoff.get_by_role("button", name="Copy text", exact=True).click()
        assert copy_check.value.status == 200 and copy_check.value.json() == approved
        expect(handoff.get_by_text("Handoff copied.", exact=True)).to_be_visible()
        assert bytes(page.evaluate("window.handoffCopies[0]")) == expected_text.encode()
        with page.expect_download() as downloaded, page.expect_response(lambda r: urlsplit(r.url).path == observation.verify_path) as file_check:
            handoff.get_by_role("button", name="Download text file", exact=True).click()
        assert file_check.value.status == 200 and file_check.value.json() == approved
        assert downloaded.value.suggested_filename == "pending-questions.txt"
        assert downloaded.value.path().read_bytes() == bytes(page.evaluate("window.handoffCopies[0]")) == expected_text.encode()
        assert len(observation.downloads) == 1
        paths = [route for route, _ in observation.calls]
        assert paths == [observation.preview_path, observation.verify_path, observation.verify_path]
        for route, body in observation.calls:
            assert set(body) == ({"items"} if route == observation.preview_path else {"items", "preview_sha256"})
            assert all(set(item) == {"id", "version"} for item in body["items"])
            assert len(body["items"]) == 3
            assert {(r["id"], r["version"]) for r in body["items"]} == {(r["id"], r["version"]) for r in chosen}
            if route == observation.verify_path:
                assert body["preview_sha256"] == approved["sha256"]
        assert state(ws.review_db, sid) == after_peer
        expect(toggle(page, queue, 1, SECOND)).not_to_be_checked()
        expect(handoff.get_by_role("textbox", name="Exact handoff text")).to_have_count(0)
        disabled_transfer(page, handoff)
        handoff.get_by_role("button", name="Clear selection", exact=True).click()
        expect(queue.get_by_role("checkbox", checked=True)).to_have_count(0)
        assert len(observation.calls) == 3
        observation.assert_private()
        collector.assert_clean()


@pytest.mark.parametrize(("change", "action", "status"), [
    ("selected", "Download text file", 409), ("retention", "Copy text", 403),
    ("trash", "Download text file", 404), ("logout", "Copy text", 401),
])
def test_change_after_preview_refuses_transfer_and_erases_preview(e2e_workspace, desktop_page, change, action, status):
    from api import store
    from api.retention_anonymizer import SessionAnonymizer

    ws = e2e_workspace
    page, collector = desktop_page
    with records(ws, page, 2) as (client, sid, path, parents, items):
        observed = Observed(page, ws.base_url, path)
        queue, handoff = controls(page, ws.base_url, sid, parents[0])
        toggle(page, queue, 1, SHARED)
        show_preview(page, handoff, observed, f"1. {SHARED}\n")
        target = items[0]
        if change == "selected":
            client.patch(path + "/deferred-questions/" + target["id"], json={"action":"dismiss",
                         "expected_version":target["version"]}).raise_for_status()
        elif change == "retention":
            with store.connection(ws.review_db, write=True) as db:
                SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=False, actor_email="fixture@example.test",
                                               now_iso=store.timestamp())
        elif change == "trash":
            client.post(path + "/trash").raise_for_status()
        else:
            signed_out = page.request.post(ws.base_url + "/api/integrations/logout", headers=HEADERS)
            assert signed_out.ok and signed_out.json()["signed_out"] is True
        after_change = state(ws.review_db, sid)
        collector.assert_clean()
        with page.expect_response(lambda r: urlsplit(r.url).path == observed.verify_path) as rejected:
            handoff.get_by_role("button", name=action, exact=True).click()
        assert rejected.value.status == status and SHARED not in rejected.value.text()
        if change == "selected":
            expect(queue.get_by_role("checkbox", checked=True)).to_have_count(0)
            expect(queue.get_by_text(SHARED, exact=True)).to_have_count(0)
        else:
            expect(page.get_by_role("region", name="Interview access changed")).to_be_visible()
            expect(queue).to_have_count(0)
        expect(page.get_by_role("textbox", name="Exact handoff text")).to_have_count(0)
        disabled_transfer(page, handoff)
        assert page.evaluate("window.handoffCopies") == [] and observed.downloads == []
        assert [key for key, _ in observed.calls] == [observed.preview_path, observed.verify_path]
        assert state(ws.review_db, sid) == after_change
        observed.assert_private()
        assert not collector.page_errors and not collector.server_errors
        assert all(str(status) in error for error in collector.console_errors), collector.console_errors
        collector.reset()


def test_late_verified_reply_cannot_copy_a_replaced_selection(e2e_workspace, desktop_page):
    ws = e2e_workspace
    page, collector = desktop_page
    with records(ws, page, 4) as (_, sid, path, parents, _items):
        observed = Observed(page, ws.base_url, path)
        page.add_init_script("""(() => {
          const normal = window.fetch.bind(window);
          window.fetch = async (...args) => {
            const response = await normal(...args);
            if (!response.ok || !new URL(response.url).pathname.endsWith('/handoff/verify') || !window.holdHandoff) return response;
            const body = await response.text();
            await new Promise(resolve => { window.releaseHandoff = resolve; document.documentElement.dataset.handoffWaiting = "1"; });
            requestAnimationFrame(() => requestAnimationFrame(() => { document.documentElement.dataset.handoffReturned = "1"; }));
            return new Response(body,{status: response.status,headers: response.headers});
          };
        })()""")
        queue, handoff = controls(page, ws.base_url, sid, parents[0])
        before = state(ws.review_db, sid)
        toggle(page, queue, 1, SHARED)
        show_preview(page, handoff, observed, f"1. {SHARED}\n")
        page.evaluate("window.holdHandoff = true")
        handoff.get_by_role("button", name="Copy text", exact=True).click()
        try:
            expect(page.locator("html")).to_have_attribute("data-handoff-waiting", "1")
            expect(toggle(page, queue, 1, SHARED)).not_to_be_checked()
            expect(toggle(page, queue, 1, SECOND)).to_be_checked()
            disabled_transfer(page, handoff)
        finally:
            page.evaluate("() => { window.holdHandoff = false; window.releaseHandoff?.(); }")
        expect(page.locator("html")).to_have_attribute("data-handoff-returned", "1")
        show_preview(page, handoff, observed, f"1. {SECOND}\n")
        assert [key for key, _ in observed.calls] == [observed.preview_path, observed.verify_path, observed.preview_path]
        assert page.evaluate("window.handoffCopies") == [] and observed.downloads == []
        assert state(ws.review_db, sid) == before
        observed.assert_private()
        collector.assert_clean()


def test_selected_parent_note_edit_and_queue_reload_preserve_inspected_text(e2e_workspace, desktop_page):
    ws = e2e_workspace
    page, collector = desktop_page
    with records(ws, page, 2) as (client, sid, path, parents, items):
        seen = Observed(page, ws.base_url, path)
        queue, handoff = controls(page, ws.base_url, sid, parents[0])
        toggle(page, queue, 1, SHARED)
        inspected = show_preview(page, handoff, seen, f"1. {SHARED}\n")
        answer_path = path + "/answers/" + parents[0]["id"]
        old = client.get(answer_path).raise_for_status().json()
        before = state(ws.review_db, sid)
        changed_note = "A revised ordinary review note. Keep this out of the handoff."
        page.get_by_role("textbox", name="Interviewer note", exact=True).fill(changed_note)
        with page.expect_response(lambda r: r.request.method == "PATCH" and urlsplit(r.url).path == answer_path) as update:
            page.get_by_role("button", name="Save review", exact=True).click()
        assert update.value.status == 200
        expect(page.get_by_text("Review saved", exact=True)).to_be_visible()
        assert client.get(answer_path).json() == {**old, "revision": old["revision"] + 1, "note": changed_note}
        parent_state = state(ws.review_db, sid)
        assert parent_state["votes"] == before["votes"] and parent_state["history"][0] == before["history"][0] + 1
        assert parent_state["deferred"] == before["deferred"]
        current = client.get(path + "/deferred-questions/" + items[0]["id"]).raise_for_status().json()
        assert current["version"] == items[0]["version"] and not current["needs_reconfirmation"]

        with page.expect_response(lambda r: r.request.method == "GET" and urlsplit(r.url).path == path + "/deferred-questions"):
            queue.get_by_role("button", name="Reload questions", exact=True).click()
        expect(handoff.get_by_role("textbox", name="Exact handoff text")).to_have_value(inspected["text"])
        expect(queue.get_by_role("checkbox", name="Include question from exchange 1", checked=True)).to_have_count(1)
        with page.expect_response(lambda r: urlsplit(r.url).path == seen.verify_path) as verified:
            handoff.get_by_role("button", name="Copy text", exact=True).click()
        assert verified.value.status == 200 and verified.value.json() == inspected
        expect(handoff.get_by_text("Handoff copied.", exact=True)).to_be_visible()
        assert bytes(page.evaluate("window.handoffCopies[0]")) == inspected["text"].encode("utf-8")
        assert [url for url, _ in seen.calls] == [seen.preview_path, seen.verify_path]
        assert seen.workspace_writes == [("PATCH", answer_path)] and not seen.external and not seen.downloads
        assert state(ws.review_db, sid) == parent_state
        collector.assert_clean()
