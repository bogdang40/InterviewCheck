"""Tier 3 opaque-box cross-viewport, theme persistence, contrast, and navigation tests."""
import re

import pytest
from playwright.sync_api import expect

from e2e_suite.harness import (
    DESKTOP_VIEWPORT,
    MOBILE_VIEWPORT,
    assert_no_horizontal_overflow,
    signup_user,
)

ADMIN_EMAIL = "admin-t3-vp@example.test"
BOOTSTRAP_SECRET = "t3-bootstrap-secret-1234"
ADMIN_PASS = "Synthetic-T3-Admin-Pass-1"

CHECK_ROUTES = (
    "/",
    "/interviews/",
    "/interviews/new/",
    "/roles/",
    "/connections/",
    "/data/",
    "/account/",
    "/admin/",
)

CONTRAST_SCRIPT = """() => {
  function parseRgb(str) {
    const m = str.match(/rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)(?:,\\s*([\\d.]+))?\\)/);
    if (!m) return null;
    return { r: Number(m[1]), g: Number(m[2]), b: Number(m[3]), a: m[4] === undefined ? 1 : Number(m[4]) };
  }
  function effectiveBg(el) {
    let cur = el;
    while (cur) {
      const bg = parseRgb(getComputedStyle(cur).backgroundColor);
      if (bg && bg.a > 0.1) return bg;
      cur = cur.parentElement;
    }
    return parseRgb(getComputedStyle(document.body).backgroundColor) || { r: 255, g: 255, b: 255, a: 1 };
  }
  function relLum(c) {
    const chan = [c.r, c.g, c.b].map((v) => {
      const s = v / 255;
      return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * chan[0] + 0.7152 * chan[1] + 0.0722 * chan[2];
  }
  function ratio(fg, bg) {
    const l1 = relLum(fg);
    const l2 = relLum(bg);
    return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
  }
  const heading = document.querySelector("main#main-content h1") || document.querySelector("main#main-content");
  const fg = parseRgb(getComputedStyle(heading).color);
  const bg = effectiveBg(heading);
  const bodyFg = parseRgb(getComputedStyle(document.body).color);
  const bodyBg = parseRgb(getComputedStyle(document.body).backgroundColor);
  return {
    theme: document.documentElement.dataset.theme,
    headingRatio: ratio(fg, bg),
    bodyRatio: ratio(bodyFg, bodyBg),
    bodyBg,
  };
}"""

LAYOUT_BOUNDS_SCRIPT = """() => {
  const vw = window.innerWidth;
  const headerSelectors = [".nav-toggle", ".breadcrumb", ".account-link"];
  const headerRects = [];
  for (const sel of headerSelectors) {
    const el = document.querySelector(sel);
    if (!el) continue;
    const style = getComputedStyle(el);
    if (style.display === "none" || style.visibility === "hidden") continue;
    const r = el.getBoundingClientRect();
    if (r.width === 0 && r.height === 0) continue;
    headerRects.push({ sel, left: r.left, right: r.right, top: r.top, bottom: r.bottom });
  }
  const overlaps = [];
  for (let i = 0; i < headerRects.length; i++) {
    const a = headerRects[i];
    if (a.left < -1 || a.right > vw + 1) {
      overlaps.push(`Clipped header element ${a.sel}: [${a.left}, ${a.right}] vs vw=${vw}`);
    }
    for (let j = i + 1; j < headerRects.length; j++) {
      const b = headerRects[j];
      const hit = a.right > b.left + 1 && b.right > a.left + 1 && a.bottom > b.top + 1 && b.bottom > a.top + 1;
      if (hit) overlaps.push(`Overlap ${a.sel} vs ${b.sel}`);
    }
  }
  const clippedControls = [];
  for (const el of document.querySelectorAll("main#main-content button, main#main-content a, main#main-content input, main#main-content select")) {
    const style = getComputedStyle(el);
    if (style.display === "none" || style.visibility === "hidden") continue;
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    if (r.left < -1 || r.right > vw + 1) {
      clippedControls.push(`${el.tagName}:${(el.textContent || "").trim().slice(0, 24)} [${r.left},${r.right}] vw=${vw}`);
    }
  }
  return { overlaps, clippedControls, headerCount: headerRects.length };
}"""


def _sign_in_admin_browser(page, base_url: str) -> None:
    page.goto(base_url + "/account/", wait_until="domcontentloaded")
    page.get_by_label("Operator email").fill(ADMIN_EMAIL)
    page.get_by_label("Password", exact=True).fill(ADMIN_PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(ADMIN_EMAIL)).to_be_visible()


@pytest.mark.tier3
@pytest.mark.parametrize("is_mobile", [False, True], ids=["desktop-1440x900", "mobile-390x844"])
def test_theme_switching_persists_across_routes_and_reloads(e2e_workspace, e2e_browser, is_mobile):
    viewport = MOBILE_VIEWPORT if is_mobile else DESKTOP_VIEWPORT
    ctx = e2e_browser.new_context(viewport=viewport, reduced_motion="reduce", is_mobile=is_mobile, has_touch=is_mobile)
    page = ctx.new_page()
    try:
        page.goto(e2e_workspace.base_url + "/account/", wait_until="domcontentloaded")
        expect(page.locator("section.appearance")).to_have_attribute("data-hydrated", "true")
        expect(page.locator("html")).to_have_attribute("data-theme", "dark")
        expect(page.get_by_text("Local workspace.")).to_be_visible()

        page.get_by_role("radio", name="Light").check()
        expect(page.locator("html")).to_have_attribute("data-theme", "light")
        assert page.evaluate("() => localStorage.getItem('interviewcheck.appearance')") == "light"

        for route in ("/", "/roles/", "/connections/", "/data/"):
            page.goto(e2e_workspace.base_url + route, wait_until="networkidle")
            expect(page.locator("main#main-content")).to_be_visible()
            expect(page.locator("html")).to_have_attribute("data-theme", "light")
            assert_no_horizontal_overflow(page)

        page.reload(wait_until="networkidle")
        expect(page.locator("main#main-content")).to_be_visible()
        expect(page.locator("html")).to_have_attribute("data-theme", "light")

        page.goto(e2e_workspace.base_url + "/account/", wait_until="domcontentloaded")
        expect(page.locator("section.appearance")).to_have_attribute("data-hydrated", "true")
        expect(page.get_by_text("Local workspace.")).to_be_visible()
        page.get_by_role("radio", name="Dark").check()
        expect(page.locator("html")).to_have_attribute("data-theme", "dark")
        page.reload(wait_until="networkidle")
        expect(page.locator("main#main-content")).to_be_visible()
        expect(page.locator("html")).to_have_attribute("data-theme", "dark")
    finally:
        ctx.close()


@pytest.mark.tier3
def test_dark_and_light_themes_maintain_readable_contrast_and_zero_overflow(e2e_workspace, desktop_page, mobile_page):
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)

    for label, (page, collector) in (("desktop", desktop_page), ("mobile", mobile_page)):
        _sign_in_admin_browser(page, e2e_workspace.base_url)
        for theme in ("dark", "light"):
            page.goto(e2e_workspace.base_url + "/account/", wait_until="domcontentloaded")
            expect(page.locator("section.appearance")).to_have_attribute("data-hydrated", "true")
            expect(page.get_by_text(ADMIN_EMAIL)).to_be_visible()
            page.get_by_role("radio", name=theme.capitalize()).check()
            expect(page.locator("html")).to_have_attribute("data-theme", theme)

            for route in CHECK_ROUTES:
                page.goto(e2e_workspace.base_url + route, wait_until="networkidle")
                expect(page.locator("main#main-content")).to_be_visible()
                expect(page.locator("html")).to_have_attribute("data-theme", theme)
                assert_no_horizontal_overflow(page)
                metrics = page.evaluate(CONTRAST_SCRIPT)
                assert metrics["theme"] == theme, f"{label} {route} theme mismatch"
                assert metrics["headingRatio"] >= 4.5, f"{label} {route} {theme} heading contrast {metrics['headingRatio']}"
                assert metrics["bodyRatio"] >= 4.5, f"{label} {route} {theme} body contrast {metrics['bodyRatio']}"
                if theme == "light":
                    assert metrics["bodyBg"]["r"] > 200
                else:
                    assert metrics["bodyBg"]["r"] < 40
        collector.assert_clean()


@pytest.mark.tier3
def test_desktop_and_mobile_layout_parity_no_clipped_or_overlapping_controls(e2e_workspace, desktop_page, mobile_page):
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)

    d_page, d_collector = desktop_page
    _sign_in_admin_browser(d_page, e2e_workspace.base_url)
    for route in CHECK_ROUTES:
        d_page.goto(e2e_workspace.base_url + route, wait_until="domcontentloaded")
        expect(d_page.get_by_role("navigation", name="Workspace")).to_be_visible()
        expect(d_page.get_by_role("button", name="Open navigation menu")).to_be_hidden()
        bounds = d_page.evaluate(LAYOUT_BOUNDS_SCRIPT)
        assert not bounds["overlaps"], f"Desktop {route} header issue: {bounds['overlaps']}"
        assert not bounds["clippedControls"], f"Desktop {route} clipped controls: {bounds['clippedControls']}"
        assert_no_horizontal_overflow(d_page)
    d_collector.assert_clean()

    m_page, m_collector = mobile_page
    _sign_in_admin_browser(m_page, e2e_workspace.base_url)
    for route in CHECK_ROUTES:
        m_page.goto(e2e_workspace.base_url + route, wait_until="domcontentloaded")
        expect(m_page.get_by_role("button", name="Open navigation menu")).to_be_visible()
        expect(m_page.locator("aside.sidebar")).to_have_attribute("aria-hidden", "true")
        bounds = m_page.evaluate(LAYOUT_BOUNDS_SCRIPT)
        assert not bounds["overlaps"], f"Mobile {route} header issue: {bounds['overlaps']}"
        assert not bounds["clippedControls"], f"Mobile {route} clipped controls: {bounds['clippedControls']}"
        assert_no_horizontal_overflow(m_page)
    m_collector.assert_clean()


@pytest.mark.tier3
def test_mobile_drawer_navigation_keyboard_escape_backdrop_and_skip_link(e2e_workspace, mobile_page):
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)

    page, collector = mobile_page
    _sign_in_admin_browser(page, e2e_workspace.base_url)
    page.goto(e2e_workspace.base_url + "/", wait_until="domcontentloaded")

    # Skip link points to #main-content and moves focus cleanly.
    skip = page.locator("a.skip-content")
    expect(skip).to_have_attribute("href", "#main-content")
    skip.focus()
    skip.press("Enter")
    expect(page.locator("main#main-content")).to_be_focused()

    toggle = page.get_by_role("button", name="Open navigation menu")
    sidebar = page.locator("aside.sidebar")
    expect(sidebar).to_have_attribute("aria-hidden", "true")

    # Open drawer and close with Escape, restoring focus to toggle button.
    toggle.click()
    expect(sidebar).to_have_class(re.compile(r"\bopen\b"))
    page.keyboard.press("Escape")
    expect(sidebar).not_to_have_class(re.compile(r"\bopen\b"))
    expect(toggle).to_be_focused()

    # Open drawer and close via clicking exposed right strip of backdrop.
    toggle.click()
    backdrop = page.locator(".drawer-backdrop")
    expect(backdrop).to_be_visible()
    backdrop.click(position={"x": 360, "y": 200})
    expect(sidebar).not_to_have_class(re.compile(r"\bopen\b"))

    # Navigate across workspace routes using the mobile drawer.
    destinations = (
        ("Interviews", r"/interviews/?$", "Interviews"),
        ("Role library", r"/roles/?$", "Role library"),
        ("Connections", r"/connections/?$", "Connections"),
        ("Data", r"/data/?$", "Workspace data"),
        ("Admin", r"/admin/?$", "Model administration"),
        ("Overview", r"/$", "Interview workspace"),
    )
    nav = page.get_by_role("navigation", name="Workspace")
    for label, url_pattern, heading in destinations:
        toggle.click()
        link = nav.get_by_role("link", name=label, exact=True)
        expect(link).to_be_visible()
        link.click()
        expect(page).to_have_url(re.compile(url_pattern))
        expect(page.get_by_role("heading", name=heading).first).to_be_visible()
        expect(sidebar).not_to_have_class(re.compile(r"\bopen\b"))
        assert_no_horizontal_overflow(page)

    collector.assert_clean()
