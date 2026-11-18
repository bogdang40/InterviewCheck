"""Exercise the mounted UI, FastAPI and storage with synthetic provider responses."""
from unittest.mock import AsyncMock
from uuid import uuid4

import httpx
from playwright.sync_api import expect


def test_role_authoring(workspace_url, browser_page, monkeypatch):
    from api import authoring
    question = "Which failure would you simulate before rollout?"
    monkeypatch.setenv("OPENAI_API_KEY", "fixture")
    monkeypatch.setenv("INTERVIEWCHECK_REFERENCE_MODEL", "fixture")
    generate = AsyncMock(return_value=("fixture", '["' + question + '"]'))
    monkeypatch.setattr(authoring, "complete", generate)
    page = browser_page
    page.goto(workspace_url + "/#roles")
    page.get_by_role("button", name="Add role").click()
    page.get_by_label("Role name").fill("Release engineer")
    page.get_by_label("Description", exact=True).fill("Manage staged updates.")
    page.get_by_text("Draft role questions", exact=True).click()
    page.get_by_role("button", name="Draft questions", exact=True).click()
    expect(page.get_by_role("textbox", name="Planned questions, one per line")).to_have_value(question)
    page.get_by_role("button", name="Save role").click()
    expect(page.get_by_text("Release engineer", exact=True)).to_be_visible()
    assert httpx.get(workspace_url + "/api/roles").json()[0]["questions"] == [question]
    generate.assert_awaited_once()


def test_note_preview_requires_confirmation_after_edit(workspace_url, browser_page, monkeypatch):
    from api import ats_notes
    monkeypatch.setenv("LEVER_API_KEY", "fixture")
    remote_id = str(uuid4())
    lookup = AsyncMock(return_value=[{"candidate": "Test record", "role": "Reviewer", "target_id": remote_id}])
    delivery = AsyncMock()
    monkeypatch.setattr(ats_notes.ats, "lookup", lookup)
    monkeypatch.setattr(ats_notes, "send_private", delivery)
    response = httpx.post(workspace_url + "/api/sessions", headers={"X-InterviewCheck": "1"}, json={
        "candidate": "Test record", "role": "Reviewer", "policy": "Notes allowed.", "consent": True,
    })
    response.raise_for_status()
    page = browser_page
    page.goto(workspace_url + "/#session/" + response.json()["id"])
    page.get_by_text("Send a private ATS note", exact=True).click()
    page.get_by_label("Candidate email").fill("fixture@example.test")
    page.get_by_role("button", name="Find recipient").click()
    page.get_by_role("button", name="Preview note").click()
    send = page.get_by_role("button", name="Send private note", exact=True)
    expect(send).to_be_disabled()
    check = page.get_by_label("I verified the recipient and the note.")
    check.check()
    page.get_by_role("textbox", name="Private note", exact=True).fill("Reviewed by test operator.")
    expect(send).to_be_disabled()
    delivery.assert_not_called()
    check.check()
    send.click()
    expect(page.get_by_text("The provider accepted the private note.")).to_be_visible()
    delivery.assert_awaited_once_with("lever", remote_id, "Reviewed by test operator.")
    page.get_by_text("Delivery history", exact=True).click()
    expect(page.get_by_text("lever · Test record · Accepted by provider")).to_be_visible()
