"""Synthetic account fixtures and browser signals for password changes."""
from playwright.sync_api import expect

from e2e_suite.harness import ConsoleErrorCollector, DESKTOP_VIEWPORT

ADMIN1_EMAIL = "admin1-t3@example.test"
MEMBER_EMAIL = "member-t3@example.test"
BOOTSTRAP_SECRET = "t3-admin-bootstrap-1234"
ADMIN_PASS = "Synthetic-T3-Admin-Pass-1"
NEW_ADMIN_PASS = "Synthetic-T3-Admin-Pass-2"
MEMBER_PASS = "Synthetic-T3-Member-Pass-1"


def open_account_context(browser):
    ctx = browser.new_context(viewport=DESKTOP_VIEWPORT, reduced_motion="reduce")
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    page.set_default_navigation_timeout(30_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    return ctx, page, collector


def sign_in_on_account(page, base_url: str, email: str, password: str) -> None:
    page.goto(base_url + "/account/", wait_until="domcontentloaded")
    page.get_by_label("Operator email").fill(email)
    page.get_by_label("Password", exact=True).fill(password)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(email)).to_be_visible()


def delay_rotation_deliveries(page):
    # Keep independent browser fetch promises. Each response has exactly one consumer,
    # including the real password response whose fresh cookie the browser already accepted.
    page.evaluate("""() => {
      const send = window.fetch.bind(window);
      const phase = window.rotationFixture = {};
      let firstAccount = true, firstStatus = true;
      window.fetch = async (input, init) => {
        const url = new URL(input instanceof Request ? input.url : input, location.href);
        if (firstAccount && url.pathname === '/api/integrations/account') {
          firstAccount = false;
          const stale = await new Promise(resolve => {
            phase.releaseRead = resolve;
            document.documentElement.dataset.rotationRead = 'waiting';
          });
          document.documentElement.dataset.rotationRead = 'returned';
          return new Response(stale.body, {status: stale.status, headers: {'Content-Type': 'application/json'}});
        }
        const response = await send(input, init);
        if (url.pathname === '/api/integrations/access/password') {
          phase.passwordStatus = response.status;
          await new Promise(resolve => {
            phase.releasePassword = resolve;
            document.documentElement.dataset.rotationPassword = 'waiting';
          });
          phase.ackReturned = true;
        } else if (phase.ackReturned && firstStatus && url.pathname === '/api/integrations/status') {
          firstStatus = false;
          await new Promise(resolve => {
            phase.releaseStatus = resolve;
            document.documentElement.dataset.rotationStatus = 'waiting';
          });
        }
        return response;
      };
    }""")
