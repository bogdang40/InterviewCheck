"""Withhold stale private controls and distinguish read-only matching content from a Keep receipt."""
from uuid import uuid4

import httpx
import pytest
from playwright.sync_api import expect

from test_deferred_questions_ui import REPEATED, drop_ack_then_read, keep_custom, open_queue, review_url, seed


def test_reloading_a_withheld_queue_removes_the_private_interview(workspace_url, browser_page):
    from api import answer_history, store
    from api.retention_anonymizer import SessionAnonymizer

    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path, (parent, _) = seed(client)
        page.goto(review_url(workspace_url, sid, parent["id"]))
        queue = open_queue(page)
        expect(queue.get_by_text("No deferred questions.", exact=True)).to_be_visible()
        expect(page.locator("body")).to_contain_text(parent["answer"])
        with store.connection(write=True) as db:
            SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=False, actor_email="fixture",
                                           now_iso=store.timestamp())
            answer_history.record(db, parent, "baseline")
        with page.expect_response(lambda response: path + "/deferred-questions?" in response.url) as loaded:
            queue.get_by_role("button", name="Reload questions").click()
        assert loaded.value.status == 409 and loaded.value.headers["x-interviewcheck-conflict"] == "interview-privacy"
        expect(page.get_by_role("region", name="Interview access changed")).to_be_visible()
        expect(queue).to_have_count(0)
        expect(page.locator("body")).not_to_contain_text(parent["answer"])


def test_json_restored_matching_item_does_not_confirm_the_original_keep(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as c:
        sid, path, (parent, _) = seed(c)
        page.goto(review_url(workspace_url, sid, parent["id"]))
        queue = open_queue(page)
        pattern = "**" + path + "/deferred-questions"
        attempts, handler = drop_ack_then_read(page, pattern, "POST")
        keep_custom(queue)
        expect(queue.get_by_role("button", name="Check saved question")).to_be_visible()
        original = attempts[0]["id"]
        raw = c.get("/api/backups/workspace").raise_for_status().content
        marker = c.post(path + "/trash").raise_for_status().json()
        c.post(f"/api/trash/{sid}/purge", json={"confirm_session_id": sid, "operation_version": marker["operation_version"]}).raise_for_status()
        preview = c.post("/api/backups/preview", content=raw).raise_for_status().json()
        c.post("/api/backups/restore", content=raw, headers={"X-Backup-Preview": preview["fingerprint"]}).raise_for_status()
        queue.get_by_role("button", name="Retry same question").click()
        expect(queue.get_by_role("status").filter(has_text="A matching saved question exists.")).to_be_visible()
        expect(queue.get_by_text("Question kept for later.", exact=True)).to_have_count(0)
        expect(queue.get_by_role("button", name="Keep for later", exact=True)).to_be_disabled()
        expect(queue.get_by_role("listitem").filter(has_text=REPEATED)).to_have_count(1)
        page.unroute(pattern, handler)
        saved, = c.get(path + "/deferred-questions").raise_for_status().json()["items"]
        assert len(attempts) == 1 and saved["id"] == original and saved["parent_answer_id"] == parent["id"]


@pytest.mark.parametrize(("editor", "at_final_write"), [(False, False), (True, False), (True, True)],
                         ids=["saved-list", "linked-draft", "retention-before-final-draft-put"])
def test_denied_source_reconfirmation_clears_parent_and_draft(workspace_url, browser_page, editor, at_final_write):
    from api import store
    from api.retention_anonymizer import SessionAnonymizer

    page = browser_page
    sensitive = "Private unsaved answer before retention."
    phrase = "Independent engineers measure characteristic spectral frequencies across controlled chamber boundaries"
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as c:
        sid, path, (parent, _) = seed(c)
        page.goto(review_url(workspace_url, sid, parent["id"]))
        queue = open_queue(page)
        keep_custom(queue)
        row = queue.get_by_role("listitem", name="Deferred question from exchange 1", exact=True)
        expect(row).to_be_visible()
        if editor:
            row.get_by_role("button", name="Open answer draft").click()
            page.get_by_label("Candidate answer").fill(sensitive)
            page.wait_for_function("value => Object.keys(localStorage).some(k => (localStorage.getItem(k) || '').includes(value))",
                                   arg=sensitive)
        changed = c.put(path + "/answers/" + parent["id"], json={"question": parent["question"], "answer": phrase,
                        "expected_revision": parent["revision"], "references": [
                        {"label": "Private comparison document", "text": phrase, "permitted": False}]}).raise_for_status().json()
        if editor:
            page.get_by_role("button", name="Save and compare", exact=True).click()
            check = page.get_by_role("region", name="Deferred draft source check")
        else:
            queue.get_by_role("button", name="Reload questions").click()
            check = row
        check.get_by_role("button", name="Review current source").click()
        source = check.get_by_role("region", name="Current source exchange")
        finding = changed["result"]
        assert finding["status"] == "match" and len(finding["passages"]) == 1
        expect(source.get_by_text("Passage match", exact=True)).to_be_visible()
        expect(source).to_contain_text(finding["explanation"])
        hit = finding["passages"][0]
        expect(source.locator("blockquote")).to_have_text([hit["answer_excerpt"], hit["source_excerpt"]])
        expect(source).to_contain_text(f'{hit["label"]} · {hit["words"]} matched words')
        other_key = "ic_draft_v1:" + str(uuid4()) + ":test"
        page.evaluate("k => localStorage.setItem(k, 'unrelated fixture')", other_key)
        question, = c.get(path + "/deferred-questions").raise_for_status().json()["items"]
        def erase():
            with store.connection(write=True) as db:
                SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=False, actor_email="operator@example.test",
                                               now_iso=store.timestamp())

        confirm = check.get_by_role("button", name="Confirm source and save this draft" if editor else "Confirm current source")
        if at_final_write:
            seen = []
            def observe(response):
                if response.url.endswith("/worksheet") and response.ok:
                    seen.append("source-read")
                if "/deferred-questions/" in response.url and response.request.method == "PATCH" and response.ok:
                    seen.append("reconfirmed")
            page.on("response", observe)
            def before_put(route):
                if route.request.method == "PUT":
                    assert route.request.post_data_json["deferred_question"]["id"] == question["id"]
                    assert seen == ["source-read", "reconfirmed"]
                    erase()
                    seen.append("erased")
                route.continue_()
            page.route("**" + path + "/draft", before_put)
            with page.expect_response(lambda r: r.url.endswith(path + "/draft") and r.request.method == "PUT") as denied:
                confirm.click()
            assert denied.value.status == 409
            assert denied.value.headers.get("x-interviewcheck-conflict") == "interview-privacy"
            assert seen == ["source-read", "reconfirmed", "erased"]
        else:
            erase()
            confirm.click()
        gate = page.get_by_role("region", name="Interview access changed")
        expect(gate.get_by_role("alert")).to_be_visible()
        expect(page.locator("#deferred-questions")).to_have_count(0)
        expect(page.get_by_label("Candidate answer")).to_have_count(0)
        expect(page.get_by_text(phrase, exact=False)).to_have_count(0)
        assert page.evaluate("sid => Object.keys(localStorage).every(k => !k.startsWith('ic_draft_v1:' + sid + ':'))", sid)
        assert page.evaluate("k => localStorage.getItem(k)", other_key) == "unrelated fixture"
        gate.get_by_role("button", name="Reload interview").click()
        expect(page.get_by_text("Retention anonymized this interview.", exact=False)).to_be_visible()
        assert c.get(path + "/draft").status_code == 403
        with store.connection() as db:
            assert db.execute("SELECT count(*) FROM session_drafts WHERE session_id=?", (sid,)).fetchone()[0] == 0


def test_discard_holds_draft_lifetime_even_when_question_binding_is_identical(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as c:
        sid, path, (parent, _) = seed(c)
        page.goto(review_url(workspace_url, sid, parent["id"]))
        queue = open_queue(page)
        keep_custom(queue)
        queue.get_by_role("button", name="Open answer draft").click()
        expect(page.get_by_label("Candidate answer")).to_be_visible()
        page.get_by_role("button", name="Cancel", exact=True).click()
        discard = page.get_by_role("button", name="Discard saved draft")
        discard.click()
        old = c.get(path + "/draft").raise_for_status().json()
        c.post(path + "/draft/discard", json={"id": old["id"], "expected_revision": old["revision"],
               "deferred_question": old["deferred_question"], "deferred_draft_token": old["deferred_draft_token"]}).raise_for_status()
        rebuilt = c.put(path + "/draft", json={"id": old["id"], "expected_revision": 0, "question": old["question"],
            "answer": "Another saved draft lifetime.", "parent_answer_id": old["parent_answer_id"],
            "deferred_question": old["deferred_question"], "planned_slot": None, "references": []}).raise_for_status().json()
        assert rebuilt["id"] == old["id"] and rebuilt["revision"] == old["revision"]
        assert rebuilt["deferred_question"] == old["deferred_question"] and rebuilt["deferred_draft_token"] != old["deferred_draft_token"]
        writes = []
        page.on("request", lambda req: writes.append(req.post_data_json) if req.url.endswith(path + "/draft/discard") else None)
        page.get_by_role("button", name="Confirm discard").click()
        expect(page.get_by_text("The saved draft changed. Review the current draft before confirming a discard.")).to_be_visible()
        assert c.get(path + "/draft").json() == rebuilt
        discard.click()
        page.get_by_role("button", name="Confirm discard").click()
        expect(discard).to_have_count(0)
        assert [w["deferred_draft_token"] for w in writes] == [old["deferred_draft_token"], rebuilt["deferred_draft_token"]]
