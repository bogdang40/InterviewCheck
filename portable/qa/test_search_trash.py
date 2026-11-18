"""Search and reversible removal against the real workspace service."""

import asyncio
from concurrent.futures import ThreadPoolExecutor
from threading import Event
from unittest.mock import AsyncMock

import httpx
from playwright.sync_api import expect


def create_session(client, candidate):
    created = client.post(
        "/api/sessions",
        json={"candidate": candidate, "role": "SRE", "policy": "Manual allowed.", "consent": True},
    )
    created.raise_for_status()
    return created.json()["id"]


def test_keyboard_search_and_version_bound_trash(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as c:
        wanted = create_session(c, "Harbor test")
        other = create_session(c, "Unaffected fixture")
        path = "/api/sessions/" + wanted
        content = {
            "question": "Which value?",
            "answer": "I would record the Q%_marker before comparing the traces.",
        }
        answer = c.post(path + "/answers", json=content)
        answer.raise_for_status()
        c.post(
            "/api/sessions/" + other + "/answers", json={**content, "answer": "Some Qxxmarker data."}
        ).raise_for_status()
        page.goto(workspace_url + "/interviews/")
        previous = page.get_by_label("Search interviews")
        previous.focus()
        page.keyboard.press("Control+k")
        dialog = page.get_by_role("dialog", name="Search workspace")
        query = dialog.get_by_role("combobox")
        expect(query).to_be_focused()
        query.fill("Q%_marker")
        expect(dialog.get_by_role("option")).to_have_count(1)
        page.keyboard.press("Escape")
        expect(previous).to_be_focused()
        page.keyboard.press("Control+k")
        dialog.get_by_role("combobox").fill("Q%_marker")
        expect(dialog.get_by_role("option")).to_have_count(1)
        page.keyboard.press("Enter")
        expect(page.get_by_role("heading", name="Which value?", exact=True)).to_be_visible()
        assert "answer=" + answer.json()["id"] in page.url
        page.get_by_role("button", name="Move to Trash", exact=True).click()
        page.get_by_role("button", name="Confirm move to Trash").click()
        expect(page.get_by_role("button", name="Undo move")).to_be_visible()
        token = c.get("/api/trash").json()["items"][0]["operation_version"]
        assert c.post("/api/search", json={"query": "Q%_marker"}).json()["items"] == []
        assert c.get(path + "/report").status_code == c.get(path + "/brief").status_code == 404
        assert "Harbor test" not in c.get("/api/exports/interviews.csv").text
        archived = c.get("/api/backups/workspace").json()
        assert next(s for s in archived["sessions"] if s["id"] == wanted)["trashed_at"]
        page.get_by_role("button", name="Undo move").click()
        expect(page.get_by_role("status").filter(has_text="Restored")).to_be_visible()
        fresh = c.post(path + "/trash").json()["operation_version"]
        assert token != fresh
        assert (
            c.post(
                f"/api/trash/{wanted}/purge", json={"operation_version": token, "confirm_session_id": wanted}
            ).status_code
            == 409
        )
        page.reload()
        page.get_by_role("button", name="Delete permanently").click()
        purge = page.get_by_role("button", name="Confirm permanent deletion")
        expect(purge).to_be_disabled()
        page.get_by_label("Interview ID to confirm").fill(other)
        expect(purge).to_be_disabled()
        page.get_by_label("Interview ID to confirm").fill(wanted)
        purge.click()
        expect(page.get_by_role("status").filter(has_text="Permanently deleted")).to_be_visible()
        assert c.get("/api/trash").json()["total"] == 0
        assert c.get(path).status_code == 404 and c.get("/api/sessions/" + other).status_code == 200


def test_trash_invalidates_inflight_note_callback(workspace_url, monkeypatch):
    from api import ats_notes

    monkeypatch.setenv("LEVER_API_KEY", "fixture")
    arrived, release = Event(), Event()
    remote = AsyncMock(
        return_value=[{"candidate": "Harbor fixture", "role": "Test", "target_id": "fixture-id"}]
    )
    monkeypatch.setattr(ats_notes.ats, "lookup", remote)
    calls = []

    async def wait_for_provider(*args, before_send):
        before_send()
        calls.append(args)
        arrived.set()
        if not await asyncio.to_thread(release.wait, 8):
            raise AssertionError("Timed out waiting for synthetic delivery")

    monkeypatch.setattr(ats_notes, "send_private", wait_for_provider)
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}, timeout=12) as c:
        sid = create_session(c, "Harbor fixture")
        path = "/api/sessions/" + sid
        draft = c.post(
            path + "/ats/drafts",
            json={"provider": "lever", "email": "harbor@example.invalid", "target_id": "fixture-id"},
        )
        draft.raise_for_status()
        url = path + "/ats/drafts/" + draft.json()["id"] + "/send"
        with ThreadPoolExecutor(max_workers=1) as pool:
            result = pool.submit(c.post, url, json={"note": "A fictional observation.", "confirmed": True})
            try:
                assert arrived.wait(timeout=6)
                marker = c.post(path + "/trash").json()["operation_version"]
                c.post(
                    "/api/trash/" + sid + "/restore", json={"operation_version": marker}
                ).raise_for_status()
            finally:
                release.set()
            assert result.result().status_code in (404, 409)
        assert len(calls) == 1
        assert c.get(path + "/ats").json()["history"][0]["state"] == "attempted"
