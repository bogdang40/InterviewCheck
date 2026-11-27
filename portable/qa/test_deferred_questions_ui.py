"""Verify parked questions through the real review screen, draft slot and lost replies."""
from uuid import uuid4

import httpx
from playwright.sync_api import expect

REPEATED = "Which observation would change this decision?"


def seed(client):
    session = client.post("/api/sessions", json={"candidate": "Deferred questions fixture", "role": "Engineer",
        "policy": "Handbook allowed", "consent": True}).raise_for_status().json()
    path = f"/api/sessions/{session['id']}"
    parents = [client.post(path + "/answers", json={"question": "Explain a choice.", "answer": answer})
               .raise_for_status().json() for answer in ("We reviewed the earlier case.", "We compared two later cases.")]
    return session["id"], path, parents


def open_queue(page):
    queue = page.locator("#deferred-questions")
    if not queue.evaluate("e => e.open"):
        queue.locator("summary").focus()
        page.keyboard.press("Enter")
    return queue


def keep_custom(queue):
    section = queue.get_by_role("region", name="Keep a question")
    section.get_by_role("button", name="Write a different question").click()
    section.get_by_label("Question to keep").fill(REPEATED)
    section.get_by_role("button", name="Keep for later", exact=True).click()


def drop_ack_then_read(page, route_path, method):
    attempts = []
    def handler(route):
        if route.request.method != method:
            route.continue_()
            return
        attempts.append(route.request.post_data_json)
        received = route.fetch()
        assert received.ok
        # Simulate a proxy losing only the acknowledgement of a committed write.
        route.fulfill(status=200, content_type="application/json", body="{}")
    page.route(route_path, handler)
    return attempts, handler


def review_url(base, sid, aid):
    return f"{base}/interviews/review/?id={sid}&answer={aid}"


def test_deferred_source_identity_single_draft_and_reconfirmation(workspace_url, browser_page):
    page = browser_page
    page.set_viewport_size({"width": 390, "height": 844})
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path, (first, second) = seed(client)
        unrelated = client.put(path + "/draft", json={"id": str(uuid4()), "expected_revision": 0,
            "question": "Different question", "answer": "Do not replace this draft."}).raise_for_status().json()
        page.goto(review_url(workspace_url, sid, first["id"]))
        queue = open_queue(page)
        expect(queue.get_by_text("No deferred questions.")).to_be_visible()
        parked_path = path + "/deferred-questions"
        pattern = "**" + parked_path
        attempts, handler = drop_ack_then_read(page, pattern, "POST")
        keep_custom(queue)
        expect(queue.get_by_role("button", name="Check saved question")).to_be_visible()
        queue.get_by_role("button", name="Check saved question").click()
        expect(queue.get_by_text("Question kept for later.")).to_be_visible()
        assert len(attempts) == 1
        page.unroute(pattern, handler)
        picker = page.get_by_role("navigation", name="Interview questions").get_by_label("Selected question")
        picker.select_option(second["id"])
        expect(picker).to_have_value(second["id"])
        keep_custom(queue)
        expect(queue.get_by_role("listitem")).to_have_count(2)
        assert queue.evaluate("e => e.scrollWidth <= e.clientWidth + 1")
        items = client.get(parked_path).raise_for_status().json()["items"]
        assert [r["question"] for r in items] == [REPEATED, REPEATED]
        assert {r["parent_answer_id"] for r in items} == {first["id"], second["id"]}
        row = queue.get_by_role("listitem", name="Deferred question from exchange 1", exact=True)
        row.get_by_role("button", name="Open answer draft").click()
        expect(queue.get_by_role("alert")).to_contain_text("Another exchange draft")
        assert client.get(path + "/draft").json() == unrelated
        assert len(client.get(path).json()["answers"]) == 2
        client.post(path + "/draft/discard", json={"id": unrelated["id"], "expected_revision": unrelated["revision"]}).raise_for_status()

        client.put(path + "/answers/" + first["id"], json={"question": first["question"], "answer": "A changed source answer.",
                                                           "expected_revision": first["revision"]}).raise_for_status()
        queue.get_by_role("button", name="Reload questions").click()
        row.get_by_role("button", name="Review current source").click()
        expect(row.get_by_role("region", name="Current source exchange")).to_contain_text("A changed source answer.")
        row.get_by_role("button", name="Confirm current source").click()
        expect(row.get_by_role("button", name="Open answer draft")).to_be_visible()
        other = queue.get_by_role("listitem", name="Deferred question from exchange 2", exact=True)
        other.get_by_role("button", name="Dismiss question").click()
        expect(other.get_by_text("dismissed", exact=True)).to_be_visible()
        other.get_by_role("button", name="Review source to reopen").click()
        expect(other.get_by_role("region", name="Current source exchange")).to_contain_text(second["answer"])
        other.get_by_role("button", name="Reopen with this source").click()
        expect(other.get_by_text("pending", exact=True)).to_be_visible()
        page.reload()
        queue = open_queue(page)
        expect(queue.get_by_role("listitem")).to_have_count(2)
        assert client.get(path + "/draft").json() is None


def test_deferred_child_commits_once_across_lost_reply_and_competing_tab(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path, (parent, _) = seed(client)
        url = review_url(workspace_url, sid, parent["id"])
        page.goto(url)
        queue = open_queue(page)
        keep_custom(queue)
        row = queue.get_by_role("listitem", name="Deferred question from exchange 1")
        row.get_by_role("button", name="Open answer draft").click()
        question = page.get_by_role("textbox", name="Question", exact=True)
        expect(question).to_have_value(REPEATED)
        assert question.get_attribute("readonly") is not None
        draft = client.get(path + "/draft").raise_for_status().json()
        saved_item = client.get(path + "/deferred-questions").json()["items"][0]
        assert draft["parent_answer_id"] == parent["id"] and draft["deferred_question"]["id"] == saved_item["id"]
        assert saved_item["status"] == "pending" and saved_item["child_answer_id"] is None
        other = page.context.new_page()
        try:
            other.goto(url)
            other.get_by_role("button", name="Resume draft").click()
            page.get_by_label("Candidate answer").fill("  The first tab recorded the accepted response.  ")
            other.get_by_label("Candidate answer").fill("The second tab has a different response.")
            pattern = "**" + path + "/draft/publish"
            attempts, handler = drop_ack_then_read(page, pattern, "POST")
            page.get_by_role("button", name="Save and compare", exact=True).click()
            expect(page.get_by_role("alert").filter(has_text="did not confirm")).to_be_visible()
            assert len(attempts) == 1 and attempts[0]["id"] == draft["id"]
            page.unroute(pattern, handler)
            original = client.get(path + "/answers/" + draft["id"]).raise_for_status().json()
            assert original["answer"] == "The first tab recorded the accepted response."
            correction = "The owner clarified the accepted response after publication."
            client.put(path + "/answers/" + draft["id"], json={"question": REPEATED, "answer": correction,
                       "expected_revision": original["revision"]}).raise_for_status()
            other.get_by_role("button", name="Save and compare", exact=True).click()
            expect(other.get_by_role("region", name="Deferred draft source check")).to_be_visible()
            expect(other.get_by_label("Candidate answer")).to_have_value("The second tab has a different response.")
            with page.expect_response(lambda r: r.request.method == "POST" and r.url.endswith(path + "/draft/publish")) as replay:
                page.get_by_role("button", name="Save and compare", exact=True).click()
            assert replay.value.json()["deferred_replay"] is True
            expect(page.get_by_text("Your original response was already recorded.", exact=False)).to_be_visible()
            expect(page.get_by_role("heading", name=REPEATED, exact=True)).to_be_visible()
            expect(page.get_by_text(correction, exact=True).first).to_be_visible()
            page.reload()
            queue = open_queue(page)
            expect(queue.get_by_text("fulfilled", exact=True)).to_be_visible()
            queue.get_by_role("button", name="View saved answer").click()
            expect(page.get_by_role("heading", name=REPEATED, exact=True)).to_be_visible()
            current = client.get(path).raise_for_status().json()
            children = [a for a in current["answers"] if a["parent_answer_id"] == parent["id"]]
            assert [(a["id"], a["answer"]) for a in children] == [(draft["id"], correction)]
            assert client.get(path + "/deferred-questions/" + saved_item["id"]).json()["child_answer_id"] == draft["id"]
        finally:
            other.close()


def test_deferred_draft_keeps_typed_answer_when_parent_changes(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path, (parent, _) = seed(client)
        page.goto(review_url(workspace_url, sid, parent["id"]))
        queue = open_queue(page)
        keep_custom(queue)
        queue.get_by_role("button", name="Open answer draft").click()
        answer = page.get_by_label("Candidate answer")
        answer.fill("  An unsubmitted answer retained across the parent change.  ")
        before = client.get(path + "/draft").raise_for_status().json()
        client.put(path + "/answers/" + parent["id"], json={"question": parent["question"],
                   "answer": "The parent was changed by a second reviewer.", "expected_revision": parent["revision"]}).raise_for_status()
        page.get_by_role("button", name="Save and compare", exact=True).click()
        check = page.get_by_role("region", name="Deferred draft source check")
        check.get_by_role("button", name="Review current source").click()
        expect(check.get_by_role("region", name="Current source exchange")).to_contain_text("changed by a second reviewer")
        expect(answer).to_have_value("  An unsubmitted answer retained across the parent change.  ")
        check.get_by_role("button", name="Confirm source and save this draft").click()
        expect(check).to_have_count(0)
        after = client.get(path + "/draft").raise_for_status().json()
        assert after["id"] == before["id"] and after["deferred_question"]["id"] == before["deferred_question"]["id"]
        assert after["deferred_question"]["version"] != before["deferred_question"]["version"]
        assert after["answer"] == "An unsubmitted answer retained across the parent change."
        listed = client.get(path + "/deferred-questions").json()["items"][0]
        assert listed["status"] == "pending" and listed["child_answer_id"] is None
        page.get_by_role("button", name="Save and compare", exact=True).click()
        expect(page.get_by_role("heading", name=REPEATED, exact=True)).to_be_visible()
        assert client.get(path + "/deferred-questions").json()["items"][0]["child_answer_id"] == after["id"]


def test_finished_questions_are_read_only_and_erasure_removes_the_queue(workspace_url, browser_page):
    from api import store
    from api.retention_anonymizer import SessionAnonymizer

    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path, (parent, _) = seed(client)
        page.goto(review_url(workspace_url, sid, parent["id"]))
        queue = open_queue(page)
        keep_custom(queue)
        expect(queue.get_by_role("listitem")).to_have_count(1)
        client.post(path + "/finish").raise_for_status()
        page.reload()
        queue = open_queue(page)
        expect(queue.get_by_text(REPEATED, exact=True)).to_be_visible()
        expect(queue.get_by_role("region", name="Keep a question")).to_have_count(0)
        expect(queue.get_by_role("button", name="Open answer draft")).to_have_count(0)
        with store.connection(write=True) as db:
            SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=True, actor_email="fixture@example.test",
                                           now_iso=store.timestamp())
        # The open copy must forget its previously loaded list after a denied refresh.
        queue.get_by_role("button", name="Reload questions").click()
        expect(page.get_by_role("region", name="Interview access changed").get_by_role("alert")).to_be_visible()
        expect(page.locator("#deferred-questions")).to_have_count(0)
        page.reload()
        expect(page.locator("#deferred-questions")).to_have_count(0)
        assert client.get(path + "/deferred-questions").status_code == 403
