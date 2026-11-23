"""The ?next= return path after signing in stays on this site and brings a deep link back."""
from pathlib import Path
import re
import sys
from urllib.parse import quote, urlsplit

import pytest
from playwright.sync_api import expect

QA_ROOT = Path(__file__).resolve().parent
if str(QA_ROOT) not in sys.path:
    sys.path.insert(0, str(QA_ROOT))

from e2e_suite.harness import DESKTOP_VIEWPORT, IsolatedWorkspace, signup_user  # noqa: E402

EMAIL = "redirect-fixture@example.test"
PASSWORD = "Synthetic-Redirect-Pass-7319"
# Browsers read "\" as "/" and drop tabs, so both of these resolve to //evil.example without validation.
FOREIGN_NEXT = ("/%5Cevil.example", "/%09/evil.example")


@pytest.fixture
def accounts_workspace(tmp_path, monkeypatch, frontend):
    ws = IsolatedWorkspace(tmp_path, monkeypatch, frontend)
    ws.prepare_env()
    ws.configure_embedded_auth(admin_emails=("nobody@example.test",))
    ws.start()
    with ws.client() as client:
        signup_user(client, email=EMAIL, password=PASSWORD)
    try:
        yield ws
    finally:
        ws.stop()


def _page(browser):
    context = browser.new_context(viewport=DESKTOP_VIEWPORT, reduced_motion="reduce")
    page = context.new_page()
    page.set_default_timeout(10_000)
    return context, page


def _sign_in(page):
    page.get_by_label("Operator email").fill(EMAIL)
    page.get_by_label("Password", exact=True).fill(PASSWORD)
    page.get_by_role("button", name="Sign in", exact=True).click()


@pytest.mark.parametrize("payload", FOREIGN_NEXT)
def test_sign_in_ignores_a_next_path_that_leaves_the_site(accounts_workspace, qa_browser, payload):
    context, page = _page(qa_browser)
    foreign = []
    page.route(lambda url: urlsplit(url).hostname == "evil.example",
               lambda route: (foreign.append(route.request.url), route.abort()))
    try:
        origin = urlsplit(accounts_workspace.base_url).netloc
        page.goto(accounts_workspace.base_url + "/account/?next=" + payload, wait_until="domcontentloaded")
        _sign_in(page)
        expect(page.get_by_role("button", name="Sign out", exact=True)).to_be_visible()
        # The fallback reload fires 5 seconds after sign in; wait past it before checking the origin.
        page.wait_for_timeout(5500)
        assert urlsplit(page.url).netloc == origin
        assert not foreign
    finally:
        context.close()


def test_sign_in_follows_a_same_site_next_path(accounts_workspace, qa_browser):
    context, page = _page(qa_browser)
    try:
        page.goto(accounts_workspace.base_url + "/account/?next=" + quote("/roles/?tab=all#saved"),
                  wait_until="domcontentloaded")
        _sign_in(page)
        expect(page).to_have_url(re.compile(r"/roles/\?tab=all#saved$"))
        expect(page.get_by_role("heading", name="Role library")).to_be_visible()
    finally:
        context.close()


def test_signed_out_deep_link_returns_to_the_review_after_sign_in(accounts_workspace, qa_browser):
    with accounts_workspace.client() as client:
        client.post("/api/integrations/access/login", json={"email": EMAIL, "password": PASSWORD}).raise_for_status()
        session = client.post("/api/sessions", json={
            "candidate": "Deep link candidate", "role": "Engineer", "policy": "Notes allowed.", "consent": True,
        })
        session.raise_for_status()
    review_path = "/interviews/review/?id=" + session.json()["id"]
    context, page = _page(qa_browser)
    try:
        page.goto(accounts_workspace.base_url + review_path, wait_until="domcontentloaded")
        sign_in = page.get_by_role("status").get_by_role("link", name="Sign in")
        expect(sign_in).to_have_attribute("href", "/account/?next=" + quote(review_path, safe=""))
        sign_in.click()
        expect(page.get_by_role("heading", name="Sign in")).to_be_visible()
        _sign_in(page)
        expect(page).to_have_url(re.compile(re.escape(review_path) + "$"))
        expect(page.get_by_role("heading", name="Deep link candidate")).to_be_visible()
    finally:
        context.close()
