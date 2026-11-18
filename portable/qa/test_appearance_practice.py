"""Local browser preferences and a practice session that never changes interview data."""

from urllib.parse import urlsplit

import httpx
from playwright.sync_api import expect


def test_theme_keyboard_reload_and_cross_tab_sync(workspace_url, browser_page):
    page = browser_page
    page.emulate_media(color_scheme="dark", reduced_motion="reduce")
    page.goto(workspace_url + "/account/")
    system = page.get_by_role("radio", name="System")
    expect(system).to_be_checked()
    system.focus()
    page.keyboard.press("ArrowRight")
    expect(page.get_by_role("radio", name="Light")).to_be_checked()
    page.reload()
    expect(page.get_by_role("radio", name="Light")).to_be_checked()
    other = page.context.new_page()
    try:
        other.goto(workspace_url + "/account/")
        expect(other.get_by_role("radio", name="Light")).to_be_checked()
        other.get_by_role("radio", name="Dark").check()
        expect(page.get_by_role("radio", name="Dark")).to_be_checked()
        colors = page.evaluate("""() => {
            function sample(token) {
                const node=document.createElement('span');
                node.style.color='var('+token+')'; document.body.append(node);
                const color=getComputedStyle(node).color.match(/[0-9.]+/g).slice(0,3).map(Number);
                node.remove(); return color;
            }
            return ['--ink','--muted','--surface','--green-ink','--selected-bg'].map(sample);
        }""")

        def luminance(color):
            values = [value / 255 for value in color]
            return sum(
                w * (v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4)
                for w, v in zip((0.2126, 0.7152, 0.0722), values)
            )

        for foreground, background in [
            (colors[0], colors[2]),
            (colors[1], colors[2]),
            (colors[3], colors[4]),
        ]:
            bright, dark = sorted([luminance(foreground), luminance(background)], reverse=True)
            assert (bright + 0.05) / (dark + 0.05) >= 4.5
        page.get_by_role("radio", name="System").check()
        expect(other.get_by_role("radio", name="System")).to_be_checked()
    finally:
        other.close()


def test_fictional_session_uses_real_preview_without_saving(workspace_url, browser_page):
    page = browser_page
    mutations = []
    page.on(
        "request",
        lambda r: mutations.append(urlsplit(r.url).path) if r.method not in ("GET", "HEAD") else None,
    )
    page.goto(workspace_url + "/sample/")
    expect(page.get_by_text("Fictional session", exact=False).first).to_be_visible()
    expect(page.get_by_text("Passage match", exact=True)).to_be_visible()
    page.get_by_label("Practice outcome").select_option("explained")
    page.get_by_label("Practice note").fill("Temporary sample note.")
    page.get_by_role("navigation", name="Interview questions").get_by_role(
        "button", name="02", exact=False
    ).click()
    expect(page.get_by_text("No passage match", exact=True)).to_be_visible()
    page.get_by_role("navigation", name="Interview questions").get_by_role(
        "button", name="03", exact=False
    ).click()
    expect(page.get_by_text("Limited evidence", exact=True)).to_be_visible()
    page.get_by_role("navigation", name="Interview questions").get_by_role(
        "button", name="01", exact=False
    ).click()
    expect(page.get_by_label("Practice note")).to_have_value("Temporary sample note.")
    page.get_by_label("Permitted material").check()
    expect(page.get_by_text("Limited evidence", exact=True)).to_be_visible()
    page.get_by_role("button", name="Reset sample").click()
    expect(page.get_by_text("Passage match", exact=True)).to_be_visible()
    expect(page.get_by_label("Practice note")).to_have_value("")
    assert mutations and set(mutations) == {"/api/preview"}
    assert httpx.get(workspace_url + "/api/sessions").json() == []
