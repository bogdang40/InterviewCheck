"""Late draft replies must leave the current reviewer in control of unsaved edits."""
from uuid import uuid4

import httpx
from playwright.sync_api import expect
import pytest

from test_deferred_questions_ui import keep_custom, open_queue, review_url, seed


def hold_request(page, url, method, button):
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
    return route


def hold_reply(page, url, method, button):
    route = hold_request(page, url, method, button)
    response = route.fetch()
    assert response.ok
    return route, response


def release_reply(page, route, response):
    with page.expect_request_finished(lambda req: req.method == route.request.method and req.url == route.request.url):
        route.fulfill(response=response)
    page.unroute(route.request.url)


def prepare_import(page):
    page.get_by_text("Import transcript exchanges", exact=True).click()
    page.get_by_label("Conversation WebVTT file").set_input_files({
        "name": "later.vtt", "mimeType": "text/vtt",
        "buffer": b"WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n<v Host>Which reading?</v>\n\n"
                  b"00:00:02.000 --> 00:00:03.000\n<v Candidate>The second sample.</v>\n",
    })
    page.get_by_label("Candidate in transcript").select_option("Candidate")
    page.get_by_role("checkbox", name="Host", exact=True).check()
    page.get_by_role("button", name="Preview exchanges").click()
    return page.get_by_role("button", name="Import selected exchanges")


def prepare_saved_child(page, client, path, parent):
    queue = open_queue(page)
    keep_custom(queue)
    expect(queue.get_by_role("button", name="Open answer draft")).to_be_enabled()
    item, = client.get(path + "/deferred-questions").raise_for_status().json()["items"]
    child = client.post(path + "/answers", json={"id": str(uuid4()), "question": item["question"],
        "answer": "A separate response.", "parent_answer_id": parent["id"],
        "deferred_question": {"id": item["id"], "version": item["version"]},
    }).raise_for_status().json()
    queue.get_by_role("button", name="Reload questions").click()
    return queue.get_by_role("button", name="View saved answer"), child


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
            button, child = prepare_saved_child(page, client, path, first)
        else:
            button = prepare_import(page)

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


@pytest.mark.parametrize(("action", "failure"), [
    ("resume", "trash"), ("linked_resume", "trash"), ("saved_child", "privacy"), ("import", "trash"),
    ("resume", "temporary"), ("saved_child", "temporary"), ("import", "temporary"),
])
def test_pending_interview_read_distinguishes_withdrawal_from_retry(workspace_url, browser_page, action, failure):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path, (first, _) = seed(client)
        draft_path = path + "/draft"
        if action == "resume":
            client.put(draft_path, json={"id": str(uuid4()), "expected_revision": 0,
                       "question": "A parked question?", "answer": "An unfinished draft."}).raise_for_status()
        page.goto(review_url(workspace_url, sid, first["id"]))
        if action == "linked_resume":
            queue = open_queue(page)
            keep_custom(queue)
            queue.get_by_role("button", name="Open answer draft").click()
            expect(page.get_by_role("textbox", name="Candidate answer", exact=True)).to_be_visible()
            assert client.get(draft_path).raise_for_status().json()["deferred_question"]
            page.reload()  # Only the banner should observe the denied read.
        endpoint = path
        if action in ("resume", "linked_resume"):
            button = page.get_by_role("button", name="Resume draft", exact=True)
            endpoint = draft_path
        elif action == "saved_child":
            button, _ = prepare_saved_child(page, client, path, first)
        else:
            button = prepare_import(page)

        posts = []
        page.on("request", lambda req: posts.append(req.url) if req.method == "POST" and
                req.url == workspace_url + path + "/imports/webvtt" else None)
        route = hold_request(page, workspace_url + endpoint, "GET", button)
        if action == "import":
            before = client.get(path).raise_for_status().json()
            imported, = [a for a in before["answers"] if a.get("import_origin")]
            assert before["answer_count"] == 3 and len(posts) == 1
        note = page.get_by_role("textbox", name="Interviewer note", exact=True)
        pending = "Private note entered before the pending read returned."
        note.fill(pending)
        key = f"ic_draft_v1:{sid}:review:{first['id']}"
        page.wait_for_function("([k, v]) => JSON.parse(localStorage.getItem(k))?.note === v", arg=[key, pending])
        other_key = f"ic_draft_v1:{uuid4()}:review:{uuid4()}"
        page.evaluate("k => localStorage.setItem(k, 'Unrelated local draft')", other_key)

        gate = page.get_by_role("region", name="Interview access changed")
        if failure == "temporary":
            with page.expect_request_finished(lambda req: req.url == route.request.url):
                route.fulfill(status=409 if action == "saved_child" else 503, json={"detail": "Temporary read failure."})
            page.unroute(route.request.url)
            expect(page.get_by_role("alert").filter(has_text="Temporary read failure.")).to_be_visible()
            expect(gate).to_have_count(0)
            expect(note).to_have_value(pending)
            assert page.evaluate("k => JSON.parse(localStorage.getItem(k)).note", key) == pending
            page.get_by_role("button", name="Save review", exact=True).click()
            expect(page.get_by_text("Review saved", exact=True)).to_be_visible()
            if action == "import":
                page.reload()
                page.get_by_role("navigation", name="Interview questions").get_by_role("button", name="03", exact=False).click()
            else:
                button.click()
            if action == "resume":
                expect(page.get_by_role("textbox", name="Candidate answer", exact=True)).to_have_value("An unfinished draft.")
            else:
                expect(page).not_to_have_url(review_url(workspace_url, sid, first["id"]))
            assert client.get(path + "/answers/" + first["id"]).raise_for_status().json()["note"] == pending
        else:
            if failure == "trash":
                marker = client.post(path + "/trash").raise_for_status().json()
            else:
                from api import answer_history, store
                from api.retention_anonymizer import SessionAnonymizer
                with store.connection(write=True) as db:
                    SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=False, actor_email="fixture",
                                                   now_iso=store.timestamp())
                    answer_history.record(db, first, "baseline")
            denied = route.fetch()
            if failure == "trash":
                assert denied.status == 404 and "x-interviewcheck-conflict" not in denied.headers
            else:
                assert denied.status == 409 and denied.headers["x-interviewcheck-conflict"] == "interview-privacy"
            release_reply(page, route, denied)
            expect(gate).to_be_visible()
            expect(note).to_have_count(0)
            expect(page.locator("body")).not_to_contain_text(first["answer"])
            page.evaluate("window.dispatchEvent(new Event('pagehide'))")
            assert page.evaluate("sid => Object.keys(localStorage).every(k => !k.startsWith('ic_draft_v1:' + sid + ':'))", sid)
            if failure == "trash":
                client.post(f"/api/trash/{sid}/restore", json={"operation_version": marker["operation_version"]}).raise_for_status()
                assert client.get(path + "/answers/" + first["id"]).raise_for_status().json() == first
        assert page.evaluate("k => localStorage.getItem(k)", other_key) == "Unrelated local draft"
        if action == "import":
            saved = client.get(path).raise_for_status().json()
            assert len(posts) == 1 and saved["answer_count"] == 3
            assert [a for a in saved["answers"] if a.get("import_origin")] == [imported]


def test_back_during_committed_import_keeps_explicit_exchange_selection(workspace_url, browser_page):
    page = browser_page
    page.on("dialog", lambda dialog: dialog.accept())
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path, (first, second) = seed(client)
        start = review_url(workspace_url, sid, first["id"])
        page.goto(start)
        page.get_by_role("navigation", name="Interview questions").get_by_role("button", name="02", exact=False).click()
        expect(page).to_have_url(review_url(workspace_url, sid, second["id"]))
        button = prepare_import(page)
        url = workspace_url + path + "/imports/webvtt"
        posts = []
        page.on("request", lambda req: posts.append(req.post_data_json["request_id"]) if req.method == "POST" and req.url == url else None)
        route, committed = hold_reply(page, url, "POST", button)
        child, = committed.json()["answer_ids"]
        assert committed.json()["saved"] == 1 and client.get(path).raise_for_status().json()["answer_count"] == 3
        page.go_back()
        expect(page).to_have_url(start)
        expect(page.locator(".review-pane")).to_contain_text(first["answer"])
        with page.expect_response(lambda res: res.url == workspace_url + path and res.request.method == "GET") as refreshed:
            release_reply(page, route, committed)
        assert refreshed.value.ok
        expect(page.get_by_role("alert").filter(has_text="Exchanges were saved.")).to_be_visible()
        expect(page).to_have_url(start)
        expect(page.locator(".review-pane")).to_contain_text(first["answer"])
        saved = client.get(path).raise_for_status().json()
        assert len(posts) == 1 and saved["answer_count"] == 3
        assert [a["id"] for a in saved["answers"] if a.get("import_origin")] == [child]
