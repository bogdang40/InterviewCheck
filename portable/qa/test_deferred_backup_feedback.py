"""Report the selected v7 question count consistently throughout the backup workflow."""
import json
from uuid import uuid4

import httpx
from playwright.sync_api import expect

from test_backup_restore_replies import apply, open_file
from test_deferred_questions_ui import REPEATED, seed


def test_v7_download_preview_conflict_and_restore_counts(workspace_url, browser_page, tmp_path, monkeypatch):
    from api import store

    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as c:
        sid, path, (parent, _) = seed(c)
        endpoint = path + "/deferred-questions"
        context = c.get(path + "/answers/" + parent["id"] + "/worksheet").raise_for_status().json()
        q = c.post(endpoint, json={"id": str(uuid4()), "expected_material": context["material"],
                                   "parent_answer_id": parent["id"], "question": REPEATED}).raise_for_status().json()
        page.goto(workspace_url + "/data/")
        with page.expect_download() as downloaded:
            page.get_by_role("link", name="Download backup for the entire workspace").click()
        expect(page.get_by_text("1 deferred question in this backup.")).to_be_visible()
        file = tmp_path / "deferred.json"
        downloaded.value.save_as(file)
        doc = json.loads(file.read_bytes())
        assert doc["version"] == 7 and doc["sessions"][0]["deferred_questions"][0]["id"] == q["id"]
        c.patch(endpoint + "/" + q["id"], json={"action": "dismiss", "expected_version": q["version"]}).raise_for_status()
        open_file(page, workspace_url, file)
        preview = page.get_by_role("button", name="Preview restore", exact=True)
        preview.click()
        details = page.get_by_role("heading", name="Restore preview").locator("..")
        expect(details).to_contain_text("1 deferred question")
        expect(details.get_by_role("listitem").filter(has_text="Deferred questions")).to_be_visible()
        fresh = tmp_path / "fresh.sqlite3"
        store.initialize(fresh)
        monkeypatch.setenv("INTERVIEWCHECK_DB", str(fresh))
        preview.click()
        expect(apply(page)).to_be_enabled()
        apply(page).click()
        expect(page.get_by_role("status").filter(has_text="The selected file contains 1 deferred question.")).to_be_visible()
        assert c.get(endpoint).raise_for_status().json()["items"][0]["status"] == "pending"
