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
        writes, replies, errors = [], [], []
        for target in ([page, other] if sibling else [page]):
            target.on("pageerror", lambda event: errors.append(str(event)))
        context.on("request", lambda r: writes.append(urlsplit(r.url).path)
                   if urlsplit(r.url).path in (PASSWORD_PATH, LOGOUT_PATH) else None)
        context.on("response", lambda r: replies.append((urlsplit(r.url).path, r.status))
                   if urlsplit(r.url).path in (PASSWORD_PATH, LOGOUT_PATH) else None)
        # Suspend at the app's fetch boundary while the password operation holds its order in the queue.
        page.evaluate("""acknowledged => {
          const send = window.fetch.bind(window);
          window.fetch = async (input, init) => {
            if (new URL(input instanceof Request ? input.url : input, location.href).pathname === '/api/integrations/access/password') {
              await new Promise(done => {
                window.finishRotationFixture = done;
                document.documentElement.dataset.passwordSend = 'waiting';
              });
              const reply = await send(input, init);
              return acknowledged ? reply : new Response('{}', {status:200, headers:{'Content-Type':'application/json'}});
            }
            return send(input, init);
          };
        }""", acknowledged)
        change_password(page)
        expect(page.locator("html")).to_have_attribute("data-password-send", "waiting")
        signout = other.get_by_role("button", name="Sign out", exact=True)
        signout.click()
        expect(signout).to_be_disabled()
        assert context.request.get(base + "/api/integrations/account").ok
        assert writes == [] and replies == []
        with other.expect_response(lambda r: r.url == base + LOGOUT_PATH) as logged_out:
            page.evaluate("() => window.finishRotationFixture()")
        assert logged_out.value.ok
        expect(other.get_by_role("button", name="Sign in", exact=True)).to_be_visible(timeout=15_000)
        assert writes == [PASSWORD_PATH, LOGOUT_PATH]
        assert replies == [(PASSWORD_PATH, 200), (LOGOUT_PATH, 200)]
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
