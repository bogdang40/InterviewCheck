"""A prepared brief includes only selected text and matches the preview used for download."""

import httpx
from playwright.sync_api import expect


def test_preview_excludes_unselected_text_and_rejects_a_stale_download(workspace_url, browser_page, tmp_path):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        personal = {
            "candidate": "Private candidate identity",
            "role": "Private role title",
            "policy": "Private policy text",
            "consent": True,
        }
        session = client.post("/api/sessions", json=personal)
        session.raise_for_status()
        route = "/api/sessions/" + session.json()["id"]
        phrase = (
            "Calibrate the amber receiver against three independent cold baselines before measuring drift."
        )
        record = client.post(
            route + "/answers",
            json={
                "question": "Private interview prompt.",
                "answer": phrase,
                "references": [{"label": "Private source name", "text": phrase}],
            },
        )
        record.raise_for_status()
        key = record.json()["id"]
        note = "The original interviewer note."
        path = route + "/answers/" + key
        client.patch(path, json={"note": note, "disposition": "unresolved"}).raise_for_status()
        endpoint = route + "/brief"
        default = client.get(endpoint)
        default.raise_for_status()
        for sensitive in [
            personal["candidate"],
            personal["role"],
            personal["policy"],
            phrase,
            note,
            "Private source name",
            "Private interview prompt.",
        ]:
            assert sensitive not in default.text
        page.goto(workspace_url + "/interviews/brief/?id=" + session.json()["id"])
        page.get_by_text("Choose excerpts and notes", exact=True).click()
        page.get_by_label("Interviewer note for exchange 1").check()
        expect(page.get_by_text(note, exact=True)).to_be_visible()
        updated = "Updated observations from the interviewer."
        client.patch(path, json={"note": updated, "disposition": "unresolved"}).raise_for_status()
        page.get_by_role("button", name="Download brief").click()
        expect(page.get_by_role("alert").filter(has_text="changed")).to_be_visible()
        page.get_by_role("button", name="Refresh preview").click()
        expect(page.get_by_text(updated, exact=True)).to_be_visible()
        approved = client.post(endpoint, json={"excerpt_ids": [], "note_ids": [key]})
        approved.raise_for_status()
        with page.expect_download() as download:
            page.get_by_role("button", name="Download brief").click()
        target = tmp_path / "brief.md"
        download.value.save_as(target)
        assert target.read_text(encoding="utf-8") == approved.json()["markdown"]
        assert updated in approved.json()["markdown"] and phrase not in approved.json()["markdown"]
