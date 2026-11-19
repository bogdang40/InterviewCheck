"""Opaque-box Playwright E2E tests for M16 WCAG AA contrast, command palette, and metrics."""
import re

from playwright.sync_api import expect
import pytest

from e2e_suite.harness import ConsoleErrorCollector, assert_no_horizontal_overflow, login_user, signup_user

ADMIN_EMAIL, MEMBER_EMAIL = "admin-m16@example.test", "member-m16@example.test"
BOOTSTRAP_SECRET = "m16-bootstrap-secret-1234"
ADMIN_PASS, MEMBER_PASS = "Synthetic-M16-Admin-Pass-1", "Synthetic-M16-Member-Pass-1"
MODEL_SECRET, METRICS_TOKEN = "sk-m16-e2e-secret-9999", "m16-e2e-metrics-bearer-token"

KEY_ROUTES = ("/", "/interviews/", "/roles/", "/account/", "/data/", "/admin/")
ADMIN_TABS = ("Models", "Accounts", "Audit log", "Diagnostics", "Playground", "Security")

WCAG_CONTRAST_JS = """() => {
  const canvas = document.createElement("canvas");
  canvas.width = 1; canvas.height = 1;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  function parseColor(cssColor) {
    ctx.clearRect(0, 0, 1, 1); ctx.fillStyle = "rgba(0, 0, 0, 0)"; ctx.fillStyle = cssColor;
    ctx.fillRect(0, 0, 1, 1); const d = ctx.getImageData(0, 0, 1, 1).data;
    return [d[0], d[1], d[2], d[3]];
  }
  function blendOver(cssColor, baseRgb) {
    ctx.clearRect(0, 0, 1, 1);
    ctx.fillStyle = `rgb(${baseRgb[0]},${baseRgb[1]},${baseRgb[2]})`; ctx.fillRect(0, 0, 1, 1);
    ctx.fillStyle = cssColor; ctx.fillRect(0, 0, 1, 1);
    const d = ctx.getImageData(0, 0, 1, 1).data; return [d[0], d[1], d[2]];
  }
  function tokenRgb(token) {
    const n = document.createElement("span"); n.style.color = `var(${token})`;
    document.body.append(n); const c = parseColor(getComputedStyle(n).color); n.remove();
    return [c[0], c[1], c[2]];
  }
  function lum(c) {
    return c.reduce((acc, v, idx) => {
      const s = v / 255;
      const lin = s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
      return acc + [0.2126, 0.7152, 0.0722][idx] * lin;
    }, 0);
  }
  function ratio(c1, c2) {
    const [a, b] = [lum(c1), lum(c2)].sort((x, y) => y - x);
    return Number(((a + 0.05) / (b + 0.05)).toFixed(2));
  }
  const surfaceRgb = tokenRgb("--surface");
  function paintedBg(el, includeSelf) {
    const layers = []; let cur = includeSelf ? el : el.parentElement;
    while (cur) {
      const bg = getComputedStyle(cur).backgroundColor, rgba = parseColor(bg);
      if (rgba[3] > 0) { layers.push(bg); if (rgba[3] >= 254) break; }
      cur = cur.parentElement;
    }
    let acc = surfaceRgb;
    for (let i = layers.length - 1; i >= 0; i--) acc = blendOver(layers[i], acc);
    return acc;
  }
  const tokenPairs = {
    ink_on_surface: ratio(tokenRgb("--ink"), surfaceRgb),
    muted_on_surface: ratio(tokenRgb("--muted"), surfaceRgb),
    secondary_on_surface: ratio(tokenRgb("--secondary-ink"), surfaceRgb),
    green_on_selected: ratio(tokenRgb("--green-ink"), tokenRgb("--selected-bg")),
    error_on_bg: ratio(tokenRgb("--error-text"), tokenRgb("--error-bg")),
    attention_on_bg: ratio(tokenRgb("--attention"), tokenRgb("--warning-bg")),
    input_on_surface: ratio(tokenRgb("--color-input"), surfaceRgb),
  };
  const textFailures = [], controlFailures = [];
  for (const el of document.querySelectorAll("h1, h2, h3, p, label, a, button, [role='tab'], th, td, small, .notice")) {
    const cs = getComputedStyle(el);
    if (cs.display === "none" || cs.visibility === "hidden" || Number(cs.opacity) < 0.99) continue;
    if (el.closest(".sr-only") || el.matches(":disabled, [aria-disabled='true']")) continue;
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    if (![...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim().length > 0)) continue;
    const bg = paintedBg(el, true), fgRgba = parseColor(cs.color);
    const fg = fgRgba[3] >= 254 ? [fgRgba[0], fgRgba[1], fgRgba[2]] : blendOver(cs.color, bg);
    const cr = ratio(fg, bg), fs = parseFloat(cs.fontSize) || 14, fw = parseInt(cs.fontWeight, 10) || 400;
    const minReq = (fs >= 24 || (fs >= 18.66 && fw >= 700)) ? 3.0 : 4.5;
    if (cr < minReq) textFailures.push({ tag: el.tagName, text: (el.textContent || "").trim().slice(0, 40), ratio: cr, minReq });
  }
  for (const el of document.querySelectorAll("select, input:not([type='checkbox']):not([type='radio']):not([type='hidden']), textarea")) {
    const cs = getComputedStyle(el);
    if (cs.display === "none" || cs.visibility === "hidden" || el.closest(".sr-only") || el.matches(":disabled")) continue;
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0 || parseFloat(cs.borderTopWidth) <= 0 || cs.borderTopStyle === "none") continue;
    const bRgba = parseColor(cs.borderTopColor);
    if (bRgba[3] === 0) continue;
    const bg = paintedBg(el, false);
    const bRgb = bRgba[3] >= 254 ? [bRgba[0], bRgba[1], bRgba[2]] : blendOver(cs.borderTopColor, bg);
    const cr = ratio(bRgb, bg);
    if (cr < 3.0) controlFailures.push({ tag: el.tagName, ratio: cr });
  }
  return { tokenPairs, textFailures, controlFailures };
}"""


def _setup_workspace(e2e_workspace, *, include_member: bool = False) -> tuple[str, str]:
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
        if include_member:
            signup_user(c, email=MEMBER_EMAIL, password=MEMBER_PASS)
        c.cookies.clear()
        login_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS)
        c.post("/api/admin/models", json={
            "slug": "m16-ref-model", "display_name": "M16 Reference Model", "provider": "openai",
            "capability": "reference", "model_id": "gpt-4o-mini", "apiKey": MODEL_SECRET, "enabled": True, "is_default": True,
        }).raise_for_status()
        role = c.post("/api/roles", json={
            "name": "Systems Lead", "description": "Distributed systems design and durability",
            "questions": ["Explain WAL durability.", "Explain Raft consensus."], "policy": "Rubric", "permitted_sources": [],
        })
        role.raise_for_status()
        role_id = role.json()["id"]
        s1 = c.post("/api/sessions", json={"candidate": "Ada Lovelace", "role": "Systems Lead", "role_id": role_id, "policy": "Rubric", "consent": True})
        s2 = c.post("/api/sessions", json={"candidate": "Grace Hopper", "role": "Systems Lead", "role_id": role_id, "policy": "Rubric", "consent": True})
        s1.raise_for_status(); s2.raise_for_status()
        sid1, sid2 = s1.json()["id"], s2.json()["id"]
        c.post(f"/api/sessions/{sid1}/answers", json={"question": "Explain WAL durability.", "answer": "Fsync before ack.", "references": [], "planned_slot": 1}).raise_for_status()
        c.post(f"/api/sessions/{sid2}/answers", json={"question": "Explain WAL durability.", "answer": "Group commit flushes.", "references": [], "planned_slot": 1}).raise_for_status()
        return sid1, sid2


def _sign_in(page, base_url: str, email: str, password: str) -> None:
    page.context.clear_cookies()
    page.goto(base_url + "/account/", wait_until="domcontentloaded")
    page.get_by_label("Operator email").fill(email)
    page.get_by_label("Password", exact=True).fill(password)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(email)).to_be_visible()


def _assert_route_contrast(page, route: str, theme: str) -> None:
    report = page.evaluate(WCAG_CONTRAST_JS)
    pairs = report["tokenPairs"]
    for name in ("ink_on_surface", "muted_on_surface", "secondary_on_surface", "green_on_selected", "error_on_bg", "attention_on_bg"):
        assert pairs[name] >= 4.5, f"{theme} {route} token {name}={pairs[name]} < 4.5"
    assert pairs["input_on_surface"] >= 3.0, f"{theme} {route} input_on_surface={pairs['input_on_surface']} < 3.0"
    assert not report["textFailures"], f"{theme} {route} text contrast failures: {report['textFailures']}"
    assert not report["controlFailures"], f"{theme} {route} control border failures: {report['controlFailures']}"


def test_m16_wcag_contrast_and_focus_rings_light_dark(e2e_workspace, desktop_page):
    sid1, sid2 = _setup_workspace(e2e_workspace)
    page, collector = desktop_page
    _sign_in(page, e2e_workspace.base_url, ADMIN_EMAIL, ADMIN_PASS)
    routes = KEY_ROUTES + (f"/interviews/compare/?ids={sid1},{sid2}",)

    for theme in ("light", "dark"):
        page.goto(e2e_workspace.base_url + "/account/", wait_until="domcontentloaded")
        expect(page.get_by_text(ADMIN_EMAIL)).to_be_visible()
        page.get_by_role("radio", name=theme.capitalize()).check()
        expect(page.locator("html")).to_have_attribute("data-theme", theme)
        for route in routes:
            page.goto(e2e_workspace.base_url + route, wait_until="domcontentloaded")
            expect(page.locator("main#main-content")).to_be_visible()
            if route == "/admin/":
                expect(page.get_by_role("tablist", name="Admin sections")).to_be_visible()
            _assert_route_contrast(page, route, theme)

        page.goto(e2e_workspace.base_url + "/", wait_until="domcontentloaded")
        page.locator(".studio-hero button").first.focus()
        page.keyboard.press("Tab")
        ring = page.evaluate("() => { const cs = getComputedStyle(document.activeElement); return { style: cs.outlineStyle, width: parseFloat(cs.outlineWidth) || 0 }; }")
        assert ring["style"] != "none" and ring["width"] >= 2.0, f"{theme} focus ring invalid: {ring}"

        page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
        tablist = page.get_by_role("tablist", name="Admin sections")
        expect(tablist).to_be_visible()
        for tab_label in ADMIN_TABS:
            tab = tablist.get_by_role("tab", name=tab_label)
            tab.click()
            expect(tab).to_have_attribute("aria-selected", "true")
            _assert_route_contrast(page, f"/admin/#{tab_label}", theme)
        tablist.get_by_role("tab", name="Models").focus()
        page.keyboard.press("ArrowRight")
        tab_ring = page.evaluate("() => { const cs = getComputedStyle(document.activeElement); return { style: cs.outlineStyle, width: parseFloat(cs.outlineWidth) || 0 }; }")
        assert tab_ring["style"] != "none" and tab_ring["width"] >= 2.0, f"{theme} tab ring: {tab_ring}"

    collector.assert_clean()


def test_m16_command_palette_navigation_theme_and_shortcut_modal(e2e_workspace, desktop_page):
    _setup_workspace(e2e_workspace, include_member=True)
    page, collector = desktop_page
    _sign_in(page, e2e_workspace.base_url, MEMBER_EMAIL, MEMBER_PASS)
    page.goto(e2e_workspace.base_url + "/", wait_until="domcontentloaded")
    expect(page.get_by_text("Ada Lovelace")).to_be_visible()

    trigger = page.get_by_role("button", name="Search workspace")
    trigger.focus()
    page.keyboard.press("Control+k")
    palette = page.get_by_role("dialog", name="Search workspace")
    expect(palette).to_be_visible()
    combobox = palette.get_by_role("combobox", name="Search workspace records")
    expect(combobox).to_be_focused()
    expect(palette.get_by_role("option", name=re.compile("Go to Overview"))).to_be_visible()
    expect(palette.get_by_role("option", name=re.compile("Go to Model admin"))).to_have_count(0)

    combobox.fill("Switch theme: Dark")
    expect(palette.get_by_role("option", name=re.compile("Switch theme: Dark"))).to_be_visible()
    page.keyboard.press("Enter")
    expect(palette).not_to_be_visible()
    expect(page.locator("html")).to_have_attribute("data-theme", "dark")
    assert page.evaluate("() => localStorage.getItem('interviewcheck.appearance')") == "dark"
    expect(trigger).to_be_focused()

    page.keyboard.press("Control+k")
    expect(palette).to_be_visible()
    combobox.fill("Compare candidates")
    expect(palette.get_by_role("option", name=re.compile("Compare candidates"))).to_be_visible()
    page.keyboard.press("Enter")
    expect(page.get_by_role("heading", name="Candidate comparison")).to_be_visible()
    assert "/interviews/compare/" in page.url

    page.goto(e2e_workspace.base_url + "/interviews/", wait_until="domcontentloaded")
    expect(page.get_by_text("Ada Lovelace")).to_be_visible()
    page.get_by_label("Search interviews").focus()
    page.keyboard.press("?")
    expect(page.locator("dialog.shortcut-dialog")).to_have_count(0)

    trigger.focus()
    page.keyboard.press("?")
    help_modal = page.get_by_role("dialog", name="Keyboard shortcuts")
    expect(help_modal).to_be_visible()
    expect(help_modal.get_by_role("button", name="Close keyboard shortcuts")).to_be_focused()
    for key_seq in ("Tab", "Tab", "Tab", "Tab", "Shift+Tab", "Shift+Tab"):
        page.keyboard.press(key_seq)
        assert page.evaluate("() => Boolean(document.querySelector('dialog.shortcut-dialog')?.contains(document.activeElement))") is True
    page.keyboard.press("Escape")
    expect(help_modal).to_have_count(0)
    expect(trigger).to_be_focused()

    page.keyboard.press("Control+k")
    expect(palette).to_be_visible()
    palette.get_by_role("button", name=re.compile("Shortcuts")).click()
    expect(help_modal).to_be_visible()
    expect(help_modal.get_by_role("button", name="Close keyboard shortcuts")).to_be_focused()
    page.keyboard.press("Escape")
    expect(help_modal).to_have_count(0)
    expect(trigger).to_be_focused()

    _sign_in(page, e2e_workspace.base_url, ADMIN_EMAIL, ADMIN_PASS)
    page.goto(e2e_workspace.base_url + "/", wait_until="domcontentloaded")
    expect(page.get_by_role("link", name="Admin", exact=True)).to_be_visible()
    page.keyboard.press("Control+k")
    expect(palette).to_be_visible()
    combobox.fill("Go to Model admin")
    expect(palette.get_by_role("option", name=re.compile("Go to Model admin"))).to_be_visible()
    page.keyboard.press("Enter")
    expect(page.get_by_role("heading", name="Model administration")).to_be_visible()
    collector.assert_clean()


@pytest.mark.parametrize(
    "viewport",
    [(320, 640, "mobile-320"), (390, 844, "mobile-390"), (1440, 900, "desktop-1440")],
    ids=lambda v: v[2],
)
def test_m16_responsive_viewports_zero_overflow_and_clean_console(e2e_workspace, e2e_browser, viewport):
    width, height, _ = viewport
    sid1, sid2 = _setup_workspace(e2e_workspace)
    mobile = width <= 480
    ctx = e2e_browser.new_context(viewport={"width": width, "height": height}, reduced_motion="reduce", is_mobile=mobile, has_touch=mobile)
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    page.set_default_navigation_timeout(30_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    try:
        _sign_in(page, e2e_workspace.base_url, ADMIN_EMAIL, ADMIN_PASS)
        routes = KEY_ROUTES + (f"/interviews/compare/?ids={sid1},{sid2}",)
        for theme in ("light", "dark"):
            page.goto(e2e_workspace.base_url + "/account/", wait_until="domcontentloaded")
            expect(page.get_by_text(ADMIN_EMAIL)).to_be_visible()
            page.get_by_role("radio", name=theme.capitalize()).check()
            expect(page.locator("html")).to_have_attribute("data-theme", theme)
            for route in routes:
                page.goto(e2e_workspace.base_url + route, wait_until="domcontentloaded")
                expect(page.locator("main#main-content")).to_be_visible()
                assert_no_horizontal_overflow(page)
        page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
        tablist = page.get_by_role("tablist", name="Admin sections")
        expect(tablist).to_be_visible()
        for tab_label in ADMIN_TABS:
            tablist.get_by_role("tab", name=tab_label).click()
            assert_no_horizontal_overflow(page)
        collector.assert_clean()
    finally:
        ctx.close()


def test_m16_admin_metrics_auth_prometheus_json_and_zero_pii(e2e_workspace, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_METRICS_TOKEN", METRICS_TOKEN)
    _setup_workspace(e2e_workspace, include_member=True)

    with e2e_workspace.client() as anon:
        assert anon.get("/api/admin/metrics").status_code == 401
        assert anon.get("/api/admin/metrics", headers={"Authorization": "Bearer wrong-token"}).status_code == 401
        token_res = anon.get("/api/admin/metrics?format=json", headers={"Authorization": f"Bearer {METRICS_TOKEN}"})
        assert token_res.status_code == 200 and token_res.headers.get("cache-control") == "no-store"

    with e2e_workspace.client() as mem:
        login_user(mem, email=MEMBER_EMAIL, password=MEMBER_PASS)
        assert mem.get("/api/admin/metrics").status_code == 403
        assert mem.get("/api/admin/metrics?format=json").status_code == 403

    with e2e_workspace.client() as admin:
        login_user(admin, email=ADMIN_EMAIL, password=ADMIN_PASS)
        prom = admin.get("/api/admin/metrics")
        assert prom.status_code == 200
        assert prom.headers.get("content-type", "").startswith("text/plain; version=0.0.4")
        assert prom.headers.get("cache-control") == "no-store"
        for metric_name in (
            "ic_http_requests_total", "ic_http_request_duration_ms_bucket", "ic_rate_limit_rejections_total",
            "ic_sqlite_wal_bytes", "ic_sqlite_page_count", "ic_connected_models_total", "ic_sessions_total",
        ):
            assert metric_name in prom.text, f"Missing Prometheus metric {metric_name}"

        js = admin.get("/api/admin/metrics?format=json")
        assert js.status_code == 200 and js.headers.get("cache-control") == "no-store"
        payload = js.json()
        assert {"http", "sqlite_wal_bytes", "sqlite_page_count", "connected_models", "sessions"} <= set(payload.keys())
        assert payload["sessions"]["active"] >= 2
        assert admin.get("/api/admin/metrics?format=xml").status_code == 422
        for forbidden in (ADMIN_EMAIL, MEMBER_EMAIL, MODEL_SECRET, METRICS_TOKEN, str(e2e_workspace.tmp_path)):
            assert forbidden not in (prom.text + js.text)
