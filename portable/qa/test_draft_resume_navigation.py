"""Late draft replies must leave the current reviewer in control of unsaved edits."""
from uuid import uuid4

import httpx
from playwright.sync_api import expect
import pytest

from test_deferred_questions_ui import keep_custom, open_queue, review_url, seed


def hold_reply(page, url, method, button):
    held = []

    def hold(route):
        if route.request.method == method:
            held.append(route)
            page.evaluate("document.documentElement.dataset.reviewReplyHeld = 'yes'")
        else:
            route.continue_()

    page.route(url, hold)
    with page.expect_request(lambda req: req.method == method and req.url == url):
        button.click()
    page.wait_for_function("() => document.documentElement.dataset.reviewReplyHeld === 'yes'")
    route, = held
    response = route.fetch()
    assert response.ok
    return route, response


def release_reply(page, route, response):
    with page.expect_request_finished(lambda req: req.method == route.request.method and req.url == route.request.url):
        route.fulfill(response=response)
    page.unroute(route.request.url)


@pytest.mark.parametrize("action", ["resume", "open_existing", "read_empty", "create"])
def test_draft_reply_after_typing_keeps_review_until_explicit_retry(workspace_url, browser_page, action):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path, (first, second) = seed(client)
        draft_path = path + "/draft"
        answer_path = path + "/answers/" + first["id"]
        prior = client.patch(answer_path, json={
            "expected_revision": first["revision"], "disposition": "pending", "note": "Earlier saved review.",
        }).raise_for_status().json()
        payload = {"id": str(uuid4()), "expected_revision": 0, "question": "Which reading?", "answer": "Parked work."}
        if action == "resume":
            parked = client.put(draft_path, json=payload).raise_for_status().json()
        else:
            parked = None
        page.goto(review_url(workspace_url, sid, first["id"]))
        resume = page.get_by_role("button", name="Resume draft", exact=True)
        if action == "resume":
            trigger = resume
        else:
            queue = open_queue(page)
            keep_custom(queue)
            trigger = queue.get_by_role("button", name="Open answer draft")
            expect(trigger).to_be_enabled()
            if action == "open_existing":
                item, = client.get(path + "/deferred-questions").raise_for_status().json()["items"]
                parked = client.put(draft_path, json={**payload, "question": item["question"],
                    "parent_answer_id": first["id"], "deferred_question": {"id": item["id"], "version": item["version"]},
                }).raise_for_status().json()

        note = page.get_by_role("textbox", name="Interviewer note", exact=True)
        expect(note).to_have_value(prior["note"])
        method = "PUT" if action == "create" else "GET"
        url = workspace_url + draft_path
        requests = []
        page.on("request", lambda req: requests.append(req.method) if req.url == url else None)
        route, reply = hold_reply(page, url, method, trigger)
        if action == "create":
            parked = reply.json()
            assert parked["parent_answer_id"] == first["id"]
        else:
            assert reply.json() == parked

        proposed = "Note typed while the saved draft reply was in flight."
        note.fill(proposed)
        release_reply(page, route, reply)
        retry = trigger if action == "read_empty" else resume
        message = "then choose Open answer draft again." if action == "read_empty" else "then choose Resume draft."
        expect(page.get_by_text(message, exact=False)).to_be_visible()
        expect(note).to_have_value(proposed)
        expect(retry).to_be_disabled()
        page.wait_for_function("([key, note]) => JSON.parse(localStorage.getItem(key))?.note === note",
                               arg=[f"ic_draft_v1:{sid}:review:{first['id']}", proposed])
        assert client.get(answer_path).raise_for_status().json() == prior
        assert client.get(draft_path).raise_for_status().json() == parked
        assert requests == (["GET", "PUT"] if action == "create" else ["GET"])

        page.get_by_role("button", name="Save review", exact=True).click()
        expect(page.get_by_text("Review saved", exact=True)).to_be_visible()
        expect(note).to_have_value(proposed)
        with page.expect_request(lambda req: req.method == "GET" and req.url == url):
            retry.click()
        if parked is None:
            expect(page.get_by_role("textbox", name="Candidate answer", exact=True)).to_be_visible()
            parked = client.get(draft_path).raise_for_status().json()
            assert parked["parent_answer_id"] == first["id"] and parked["deferred_question"]
        else:
            assert client.get(draft_path).raise_for_status().json() == parked
        expect(page.get_by_role("textbox", name="Candidate answer", exact=True)).to_have_value(parked["answer"])
        saved = client.get(answer_path).raise_for_status().json()
        assert (saved["note"], saved["revision"]) == (proposed, prior["revision"] + 1)
        assert client.get(path + "/answers/" + second["id"]).raise_for_status().json() == second


@pytest.mark.parametrize("action", ["saved_child", "import"])
def test_late_session_refresh_preserves_current_note_and_saved_exchange(workspace_url, browser_page, action):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path, (first, _) = seed(client)
        page.goto(review_url(workspace_url, sid, first["id"]))
        note = page.get_by_role("textbox", name="Interviewer note", exact=True)
        expect(note).to_be_visible()
        if action == "saved_child":
            queue = open_queue(page)
            keep_custom(queue)
            expect(queue.get_by_role("button", name="Open answer draft")).to_be_enabled()
            item, = client.get(path + "/deferred-questions").raise_for_status().json()["items"]
            child = client.post(path + "/answers", json={"id": str(uuid4()), "question": item["question"],
                "answer": "A separate response.", "parent_answer_id": first["id"],
                "deferred_question": {"id": item["id"], "version": item["version"]},
            }).raise_for_status().json()
            queue.get_by_role("button", name="Reload questions").click()
            button = queue.get_by_role("button", name="View saved answer")
        else:
            page.get_by_text("Import transcript exchanges", exact=True).click()
            page.get_by_label("Conversation WebVTT file").set_input_files({
                "name": "later.vtt", "mimeType": "text/vtt",
                "buffer": b"WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n<v Host>Which reading?</v>\n\n"
                          b"00:00:02.000 --> 00:00:03.000\n<v Candidate>The second sample.</v>\n",
            })
            page.get_by_label("Candidate in transcript").select_option("Candidate")
            page.get_by_role("checkbox", name="Host", exact=True).check()
            page.get_by_role("button", name="Preview exchanges").click()
            button = page.get_by_role("button", name="Import selected exchanges")

        route, reply = hold_reply(page, workspace_url + path, "GET", button)
        current = reply.json()
        assert current["answer_count"] == 3
        if action == "import":
            child, = [a for a in current["answers"] if a.get("import_origin")]
        proposed = "Review entered during the session refresh."
        note.fill(proposed)
        release_reply(page, route, reply)
        warning = "select the exchange again" if action == "saved_child" else "Reload the record to view them"
        expect(page.get_by_role("alert").filter(has_text=warning)).to_be_visible()
        expect(note).to_have_value(proposed)
        assert page.url == review_url(workspace_url, sid, first["id"])
        assert client.get(path + "/answers/" + first["id"]).raise_for_status().json() == first
        page.get_by_role("button", name="Save review", exact=True).click()
        expect(page.get_by_text("Review saved", exact=True)).to_be_visible()
        if action == "saved_child":
            button.click()
        else:
            page.reload()
            page.get_by_role("navigation", name="Interview questions").get_by_role("button", name="03", exact=False).click()
        expect(page.get_by_role("heading", name=child["question"], exact=True)).to_be_visible()
        assert client.get(path + "/answers/" + first["id"]).raise_for_status().json()["note"] == proposed
        assert client.get(path).raise_for_status().json()["answer_count"] == 3
