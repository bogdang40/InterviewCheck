"""Exercise the Chromium clipboard on a disposable runner and the denied permission fallback everywhere."""
import os
from urllib.parse import urlsplit

import pytest
from playwright.sync_api import expect

from e2e_suite.question_handoff_fixture import SHARED, Observed, controls, records, show_preview, state, toggle

pytestmark = pytest.mark.tier3


def click_copy(page, handoff, observed, approved):
    with page.expect_response(lambda r: urlsplit(r.url).path == observed.verify_path) as check:
        handoff.get_by_role("button", name="Copy text", exact=True).click()
    assert check.value.status == 200 and check.value.json() == approved


@pytest.mark.skipif(
    os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted",
    reason="Reading the native clipboard requires a disposable GitHub hosted runner",
)
def test_copy_reads_back_from_disposable_chromium_clipboard(e2e_workspace, desktop_page):
    ws = e2e_workspace
    page, collector = desktop_page
    with records(ws, page, 1) as (_, sid, path, parents, _items):
        observed = Observed(page, ws.base_url, path, capture_clipboard=False)
        queue, handoff = controls(page, ws.base_url, sid, parents[0])
        before = state(ws.review_db, sid)
        toggle(page, queue, 1, SHARED)
        approved = show_preview(page, handoff, observed, f"1. {SHARED}\n")
        page.bring_to_front()
        page.context.grant_permissions(["clipboard-read", "clipboard-write"], origin=ws.base_url)
        # Replace any previous content without reading it. A failed write stops the test before readback.
        page.evaluate("() => navigator.clipboard.writeText('Synthetic clipboard test precondition')")
        click_copy(page, handoff, observed, approved)
        expect(handoff.get_by_text("Handoff copied.", exact=True)).to_be_visible()
        text = approved["text"]
        acceptable = {text, text.replace("\n", "\r\n")} if os.name == "nt" else {text}
        assert page.evaluate("() => navigator.clipboard.readText()") in acceptable
        assert [route for route, _ in observed.calls] == [observed.preview_path, observed.verify_path]
        assert observed.downloads == []
        assert state(ws.review_db, sid) == before
        observed.assert_private()
        collector.assert_clean()


def test_clipboard_permission_denial_waits_for_explicit_verified_download(e2e_workspace, desktop_page):
    ws = e2e_workspace
    page, collector = desktop_page
    with records(ws, page, 1) as (_, sid, path, parents, _items):
        observed = Observed(page, ws.base_url, path)
        queue, handoff = controls(page, ws.base_url, sid, parents[0])
        before = state(ws.review_db, sid)
        # Reject at the clipboard adapter boundary so this also runs on a developer's machine.
        page.evaluate("""() => {
            window.handoffDeniedAttempts = 0;
            navigator.clipboard.writeText = async () => {
                window.handoffDeniedAttempts++;
                throw new DOMException('Clipboard permission denied', 'NotAllowedError');
            };
        }""")
        toggle(page, queue, 1, SHARED)
        approved = show_preview(page, handoff, observed, f"1. {SHARED}\n")
        click_copy(page, handoff, observed, approved)
        expect(handoff.get_by_role("alert")).to_have_text("Clipboard access failed. Use Download text file to save the verified handoff.")
        expect(handoff.get_by_role("textbox", name="Exact handoff text")).to_have_value(approved["text"])
        assert observed.downloads == [] and page.evaluate("window.handoffDeniedAttempts") == 1
        assert [route for route, _ in observed.calls] == [observed.preview_path, observed.verify_path]

        with page.expect_download() as download, page.expect_response(lambda r: urlsplit(r.url).path == observed.verify_path) as check:
            handoff.get_by_role("button", name="Download text file", exact=True).click()
        assert check.value.status == 200 and check.value.json() == approved
        assert download.value.suggested_filename == "pending-questions.txt"
        assert download.value.path().read_bytes() == approved["text"].encode("utf-8")
        assert len(observed.downloads) == 1 and page.evaluate("window.handoffDeniedAttempts") == 1
        assert [route for route, _ in observed.calls] == [observed.preview_path, observed.verify_path, observed.verify_path]
        assert state(ws.review_db, sid) == before
        observed.assert_private()
        collector.assert_clean()
