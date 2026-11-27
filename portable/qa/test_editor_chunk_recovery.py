"""A stale editor script leaves the saved interview usable until the reviewer chooses to reload."""
from urllib.parse import urlsplit

import httpx
import pytest
from playwright.sync_api import expect


def editor_script(browser, url, answer):
    with browser.new_context(service_workers="block") as context:
        page = context.new_page()
        scripts = []
        page.on("response", lambda r: scripts.append(r) if r.request.resource_type == "script" and r.status == 200 else None)
        page.goto(url, wait_until="networkidle")
        edit = page.get_by_role("button", name="Edit exchange", exact=True)
        expect(edit).to_be_visible()
        loaded = {r.url for r in scripts}
        edit.click()
        expect(page.get_by_role("heading", name="Edit exchange", exact=True)).to_be_visible()
        expect(page.get_by_role("textbox", name="Candidate answer")).to_have_value(answer)
        matches = []
        for response in scripts:
            path = urlsplit(response.url).path
            if response.url not in loaded and path.startswith("/_next/static/chunks/") and path.endswith(".js"):
                data = response.body()
                if b"Add an exchange" in data and b"Save and compare" in data:
                    matches.append(response.url)
        assert len(set(matches)) == 1, "Expected one newly requested browser script containing the editor."
        return matches[0]


def test_missing_editor_script_recovers_without_losing_the_saved_exchange(workspace_url, qa_browser, request):
    if request.config.getoption("--frontend") == "dev":
        pytest.skip("This regression checks the production webpack split.")
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid = client.post("/api/sessions", json={"candidate": "Editor recovery fixture", "role": "Engineer",
                          "policy": "Manuals permitted.", "consent": True}).raise_for_status().json()["id"]
        path = "/api/sessions/" + sid
        saved = client.post(path + "/answers", json={"question": "Which reading changed?",
                            "answer": "The independent control stayed stable."}).raise_for_status().json()
        baseline = client.get(path).raise_for_status().json()
        url = workspace_url + f"/interviews/review/?id={sid}&answer={saved['id']}"
        asset = editor_script(qa_browser, url, saved["answer"])
        with qa_browser.new_context(service_workers="block") as context:
            page = context.new_page()
            requests, writes, exceptions, denied = [], [], [], []
            def observe(req):
                requests.append(req.url)
                if req.method not in {"GET", "HEAD", "OPTIONS"}:
                    writes.append((req.method, urlsplit(req.url).path))
            page.on("request", observe)
            page.on("pageerror", lambda err: exceptions.append(str(err)))
            page.goto(url, wait_until="networkidle")
            edit = page.get_by_role("button", name="Edit exchange", exact=True)
            expect(edit).to_be_enabled()
            assert asset not in requests
            origin = page.evaluate("performance.timeOrigin")
            def missing(route):
                denied.append(route.request.url)
                route.fulfill(status=404, content_type="text/plain", body="Script unavailable")
            page.route(asset, missing)
            with page.expect_response(lambda r: r.url == asset and r.status == 404):
                edit.focus()
                page.keyboard.press("Enter")
            recovery = page.get_by_role("region", name="Exchange editor unavailable")
            expect(recovery).to_be_visible()
            expect(recovery.get_by_role("alert")).to_contain_text("editor could not load")
            expect(page.get_by_role("region", name="Session scorecard panel")).to_be_visible()
            assert page.url == url and page.evaluate("performance.timeOrigin") == origin
            assert denied == [asset] and writes == [] and not exceptions
            back = recovery.get_by_role("button", name="Return to saved exchange")
            back.focus()
            page.keyboard.press("Enter")
            expect(page.get_by_role("heading", name=saved["question"], exact=True)).to_be_visible()
            expect(page.get_by_text(saved["answer"], exact=True)).to_be_visible()
            expect(page.get_by_label("Selected exchange", exact=True)).to_be_focused()
            assert page.evaluate("performance.timeOrigin") == origin

            edit.click()
            reload = recovery.get_by_role("button", name="Reload interview", exact=True)
            expect(reload).to_be_visible()
            page.unroute(asset, missing)
            reload.focus()
            with page.expect_navigation(url=url, wait_until="domcontentloaded"):
                page.keyboard.press("Enter")
            expect(edit).to_be_enabled()
            assert page.evaluate("performance.timeOrigin") != origin
            edit.click()
            expect(page.get_by_role("heading", name="Edit exchange", exact=True)).to_be_visible()
            expect(page.get_by_role("textbox", name="Candidate answer")).to_have_value(saved["answer"])
            assert not exceptions and not writes
            assert client.get(path).raise_for_status().json() == baseline
