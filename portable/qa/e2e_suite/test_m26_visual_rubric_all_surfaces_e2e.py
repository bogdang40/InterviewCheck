"""M26 full-surface visual rubric Playwright E2E gate across routes, admin tabs, themes, and viewports."""
import json
from pathlib import Path
import re
import sys

from playwright.sync_api import expect
import pytest

PORTABLE_ROOT = Path(__file__).resolve().parents[2]
if str(PORTABLE_ROOT) not in sys.path:
    sys.path.insert(0, str(PORTABLE_ROOT))

from api import model_probe, ssrf_guard  # noqa: E402
from e2e_suite.harness import (  # noqa: E402
    ConsoleErrorCollector,
    DESKTOP_VIEWPORT,
    MOBILE_VIEWPORT,
    login_user,
    signup_user,
)
from qa.visual_rubric import (  # noqa: E402
    ADMIN_TABS,
    AUDIT_JS,
    record_passes_rubric,
    summarize_records,
)

ADMIN_EMAIL = "admin-m26-visual@example.test"
BOOTSTRAP_SECRET = "m26-visual-bootstrap-secret-1234"
ADMIN_PASS = "Synthetic-M26-Admin-Pass-1"
VIEWPORTS = (
    ("1440x900", DESKTOP_VIEWPORT, False),
    ("390x844", MOBILE_VIEWPORT, True),
)
THEMES = ("dark", "light")


def _seed_workspace(e2e_workspace, monkeypatch) -> tuple[str, str]:
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])

    async def fake_probe(row, *, api_key: str):
        if row["slug"] == "m26-openai-ref":
            return model_probe.ProbeOutcome(
                ok=True, status="connected", http_status=200, latency_ms=38,
                last_error=None, checked_at=model_probe._now_iso(),
            )
        return model_probe.ProbeOutcome(
            ok=False, status="error", http_status=401, latency_ms=91,
            last_error="Provider rejected API key", checked_at=model_probe._now_iso(),
        )

    monkeypatch.setattr(model_probe, "probe_model", fake_probe)
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()

    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
        c.cookies.clear()
        login_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS)

        role_res = c.post("/api/roles", json={
            "name": "Distributed Systems Engineer",
            "description": "Evaluates consistency, retries, and observability under failure.",
            "policy": "Architecture notes allowed.",
            "questions": ["How do you bound tail latency during failover?"],
            "rubric": [{
                "criterion": "Fault isolation and tail latency bounds",
                "weight": 5,
                "expected_signals": ["Circuit breakers", "Load shedding"],
                "red_flags": ["Unbounded retries"],
            }],
        })
        role_res.raise_for_status()
        role = role_res.json()

        phrase = "Isolate noisy shards behind circuit breakers before shedding background traffic."
        sids: list[str] = []
        for candidate, note in (
            ("Jordan Alvarez", "Explained bounded retries and circuit breaker thresholds."),
            ("Morgan Patel", "Covered shard isolation and graceful degradation."),
        ):
            s_res = c.post("/api/sessions", json={
                "candidate": candidate,
                "role": role["name"],
                "role_id": role["id"],
                "role_version": role["version"],
                "policy": role["policy"],
                "consent": True,
            })
            s_res.raise_for_status()
            sid = s_res.json()["id"]
            a_res = c.post(f"/api/sessions/{sid}/answers", json={
                "question": "How do you bound tail latency during failover?",
                "answer": phrase,
                "references": [{"label": "Runbook", "text": phrase}],
                "planned_slot": 1,
            })
            a_res.raise_for_status()
            aid = a_res.json()["id"]
            c.patch(f"/api/sessions/{sid}/answers/{aid}", json={
                "disposition": "explained",
                "note": note,
            }).raise_for_status()
            c.post(f"/api/sessions/{sid}/finish").raise_for_status()
            sids.append(sid)

        ok_res = c.post("/api/admin/models", json={
            "slug": "m26-openai-ref",
            "display_name": "Primary GPT-4o",
            "provider": "openai",
            "capability": "reference",
            "model_id": "gpt-4o",
            "apiKey": "sk-m26-visual-fixture-key-1111",
            "parameters": {"temperature": 0.2, "max_tokens": 1024, "timeout_s": 2.0, "fallback_priority": 10},
            "enabled": True,
            "is_default": True,
        })
        ok_res.raise_for_status()
        ok_model = ok_res.json()["model"]
        assert c.post(f"/api/admin/models/{ok_model['id']}/probe").status_code == 200

        err_res = c.post("/api/admin/models", json={
            "slug": "m26-anthropic-judge",
            "display_name": "Audit Judge Claude",
            "provider": "anthropic",
            "capability": "judge",
            "model_id": "claude-sonnet-4-6",
            "apiKey": "sk-ant-m26-visual-fixture-2222",
            "parameters": {"temperature": 0.0, "max_tokens": 512, "timeout_s": 2.0, "fallback_priority": 20},
            "enabled": True,
            "is_default": False,
        })
        err_res.raise_for_status()
        err_model = err_res.json()["model"]
        assert c.post(f"/api/admin/models/{err_model['id']}/probe").status_code == 502

        c.post("/api/admin/alerts", json={
            "name": "Judge probe failure",
            "trigger_type": "probe_failed",
            "threshold_value": 1,
            "webhook_url": "https://hooks.example.test/m26-alerts",
            "enabled": True,
        }).raise_for_status()

        c.put("/api/admin/prompts/judge_rubric", json={
            "system_prompt": "Evaluate interview answers against rubric criteria and verified references.",
            "output_rule": "Return strictly JSON with likelihood, confidence, evidence, follow_up_questions.",
            "change_note": "M26 visual rubric seed",
            "expected_version": 1,
        }).raise_for_status()

    return sids[0], sids[1]


def _sign_in_and_set_theme(page, collector: ConsoleErrorCollector, base_url: str, theme: str) -> None:
    page.goto(base_url + "/account/", wait_until="domcontentloaded")
    page.get_by_label("Operator email").fill(ADMIN_EMAIL)
    page.get_by_label("Password", exact=True).fill(ADMIN_PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(ADMIN_EMAIL)).to_be_visible()
    expect(page.get_by_role("button", name="Sign out", exact=True)).to_be_visible()

    light_radio = page.get_by_role("radio", name="Light")
    dark_radio = page.get_by_role("radio", name="Dark")
    expect(light_radio).to_be_visible()
    if theme == "dark":
        light_radio.check()
        expect(page.locator("html")).to_have_attribute("data-theme", "light")
        dark_radio.check()
    else:
        light_radio.check()
    expect(page.locator("html")).to_have_attribute("data-theme", theme)
    assert page.evaluate("() => localStorage.getItem('interviewcheck.appearance')") == theme
    collector.reset()


def _audit_surface(page, collector: ConsoleErrorCollector, out_dir: Path, slug: str, route: str, theme: str, vp_label: str) -> dict:
    page.evaluate("() => document.fonts ? document.fonts.ready : Promise.resolve()")
    metrics = page.evaluate(AUDIT_JS)
    fname = f"{slug}__{theme}__{vp_label}.png"
    page.screenshot(path=str(out_dir / fname), full_page=True)
    return {
        "slug": slug,
        "route": route,
        "theme": theme,
        "viewport": vp_label,
        "screenshot": fname,
        "console_errors": list(collector.console_errors),
        "page_errors": list(collector.page_errors),
        "server_errors": list(collector.server_errors),
        **metrics,
    }


def _audit_workspace_search(page, collector: ConsoleErrorCollector, out_dir: Path, theme: str, vp_label: str) -> dict:
    trigger = page.get_by_role("button", name="Search workspace", exact=True)
    expect(trigger).to_be_visible()
    collector.reset()
    trigger.click()
    dialog = page.locator("dialog.search-dialog[open]")
    expect(dialog).to_be_visible()
    combobox = dialog.get_by_role("combobox", name="Search workspace records")
    expect(combobox).to_be_focused()
    rec = _audit_surface(page, collector, out_dir, "workspace_search_palette", "/", theme, vp_label)
    page.keyboard.press("Escape")
    expect(dialog).to_be_hidden()
    expect(trigger).to_be_focused()
    return rec


def _audit_admin_tabs(page, collector: ConsoleErrorCollector, out_dir: Path, theme: str, vp_label: str) -> list[dict]:
    tablist = page.get_by_role("tablist", name="Admin sections")
    expect(tablist).to_be_visible()
    tab_records: list[dict] = []
    for tab_label in ADMIN_TABS:
        tab = tablist.get_by_role("tab", name=tab_label, exact=True)
        expect(tab).to_be_visible()
        collector.reset()
        tab.click()
        expect(tab).to_have_attribute("aria-selected", "true")
        panel_id = tab.get_attribute("aria-controls")
        assert panel_id, f"Missing aria-controls for admin tab {tab_label}"
        expect(page.locator(f"#{panel_id}")).to_be_visible()
        page.wait_for_load_state("networkidle")
        bounds = tab.evaluate(
            """(el) => {
              const strip = el.closest('.admin-tabs');
              if (!strip) return null;
              const s = strip.getBoundingClientRect(), t = el.getBoundingClientRect();
              return { sLeft: s.left, sRight: s.right, tLeft: t.left, tRight: t.right };
            }"""
        )
        assert bounds is not None
        assert bounds["tLeft"] >= bounds["sLeft"] - 1 and bounds["tRight"] <= bounds["sRight"] + 1, (
            f"{theme} {vp_label} tab {tab_label} outside .admin-tabs bounds: {bounds}"
        )
        tab_slug = "admin_tab_" + re.sub(r"[^a-z0-9]+", "_", tab_label.lower()).strip("_")
        tab_records.append(_audit_surface(page, collector, out_dir, tab_slug, f"/admin/#{tab_label}", theme, vp_label))
    return tab_records


@pytest.mark.tier3
def test_m26_visual_rubric_all_surfaces(e2e_workspace, e2e_browser, monkeypatch):
    sid1, sid2 = _seed_workspace(e2e_workspace, monkeypatch)
    out_dir = e2e_workspace.screenshot_dir
    routes = (
        ("overview", "/"),
        ("interviews", "/interviews/"),
        ("interviews_new", "/interviews/new/"),
        ("interviews_review", f"/interviews/review/?id={sid1}"),
        ("interviews_brief", f"/interviews/brief/?id={sid1}"),
        ("interviews_compare", f"/interviews/compare/?ids={sid1},{sid2}"),
        ("roles", "/roles/"),
        ("connections", "/connections/"),
        ("data", "/data/"),
        ("account", "/account/"),
        ("sample", "/sample/"),
        ("trash", "/trash/"),
        ("admin", "/admin/"),
    )

    records: list[dict] = []
    for vp_label, vp, is_mob in VIEWPORTS:
        for theme in THEMES:
            ctx = e2e_browser.new_context(
                viewport=vp, reduced_motion="reduce", color_scheme=theme, is_mobile=is_mob, has_touch=is_mob,
            )
            page = ctx.new_page()
            page.set_default_timeout(12_000)
            page.set_default_navigation_timeout(30_000)
            page.add_init_script(
                "window.__icCspViolations = [];"
                "window.addEventListener('securitypolicyviolation', e => window.__icCspViolations.push(e.violatedDirective));"
            )
            collector = ConsoleErrorCollector()
            collector.attach(page)
            try:
                _sign_in_and_set_theme(page, collector, e2e_workspace.base_url, theme)
                for slug, url_path in routes:
                    collector.reset()
                    page.goto(e2e_workspace.base_url + url_path, wait_until="networkidle")
                    expect(page.locator("main#main-content")).to_be_visible()
                    if slug == "interviews_compare":
                        expect(page.get_by_role("heading", name="Candidate comparison")).to_be_visible()
                        expect(page.get_by_role("heading", name="Shared role rubric criteria")).to_be_visible()
                    if slug == "admin":
                        expect(page.get_by_role("tablist", name="Admin sections")).to_be_visible()
                        expect(page.get_by_text("Primary GPT-4o")).to_be_visible()
                    records.append(_audit_surface(page, collector, out_dir, slug, url_path, theme, vp_label))
                    if slug == "overview":
                        records.append(_audit_workspace_search(page, collector, out_dir, theme, vp_label))
                    if slug == "admin":
                        records.extend(_audit_admin_tabs(page, collector, out_dir, theme, vp_label))
            finally:
                ctx.close()

    summary = summarize_records(records)
    manifest_path = out_dir / "m26_visual_manifest.json"
    manifest_path.write_text(json.dumps({**summary, "records": records}, indent=2), encoding="utf-8")

    failures = [
        f"{r['slug']} [{r['theme']} {r['viewport']}]: {', '.join(reasons)}"
        for r in records
        if (reasons := record_passes_rubric(r))
    ]
    assert summary["passed"] is True and not failures, (
        f"Visual rubric failures (manifest={manifest_path}):\n" + "\n".join(failures)
    )
