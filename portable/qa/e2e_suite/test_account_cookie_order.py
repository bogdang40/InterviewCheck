"""Explicit signout remains queued behind a browser's earlier password operation."""
from urllib.parse import urlsplit

from playwright.sync_api import expect
import pytest

from e2e_suite.harness import DESKTOP_VIEWPORT, signup_user
from e2e_suite.account_rotation_fixture import (
    ADMIN1_EMAIL, BOOTSTRAP_SECRET, MEMBER_EMAIL, MEMBER_PASS, sign_in_on_account,
)

PASSWORD_PATH = "/api/integrations/access/password"
LOGOUT_PATH = "/api/integrations/logout"
SESSIONS_PATH = "/api/integrations/security/sessions"
NEW_PASS = "Synthetic-Cookie-Order-Pass-4678"
NOTICE = "The last password change in this tab was not confirmed."


def change_password(page):
    form = page.get_by_role("form", name="Change password")
    form.get_by_label("Current password").fill(MEMBER_PASS)
    form.get_by_label("New password", exact=True).fill(NEW_PASS)
    form.get_by_label("Confirm new password").fill(NEW_PASS)
    form.get_by_role("button", name="Update password").click()
    return form


def create_member(workspace):
    workspace.configure_embedded_auth(admin_emails=(ADMIN1_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    with workspace.client() as client:
        signup_user(client, email=MEMBER_EMAIL, password=MEMBER_PASS)


@pytest.mark.tier3
@pytest.mark.parametrize(("sibling", "acknowledged"), [(False, True), (True, True), (False, False)],
                         ids=["same-tab-without-web-locks", "other-tab-with-web-locks", "unconfirmed-rotation"])
def test_explicit_signout_runs_after_an_earlier_rotation(e2e_workspace, e2e_browser, sibling, acknowledged):
    create_member(e2e_workspace)
    base = e2e_workspace.base_url
    with e2e_browser.new_context(viewport=DESKTOP_VIEWPORT) as context:
        if not sibling:
            context.add_init_script("Object.defineProperty(navigator,'locks',{configurable:true,value:undefined})")
        page = context.new_page()
        sign_in_on_account(page, base, MEMBER_EMAIL, MEMBER_PASS)
        other = context.new_page() if sibling else page
        if sibling:
            other.goto(base + "/admin/")
            expect(other.get_by_role("button", name="Sign out", exact=True)).to_be_visible()
        assert page.evaluate("typeof navigator.locks?.request === 'function'") == sibling
        traffic, errors = [], []
        for target in ([page, other] if sibling else [page]):
            target.on("pageerror", lambda event: errors.append(str(event)))
        context.on("request", lambda r: traffic.append(("send", urlsplit(r.url).path))
                   if urlsplit(r.url).path in (PASSWORD_PATH, LOGOUT_PATH) else None)
        context.on("response", lambda r: traffic.append((r.status, urlsplit(r.url).path))
                   if urlsplit(r.url).path in (PASSWORD_PATH, LOGOUT_PATH) else None)
        # The server has rotated the cookie. Keep its response from the form until after the signout click.
        page.evaluate("""acknowledged => {
          const send = window.fetch.bind(window);
          window.fetch = async (input, init) => {
            if (new URL(input instanceof Request ? input.url : input, location.href).pathname === '/api/integrations/access/password') {
              const reply = await send(input, init);
              await new Promise(done => {
                window.finishRotationFixture = done;
                document.documentElement.dataset.passwordReply = String(reply.status);
              });
              return acknowledged ? reply : new Response('{}', {status:200, headers:{'Content-Type':'application/json'}});
            }
            return send(input, init);
          };
        }""", acknowledged)
        change_password(page)
        expect(page.locator("html")).to_have_attribute("data-password-reply", "200")
        signout = other.get_by_role("button", name="Sign out", exact=True)
        signout.click()
        expect(signout).to_be_disabled()
        assert context.request.get(base + "/api/integrations/account").ok
        assert traffic == [("send", PASSWORD_PATH), (200, PASSWORD_PATH)]
        with other.expect_response(lambda r: r.url == base + LOGOUT_PATH) as logged_out:
            page.evaluate("() => window.finishRotationFixture()")
        assert logged_out.value.ok
        expect(other.get_by_role("button", name="Sign in", exact=True)).to_be_visible(timeout=15_000)
        assert traffic == [("send", PASSWORD_PATH), (200, PASSWORD_PATH), ("send", LOGOUT_PATH), (200, LOGOUT_PATH)]
        assert context.request.get(base + "/api/integrations/account").status == 401
        if not acknowledged:
            expect(other.get_by_text(NOTICE, exact=False)).to_be_visible()
        assert not errors


@pytest.mark.tier3
def test_unconfirmed_rotation_notice_survives_a_signed_out_recheck(e2e_workspace, e2e_browser):
    create_member(e2e_workspace)
    base = e2e_workspace.base_url
    with e2e_browser.new_context(viewport=DESKTOP_VIEWPORT) as context:
        page = context.new_page()
        sign_in_on_account(page, base, MEMBER_EMAIL, MEMBER_PASS)
        writes, errors = [], []
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.on("request", lambda r: writes.append(r.method) if urlsplit(r.url).path == PASSWORD_PATH else None)
        page.evaluate("""() => {
          const send = window.fetch.bind(window);
          window.fetch = async (input, init) => {
            const reply = await send(input, init);
            if (new URL(input instanceof Request ? input.url : input, location.href).pathname === '/api/integrations/access/password') {
              await new Promise(done => {
                window.dropRotationAcknowledgment = done;
                document.documentElement.dataset.rotationReply = String(reply.status);
              });
              return new Response('{}', {status:200, headers:{'Content-Type':'application/json'}});
            }
            return reply;
          };
        }""")
        change_password(page)
        expect(page.locator("html")).to_have_attribute("data-rotation-reply", "200")
        # Ending the local browser session makes the following authoritative read return signed out.
        context.clear_cookies()
        page.evaluate("() => window.dropRotationAcknowledgment()")
        expect(page.get_by_role("button", name="Sign in", exact=True)).to_be_visible()
        expect(page.get_by_text(NOTICE, exact=False)).to_be_visible()
        expect(page.get_by_text("Password updated and session rotated.")).to_have_count(0)
        assert writes == ["POST"] and not errors
        page.get_by_role("button", name="Dismiss notice").click()
        expect(page.get_by_text(NOTICE, exact=False)).to_have_count(0)


@pytest.mark.tier3
@pytest.mark.parametrize("uncertain_read", [False, True], ids=["confirmed-list", "unconfirmed-list"])
def test_selected_session_revoke_preserves_replacement_draft_until_current_revoke(e2e_workspace, e2e_browser, uncertain_read):
    create_member(e2e_workspace)
    base = e2e_workspace.base_url
    with e2e_browser.new_context(viewport=DESKTOP_VIEWPORT) as context:
        page = context.new_page()
        sign_in_on_account(page, base, MEMBER_EMAIL, MEMBER_PASS)
        sessions = page.get_by_role("region", name="Active device sessions")
        current = sessions.get_by_role("row").filter(has_text="Current").get_by_role("button", name="Revoke")
        expect(current).to_be_visible()

        def current_id():
            reply = context.request.get(base + SESSIONS_PATH)
            assert reply.ok
            ids = [s["id"] for s in reply.json()["sessions"] if s["isCurrent"]]
            assert len(ids) == 1
            return ids[0]

        original = current_id()
        # A normal sign in replaces the shared cookie while this page still has its original rows.
        headers = {"X-InterviewCheck": "1"}
        assert context.request.post(base + "/api/integrations/access/login", headers=headers,
                                    data={"email": MEMBER_EMAIL, "password": MEMBER_PASS}).ok
        replacement = current_id()
        assert replacement != original
        interview = context.request.post(base + "/api/sessions", headers=headers, data={
            "candidate": "Synthetic draft", "role": "Engineer", "policy": "Notes permitted.", "consent": True,
        })
        assert interview.ok
        key = f"ic_draft_v1:{interview.json()['id']}:editor:new"
        draft = page.evaluate("""key => {
          const raw = JSON.stringify({question:'Design review',text:'Unfinished synthetic notes',savedAt:new Date().toISOString()});
          localStorage.setItem(key, raw);
          return raw;
        }""", key)
        deletes = []
        page.on("request", lambda r: deletes.append(urlsplit(r.url).path) if r.method == "DELETE" else None)
        if uncertain_read:
            page.route("**" + SESSIONS_PATH, lambda route: route.fulfill(status=200, json={"sessions": []}), times=1)
        current.click()
        expect(page.get_by_text("Revoked session (Portable workspace).", exact=True)).to_be_visible()
        if uncertain_read:
            expect(page.get_by_role("alert").filter(has_text="Check the current session to confirm access.")).to_be_visible()
            assert page.evaluate("key => localStorage.getItem(key)", key) == draft
            page.get_by_role("button", name="Check current session").click()
        expect(current).to_be_visible()
        assert deletes == [f"{SESSIONS_PATH}/{original}"]
        assert current_id() == replacement
        assert page.evaluate("key => localStorage.getItem(key)", key) == draft
        expect(page.get_by_text(MEMBER_EMAIL)).to_be_visible()

        if uncertain_read:
            page.route("**" + SESSIONS_PATH, lambda route: route.abort("failed"), times=1)
        current.click()
        if uncertain_read:
            expect(page.get_by_role("alert").filter(has_text="Check the current session to confirm access.")).to_be_visible()
            assert page.evaluate("key => localStorage.getItem(key)", key) == draft
            page.get_by_role("button", name="Check current session").click()
        expect(page.get_by_role("button", name="Sign in", exact=True)).to_be_visible()
        assert deletes == [f"{SESSIONS_PATH}/{original}", f"{SESSIONS_PATH}/{replacement}"]
        assert context.request.get(base + "/api/integrations/account").status == 401
        assert page.evaluate("key => localStorage.getItem(key)", key) is None
