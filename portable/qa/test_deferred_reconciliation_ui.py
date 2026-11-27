"""Exercise exact Keep, source and publication receipts when another tab changes the record."""
from uuid import uuid4

import httpx
from playwright.sync_api import expect

from test_deferred_questions_ui import REPEATED, drop_ack_then_read, keep_custom, open_queue, review_url, seed


def test_lost_keep_and_reconfirm_after_reference_permission_changes(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as c:
        session = c.post("/api/sessions", json={"candidate": "Source change fixture", "role": "Engineer", "policy": "Use published notes",
                    "consent": True, "permitted_sources": [{"label": "Interview handbook", "text": "Published reference instructions."}]}).raise_for_status().json()
        sid = session["id"]
        path = f"/api/sessions/{sid}"
        first = c.post(path + "/answers", json={"question": "What changed?", "answer": "We compared the instrument readings.",
                       "references": [{"label": "Earlier source", "text": "The earlier reference.", "permitted": False}]}).raise_for_status().json()
        parent = path + "/answers/" + first["id"]
        page.goto(review_url(workspace_url, sid, first["id"]))
        queue = open_queue(page)
        pattern = "**" + path + "/deferred-questions"
        posts, handler = drop_ack_then_read(page, pattern, "POST")
        keep_custom(queue)
        expect(queue.get_by_role("button", name="Retry same question")).to_be_visible()
        created, = c.get(path + "/deferred-questions").json()["items"]
        c.put(parent, json={"question": first["question"], "answer": first["answer"], "expected_revision": first["revision"],
                            "references": [{"label": "Current source", "text": "The revised reference text.", "permitted": True}]}).raise_for_status()
        queue.get_by_role("button", name="Retry same question").click()
        expect(queue.get_by_text("Question kept for later.", exact=True)).to_be_visible()
        assert len(posts) == 1 and posts[0]["id"] == created["id"]
        page.unroute(pattern, handler)
        row = queue.get_by_role("listitem", name="Deferred question from exchange 1", exact=True)
        row.get_by_role("button", name="Review current source").click()
        current = row.get_by_role("region", name="Current source exchange")
        expect(current).to_contain_text("Use published notes")
        current.get_by_text("Current source · Permitted", exact=True).click()
        expect(current.get_by_text("The revised reference text.", exact=True)).to_be_visible()
        current.get_by_text("Interview handbook", exact=True).click()
        expect(current.get_by_text("Published reference instructions.", exact=True)).to_be_visible()

        pattern += "/" + created["id"]
        mutations, handler = drop_ack_then_read(page, pattern, "PATCH")
        row.get_by_role("button", name="Confirm current source").click()
        expect(row.get_by_role("button", name="Open answer draft")).to_be_visible()
        assert len(mutations) == 1 and mutations[0]["action"] == "reconfirm"
        after, = c.get(path + "/deferred-questions").json()["items"]
        assert after["id"] == created["id"] and not after["needs_reconfirmation"] and after["version"] != created["version"]
        page.unroute(pattern, handler)


def test_identical_sibling_receipt_cannot_acknowledge_another_saved_question(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as c:
        sid, path, (parent, _) = seed(c)
        context = c.get(path + "/answers/" + parent["id"] + "/worksheet").raise_for_status().json()
        endpoint = path + "/deferred-questions"
        for _ in range(2):
            c.post(endpoint, json={"id": str(uuid4()), "parent_answer_id": parent["id"],
                                   "question": REPEATED, "expected_material": context["material"]}).raise_for_status()
        a, b = c.get(endpoint).json()["items"]
        page.goto(review_url(workspace_url, sid, parent["id"]))
        queue = open_queue(page)
        siblings = queue.get_by_role("listitem", name="Deferred question from exchange 1", exact=True)
        expect(siblings).to_have_count(2)
        siblings.nth(1).get_by_role("button", name="Open answer draft").click()
        typed = page.get_by_label("Candidate answer")
        typed.fill("  Response with outer whitespace.  ")
        pattern = "**" + path + "/draft/publish"
        def wrong_sibling(route):
            response = route.fetch()
            assert response.ok
            data = response.json()
            assert data["deferred_receipt"]["question_id"] == b["id"]
            data["deferred_receipt"]["question_id"] = a["id"]
            route.fulfill(status=200, json=data)
        page.route(pattern, wrong_sibling)
        submit = page.get_by_role("button", name="Save and compare", exact=True)
        submit.click()
        expect(page.get_by_role("alert").filter(has_text="did not confirm")).to_be_visible()
        expect(typed).to_have_value("  Response with outer whitespace.  ")
        page.unroute(pattern, wrong_sibling)
        submit.click()
        expect(page.get_by_text("Your original response was already recorded.", exact=False)).to_be_visible()
        first, second = c.get(endpoint).json()["items"]
        assert (first["id"], first["status"], second["id"], second["status"]) == (a["id"], "pending", b["id"], "fulfilled")
        child = c.get(path + "/answers/" + second["child_answer_id"]).json()
        assert child["answer"] == "Response with outer whitespace."
        assert len(c.get(path).json()["answers"]) == 3


def test_reconfirmation_compares_concurrent_draft_before_saving(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as c:
        sid, path, (parent, _) = seed(c)
        page.goto(review_url(workspace_url, sid, parent["id"]))
        queue = open_queue(page)
        keep_custom(queue)
        queue.get_by_role("button", name="Open answer draft").click()
        answer = page.get_by_label("Candidate answer")
        answer.fill("Unsaved local response.")
        c.put(path + "/answers/" + parent["id"], json={"question": parent["question"], "answer": "Changed source.",
              "expected_revision": parent["revision"]}).raise_for_status()
        page.get_by_role("button", name="Save and compare", exact=True).click()
        check = page.get_by_role("region", name="Deferred draft source check")
        check.get_by_role("button", name="Review current source").click()
        expect(check.get_by_text("Changed source.", exact=True)).to_be_visible()
        pattern = "**" + path + "/draft"

        def competing_save(route):
            if route.request.method == "PUT":
                peer = {**route.request.post_data_json, "answer": "Saved in the other tab."}
                c.put(path + "/draft", json=peer).raise_for_status()
            route.continue_()

        page.route(pattern, competing_save)
        check.get_by_role("button", name="Confirm source and save this draft").click()
        comparison = page.get_by_role("region", name="Conflicting draft")
        comparison.get_by_role("button", name="Compare saved draft").click()
        expect(comparison.get_by_text("Saved in the other tab.", exact=True)).to_be_visible()
        expect(answer).to_have_value("Unsaved local response.")
        assert c.get(path + "/draft").json()["answer"] == "Saved in the other tab."
        page.unroute(pattern, competing_save)
        comparison.get_by_role("button", name="Keep my edits").click()
        expect(answer).to_have_value("Unsaved local response.")
        assert c.get(path + "/draft").json()["answer"] == "Saved in the other tab."
        check.get_by_role("button", name="Review current source").click()
        check.get_by_role("button", name="Confirm source and save this draft").click()
        expect(check).to_have_count(0)
        assert c.get(path + "/draft").json()["answer"] == "Unsaved local response."


def test_discard_reconfirms_new_linked_draft_after_same_id_restore(workspace_url, browser_page):
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
        raw = c.get("/api/backups/workspace").raise_for_status().content
        trash = c.post(path + "/trash").raise_for_status().json()
        c.post(f"/api/trash/{sid}/purge", json={"operation_version": trash["operation_version"], "confirm_session_id": sid}).raise_for_status()
        preview = c.post("/api/backups/preview", content=raw).raise_for_status().json()
        c.post("/api/backups/restore", content=raw, headers={"X-Backup-Preview": preview["fingerprint"]}).raise_for_status()
        fresh = c.get(path + "/draft").raise_for_status().json()
        assert fresh["id"] == old["id"] and fresh["revision"] == old["revision"]
        assert fresh["deferred_question"]["version"] != old["deferred_question"]["version"]
        discard_url = workspace_url + path + "/draft/discard"
        commands = []
        page.on("request", lambda req: commands.append(req.post_data_json) if req.method == "POST" and req.url == discard_url else None)
        page.get_by_role("button", name="Confirm discard").click()
        expect(page.get_by_text("The saved draft changed. Review the current draft before confirming a discard.")).to_be_visible()
        assert c.get(path + "/draft").json() == fresh
        discard.click()
        with page.expect_response(lambda res: res.request.method == "POST" and res.url == discard_url) as accepted:
            page.get_by_role("button", name="Confirm discard").click()
        assert accepted.value.ok and accepted.value.json() == {"discarded": True}
        expect(page.get_by_text("Saved exchange draft", exact=True)).to_have_count(0)
        assert [body["deferred_question"] for body in commands] == [old["deferred_question"], fresh["deferred_question"]]
        assert [body["deferred_draft_token"] for body in commands] == [old["deferred_draft_token"], fresh["deferred_draft_token"]]
        assert c.get(path + "/draft").raise_for_status().json() is None
