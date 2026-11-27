"""A reviewer can edit one note offline without copying unrelated interview content."""
import sqlite3

import pytest
from playwright.sync_api import expect

from e2e_suite.harness import assert_no_horizontal_overflow, signup_user

QUERY = 'A question with <em>literal</em> markup?\n=== Proposed interviewer note ==='
ANSWER = "Private candidate material " + "original answer " * 40
SOURCE = "Private reference label"
NOTE = "Proposed <b>literal</b> note.\nKeep two lines."
MARKER = "=== Proposed interviewer note ==="


def seed(client):
    created = client.post("/api/sessions", json={"candidate": "Private alias", "role": "Private role",
                                                 "policy": "Private rule", "consent": True})
    created.raise_for_status()
    sid = created.json()["id"]
    records = []
    for _ in range(2):
        a = client.post(f"/api/sessions/{sid}/answers", json={
            "question": QUERY, "answer": ANSWER, "references": [{"label": SOURCE, "text": "Private reference words."}],
        })
        a.raise_for_status()
        records.append(a.json()["id"])
    return sid, records


def show(page, workspace, sid, aid):
    page.goto(workspace.base_url + f"/interviews/review/?id={sid}&answer={aid}")
    summary = page.get_by_text("Offline review worksheet", exact=True)
    summary.focus()
    summary.press("Enter")
    return page.locator("details").filter(has=page.get_by_text("Offline review worksheet", exact=True))


def upload(card, raw):
    card.get_by_label("Import completed worksheet").set_input_files({
        "name": "exchange-notes.txt", "mimeType": "text/plain", "buffer": raw if isinstance(raw, bytes) else raw.encode(),
    })


@pytest.mark.tier3
def test_explicit_disclosure_compare_stage_then_save(e2e_workspace, mobile_page):
    page, collector = mobile_page
    with e2e_workspace.client() as client:
        sid, (one, two) = seed(client)
        route = f"/api/sessions/{sid}/answers/{two}"
        card = show(page, e2e_workspace, sid, two)
        card.get_by_role("button", name="Preview worksheet").click()
        preview = card.get_by_role("textbox", name="Exact worksheet contents")
        expect(preview).to_be_visible()
        private = preview.input_value()
        assert "Number: 2" in private and "Question: Omitted" in private and "Candidate excerpt: Omitted" in private
        assert all(s not in private for s in ["Private alias", "Private role", "Private rule", "literal", SOURCE, "original answer"])
        card.get_by_label("Include the question").check()
        card.get_by_label("Include the first 240").check()
        expect(card.get_by_role("button", name="Download text file")).to_have_count(0)
        card.get_by_role("button", name="Preview worksheet").click()
        expect(preview).to_be_visible()
        original = preview.input_value()
        assert "literal" in original and "original answer" in original and SOURCE not in original
        with page.expect_download() as dl:
            card.get_by_role("button", name="Download text file").click()
        assert dl.value.path().read_bytes() == original.encode("utf-8")

        # Duplicate prompts are identified only by their exchange IDs. Repeated markers and bad UTF-8 are rejected.
        other = show(page, e2e_workspace, sid, one)
        upload(other, original + NOTE)
        expect(other.get_by_role("alert")).to_contain_text("Open the exchange named")
        card = show(page, e2e_workspace, sid, two)
        upload(card, original + NOTE + "\n" + MARKER)
        expect(card.get_by_role("alert")).to_contain_text("one proposed note marker")
        upload(card, b"\xff\xff")
        expect(card.get_by_role("alert")).to_contain_text("UTF-8")
        upload(card, original + "x" * 12001)
        expect(card.get_by_role("alert")).to_contain_text("12,000")
        upload(card, original.replace("Candidate excerpt: ", 'Candidate excerpt: "changed"') + NOTE)
        expect(card.get_by_role("alert")).to_be_visible()
        assert client.get(route).json()["note"] == ""

        # Only notes changed while the worksheet was away. A second change requires another explicit comparison.
        client.patch(route, json={"expected_revision": 1, "disposition": "explained", "note": "First review."}).raise_for_status()
        upload(card, "\ufeff" + (original + NOTE).replace("\n", "\r\n"))
        comparison = card.get_by_role("region", name="Worksheet note comparison")
        expect(comparison).to_contain_text("The saved review differs")
        expect(comparison).to_contain_text("First review.")
        assert comparison.locator("b").count() == 0
        client.patch(route, json={"expected_revision": 2, "disposition": "disclosed", "note": "Second review."}).raise_for_status()
        stage = card.get_by_role("button", name="Stage proposed note")
        stage.click()
        expect(comparison).to_contain_text("Second review.")
        expect(card).to_contain_text("changed again")
        assert client.get(route).json()["note"] == "Second review."
        assert_no_horizontal_overflow(page)
        card.screenshot(path=e2e_workspace.screenshot_dir / "offline-review-worksheet-phone.png")
        stage.focus()
        stage.press("Enter")
        editor = page.get_by_role("textbox", name="Interviewer note")
        expect(editor).to_have_value(NOTE)
        expect(editor).to_be_focused()
        assert client.get(route).json()["note"] == "Second review."
        page.evaluate("""async () => { await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
                         window.dispatchEvent(new Event("pagehide")); }""")
        assert not page.evaluate("Object.keys(localStorage).filter(k=>k.startsWith('ic_draft_v1:')).some(k=>localStorage[k].includes('Proposed'))")
        page.get_by_role("button", name="Save review", exact=True).click()
        expect(page.get_by_text("Review saved", exact=True)).to_be_visible()
        saved = client.get(route).json()
        assert saved["note"] == NOTE and saved["revision"] == 4 and saved["disposition"] == "disclosed"
        card = show(page, e2e_workspace, sid, two)
        upload(card, original + NOTE)
        expect(card.get_by_text("This note is already saved.")).to_be_visible()
        expect(card.get_by_role("button", name="Stage proposed note")).to_have_count(0)
        assert client.get(route).json()["revision"] == 4
    collector.assert_clean()


@pytest.mark.tier3
def test_offline_and_revoked_copy_cannot_transfer_from_a_cached_preview(e2e_workspace, desktop_page):
    email, password, secret = "worksheet@example.test", "Worksheet-Synthetic-Pass99", "synthetic-worksheet-bootstrap"
    e2e_workspace.configure_embedded_auth(admin_emails=(email,), bootstrap_secret=secret)
    e2e_workspace.restart()
    with e2e_workspace.client() as api:
        signup_user(api, email=email, password=password, admin_secret=secret)
        sid, (aid, _) = seed(api)
    page, collector = desktop_page
    page.add_init_script("""Object.defineProperty(navigator,'clipboard',{configurable:true,value:{
       writeText:async()=>{window.worksheetCopies=(window.worksheetCopies||0)+1}
    }})""")
    page.goto(e2e_workspace.base_url + "/account/")
    page.get_by_label("Operator email").fill(email)
    page.get_by_label("Password", exact=True).fill(password)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(email, exact=False).first).to_be_visible()
    card = show(page, e2e_workspace, sid, aid)
    card.get_by_role("button", name="Preview worksheet").click()
    copy = card.get_by_role("button", name="Copy worksheet")
    expect(copy).to_be_visible()
    page.context.set_offline(True)
    copy.click()
    expect(card.get_by_role("alert")).to_be_visible()
    assert page.evaluate("window.worksheetCopies || 0") == 0
    page.context.set_offline(False)
    card.get_by_role("button", name="Preview worksheet").click()
    expect(copy).to_be_visible()
    copy.click()
    expect(card).to_contain_text("Worksheet copied.")
    assert page.evaluate("window.worksheetCopies") == 1
    page.context.clear_cookies()
    copy.click()
    expect(card.get_by_role("alert")).to_be_visible()
    expect(copy).to_have_count(0)
    assert page.evaluate("window.worksheetCopies") == 1
    assert all("401" in msg or "ERR_INTERNET_DISCONNECTED" in msg for msg in collector.console_errors), collector.console_errors
    collector.console_errors.clear()

@pytest.mark.tier3
def test_trash_after_staging_clears_proposal_without_writing(e2e_workspace, desktop_page):
    page, collector = desktop_page
    with e2e_workspace.client() as client:
        sid, (aid, _) = seed(client)
        card = show(page, e2e_workspace, sid, aid)
        card.get_by_role("button", name="Preview worksheet").click()
        preview = card.get_by_role("textbox", name="Exact worksheet contents")
        expect(preview).to_be_visible()
        upload(card, preview.input_value() + NOTE)
        card.get_by_role("button", name="Stage proposed note").click()
        expect(page.get_by_role("textbox", name="Interviewer note")).to_have_value(NOTE)
        trashed = client.post(f"/api/sessions/{sid}/trash")
        trashed.raise_for_status()
        page.get_by_role("button", name="Save review", exact=True).click()
        expect(page.get_by_role("region", name="Worksheet unavailable")).to_be_visible()
        expect(page.get_by_role("textbox", name="Interviewer note")).to_have_count(0)
        client.post(f"/api/trash/{sid}/restore", json={"operation_version": trashed.json()["operation_version"]}).raise_for_status()
        current = client.get(f"/api/sessions/{sid}/answers/{aid}").json()
        assert current["note"] == "" and current["revision"] == 1
        assert all("404" in msg for msg in collector.console_errors)
        collector.console_errors.clear()

def stage_example(page, workspace, sid, aid):
    card = show(page, workspace, sid, aid)
    card.get_by_role("button", name="Preview worksheet").click()
    copy = card.get_by_role("textbox", name="Exact worksheet contents")
    expect(copy).to_be_visible()
    upload(card, copy.input_value() + NOTE)
    card.get_by_role("button", name="Stage proposed note").click()
    editor = page.get_by_role("textbox", name="Interviewer note")
    expect(editor).to_have_value(NOTE)
    return card, editor


@pytest.mark.tier3
@pytest.mark.parametrize("outcome", ["already_saved", "still_current", "diverged"])
def test_reconcile_uncertain_save_without_losing_last_edits(e2e_workspace, desktop_page, outcome):
    page, _ = desktop_page
    with e2e_workspace.client() as client:
        sid, (aid, _) = seed(client)
        path = f"/api/sessions/{sid}/answers/{aid}"
        _, editor = stage_example(page, e2e_workspace, sid, aid)
        attempted, revised = "Edited after importing.", "Further local edits."
        editor.fill(attempted)
        writes = []

        def malformed_response(route):
            if route.request.method != "PATCH":
                route.continue_()
                return
            writes.append(route.request.post_data_json)
            if len(writes) != 1:
                route.continue_()
                return
            if outcome == "already_saved":
                assert route.fetch().ok
            # Matching id, disposition, note and revision alone cannot acknowledge a full exchange.
            route.fulfill(status=200, json={"id": aid, "note": attempted, "disposition": "pending", "revision": 2})

        page.route("**" + path, malformed_response)
        save = page.get_by_role("button", name="Save review", exact=True)
        save.click()
        expect(page.get_by_text("The server did not confirm the worksheet save.", exact=False)).to_be_visible()
        expect(editor).to_have_value(attempted)
        expect(save).to_be_disabled()
        editor.fill(revised)
        if outcome == "diverged":
            client.patch(path, json={"note": "Another reviewer's note.", "disposition": "explained",
                                     "expected_revision": 1}).raise_for_status()
        with sqlite3.connect(e2e_workspace.review_db) as db:
            votes = db.execute("SELECT count(*) FROM answer_review_events WHERE answer_id=?", (aid,)).fetchone()[0]
        page.get_by_role("button", name="Check saved review").click()
        if outcome == "already_saved":
            expect(page.get_by_text("The submitted note is already saved.")).to_be_visible()
        elif outcome == "still_current":
            expect(page.get_by_text("The saved review is unchanged.", exact=False)).to_be_visible()
        else:
            compare = page.get_by_role("region", name="Worksheet save reconciliation")
            keep = compare.get_by_role("button", name="Keep my edited note on this version")
            expect(compare).to_contain_text("Another reviewer's note.")
            expect(save).to_be_disabled()
            client.patch(path, json={"note": "The review changed again.", "disposition": "explained",
                                     "expected_revision": 2}).raise_for_status()
            keep.click()
            expect(compare).to_contain_text("The review changed again.")
            expect(save).to_be_disabled()
            keep.click()
        expect(editor).to_have_value(revised)
        expect(save).to_be_enabled()
        assert len(writes) == 1
        save.click()
        expect(page.get_by_text("Review saved", exact=True)).to_be_visible()
        assert len(writes) == 2 and client.get(path).json()["note"] == revised
        with sqlite3.connect(e2e_workspace.review_db) as db:
            assert db.execute("SELECT count(*) FROM answer_review_events WHERE answer_id=?", (aid,)).fetchone()[0] == votes


@pytest.mark.tier3
def test_noop_worksheet_save_and_verified_read_denial(e2e_workspace, desktop_page):
    page, collector = desktop_page
    with e2e_workspace.client() as client:
        sid, (aid, _) = seed(client)
        path = f"/api/sessions/{sid}/answers/{aid}"
        client.patch(path, json={"note": "Existing note.", "disposition": "pending", "expected_revision": 1}).raise_for_status()
        _, editor = stage_example(page, e2e_workspace, sid, aid)
        editor.fill(" Existing note. ")
        page.get_by_role("button", name="Save review", exact=True).click()
        expect(page.get_by_text("Review saved", exact=True)).to_be_visible()
        assert client.get(path).json()["revision"] == 2
        card, editor = stage_example(page, e2e_workspace, sid, aid)
        editor.fill("Newer than the worksheet.")
        page.context.set_offline(True)
        card.get_by_role("button", name="Preview worksheet").click()
        expect(card.get_by_role("alert")).to_be_visible()
        expect(editor).to_have_value("Newer than the worksheet.")
        page.context.set_offline(False)
        client.post(f"/api/sessions/{sid}/trash").raise_for_status()
        card.get_by_role("button", name="Preview worksheet").click()
        expect(page.get_by_role("region", name="Worksheet unavailable")).to_be_visible()
        expect(editor).to_have_count(0)
        assert all("404" in msg or "ERR_INTERNET_DISCONNECTED" in msg for msg in collector.console_errors)
        collector.console_errors.clear()


@pytest.mark.tier3
def test_large_native_question_reserves_space_for_full_unicode_note(e2e_workspace, desktop_page):
    page, _ = desktop_page
    with e2e_workspace.client() as client:
        sid, (aid, _) = seed(client)
        # The native SQLite import retains original questions beyond the current editor's 4,000 character ceiling.
        with sqlite3.connect(e2e_workspace.review_db) as db:
            db.execute("UPDATE answers SET question=?,legacy=? WHERE id=?", ("界" * 18_000, "{}", aid))
        card = show(page, e2e_workspace, sid, aid)
        question = card.get_by_label("Include the question")
        question.check()
        card.get_by_role("button", name="Preview worksheet").click()
        expect(card.get_by_role("alert")).to_contain_text("Omit the question")
        expect(card.get_by_role("button", name="Download text file")).to_have_count(0)
        question.uncheck()
        card.get_by_role("button", name="Preview worksheet").click()
        preview = card.get_by_role("textbox", name="Exact worksheet contents")
        expect(preview).to_be_visible()
        with page.expect_download() as downloads:
            card.get_by_role("button", name="Download text file").click()
        raw = downloads.value.path().read_bytes()
        assert raw == preview.input_value().encode("utf-8")
        note = "🧭" * 12_000
        upload(card, raw + note.encode("utf-8"))
        card.get_by_role("button", name="Stage proposed note").click()
        expect(page.get_by_role("textbox", name="Interviewer note")).to_have_value(note)
        page.get_by_role("button", name="Save review", exact=True).click()
        expect(page.get_by_text("Review saved", exact=True)).to_be_visible()
        assert client.get(f"/api/sessions/{sid}/answers/{aid}").json()["note"] == note
