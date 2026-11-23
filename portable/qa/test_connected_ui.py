"""Exercise the mounted UI, FastAPI and storage with synthetic provider responses."""
import re
from unittest.mock import ANY, AsyncMock
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
    expect(page.get_by_role("button", name="Edit role Release engineer", exact=True)).to_be_visible()
    expect(page.locator(".role-row").get_by_text("Release engineer", exact=True)).to_be_visible()
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
    delivery.assert_awaited_once_with("lever", remote_id, "Reviewed by test operator.", before_send=ANY)
    page.get_by_text("Delivery history", exact=True).click()
    expect(page.get_by_text("lever · Test record · Accepted by provider")).to_be_visible()


def test_embedded_account_browser_session(workspace_url, browser_page, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("INTERVIEWCHECK_OPERATOR_EMAIL", "operator@example.invalid")
    monkeypatch.setenv("TRIAL_DAYS", "3")
    monkeypatch.delenv("STRIPE_SECRET_KEY", raising=False)
    monkeypatch.delenv("INTERVIEWCHECK_SIGNUP_SECRET", raising=False)
    page = browser_page
    page.goto(workspace_url + "/account/")
    page.get_by_role("button", name="Create an account").click()
    page.get_by_label("Operator email").fill("operator@example.invalid")
    page.get_by_label("Password", exact=True).fill("Synthetic-private-account")
    page.get_by_role("button", name="Create account", exact=True).click()
    expect(page.get_by_text("operator@example.invalid · Access active")).to_be_visible()
    assert page.request.get(workspace_url + "/api/sessions").status == 200
    cookies = page.context.cookies(workspace_url + "/api/sessions")
    assert any(cookie["name"] == "ic_access" and cookie["httpOnly"] for cookie in cookies)
    created = page.request.post(workspace_url + "/api/sessions", headers={"X-InterviewCheck": "1"}, data={
        "candidate": "Account fixture", "role": "Engineer", "policy": "Notes allowed.", "consent": True,
    })
    assert created.status == 201
    page.goto(workspace_url + "/interviews/review/?id=" + created.json()["id"])
    expect(page.get_by_role("heading", name="Account fixture")).to_be_visible()
    page.get_by_role("link", name="Account", exact=True).click()
    page.get_by_role("button", name="Sign out", exact=True).click()
    expect(page.get_by_label("Operator email")).to_be_visible()
    assert page.request.get(workspace_url + "/api/sessions").status == 401
    page.go_back()
    prompt = page.get_by_role("status").filter(has_text="Sign in to open your interviews")
    expect(prompt).to_be_visible()
    # The link returns to this record after signing in.
    expect(prompt.get_by_role("link", name="Sign in")).to_have_attribute("href", re.compile(r"^/account/\?next=%2Finterviews%2F"))
    expect(page.get_by_role("heading", name="Account fixture")).to_have_count(0)


def test_admin_grants_access_through_account_page(workspace_url, browser_page, monkeypatch):
    from fastapi.testclient import TestClient
    from api.account_server import app as account_service
    operator = "admin@example.invalid"
    member_email = "member@example.invalid"
    secret = "Temporary-workstation-bootstrap"
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("INTERVIEWCHECK_OPERATOR_EMAIL", operator)
    monkeypatch.setenv("INTERVIEWCHECK_SIGNUP_SECRET", "Synthetic-invite")
    monkeypatch.setenv("ADMIN_EMAILS", operator)
    monkeypatch.setenv("ADMIN_BOOTSTRAP_SECRET", secret)
    monkeypatch.setenv("TRIAL_DAYS", "0")
    with TestClient(account_service) as service:
        member = service.post("/v1/auth/signup", json={
            "email": member_email, "password": "Synthetic-member-test", "inviteCode": "Synthetic-invite",
        })
        member.raise_for_status()
        assert member.json()["entitlement"]["active"] is False

    page = browser_page
    page.goto(workspace_url + "/account/")
    page.get_by_role("button", name="Create an account").click()
    page.get_by_label("Operator email").fill(operator)
    page.get_by_label("Password", exact=True).fill("Synthetic-admin-test")
    page.get_by_label("Invitation code").fill("Synthetic-invite")
    page.get_by_text("Administrator setup", exact=True).click()
    page.get_by_label("Bootstrap secret").fill(secret)
    page.get_by_role("button", name="Create account", exact=True).click()
    expect(page.get_by_role("heading", name="Manage accounts")).to_be_visible()
    page.get_by_label("Find accounts").fill(member_email)
    page.get_by_role("button", name="Search accounts").click()
    page.get_by_label("Account to manage").select_option(label=member_email)
    page.get_by_label("Complimentary access through (UTC)").fill("2099-01-01")
    apply = page.get_by_role("button", name="Apply account changes")
    expect(apply).to_be_disabled()
    page.get_by_label("Confirm changes for " + member_email).check()
    apply.click()
    expect(page.get_by_text("Account updated.", exact=True)).to_be_visible()
    expect(page.get_by_text(member_email + " · Active · complimentary")).to_be_visible()
    page.get_by_role("button", name="Recent account activity").click()
    expect(page.get_by_role("listitem").filter(has_text="admin.update_user")).to_be_visible()
    page.get_by_role("button", name="Sign out").click()
    expect(page.get_by_role("heading", name="Manage accounts")).to_have_count(0)
