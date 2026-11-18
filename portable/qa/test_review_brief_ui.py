import httpx
from playwright.sync_api import expect


def test_brief_defaults_and_selected_content_download(workspace_url, browser_page, tmp_path):
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        s = client.post(
            "/api/sessions",
            json={
                "candidate": "SensitiveParticipant",
                "role": "SensitiveRole",
                "policy": "SensitivePolicy",
                "consent": True,
            },
        ).json()
        base = "/api/sessions/" + s["id"]
        answer = client.post(
            base + "/answers", json={"question": "SensitiveQuestion?", "answer": "SensitiveAnswer."}
        ).json()
        client.patch(
            base + "/answers/" + answer["id"], json={"disposition": "disclosed", "note": "SensitiveNote."}
        ).raise_for_status()
        page = browser_page
        page.goto(workspace_url + "/interviews/review/?id=" + s["id"])
        page.get_by_role("link", name="Review brief").click()
        doc = page.get_by_role("region", name="Brief preview")
        expect(doc.get_by_text("Assistance disclosed by the candidate: 1 (exchange 1).")).to_be_visible()
        assert "Sensitive" not in doc.inner_text()
        page.get_by_text("Choose excerpts and notes", exact=True).click()
        page.get_by_role("checkbox", name="Interviewer note for exchange 1").check()
        expect(doc.get_by_text("SensitiveNote.", exact=True)).to_be_visible()
        assert "SensitiveAnswer" not in doc.inner_text()
        with page.expect_download() as download:
            page.get_by_role("button", name="Download brief").click()
        destination = tmp_path / "brief.md"
        download.value.save_as(destination)
        preview = client.post(base + "/brief", json={"note_ids": [answer["id"]]}).json()["markdown"]
        assert destination.read_bytes() == preview.encode()
        page.get_by_role("button", name="Clear optional details").click()
        expect(
            doc.get_by_text("All saved exchanges have limited comparison evidence.", exact=True)
        ).to_be_visible()
        assert "Sensitive" not in doc.inner_text()
        page.screenshot(path=tmp_path / "brief-desktop.png", full_page=True)
