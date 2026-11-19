"""Generate desktop/mobile light/dark screenshot pack and rubric telemetry manifest."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import tempfile

from playwright.sync_api import sync_playwright

QA_ROOT = Path(__file__).resolve().parent
if str(QA_ROOT) not in sys.path:
    sys.path.insert(0, str(QA_ROOT))

from e2e_suite.harness import (  # noqa: E402
    ConsoleErrorCollector,
    DESKTOP_VIEWPORT,
    IsolatedWorkspace,
    MOBILE_VIEWPORT,
    load_parent_qa_conftest,
    signup_user,
)

try:
    from qa.visual_rubric import ADMIN_TABS, AUDIT_JS, summarize_records
except ImportError:
    from visual_rubric import ADMIN_TABS, AUDIT_JS, summarize_records

ADMIN_EMAIL = "admin-visual@example.test"
MEMBER_EMAIL = "member-visual@example.test"
BOOTSTRAP_SECRET = "visual-bootstrap-secret-1234"
DEFAULT_OUT = QA_ROOT / ".screenshots"


def _seed_workspace(ws: IsolatedWorkspace) -> str:
    with ws.client() as c:
        signup_user(c, email=ADMIN_EMAIL, admin_secret=BOOTSTRAP_SECRET)
        c.post("/api/roles", json={
            "name": "Distributed Systems Engineer",
            "description": "Evaluates consistency, retries, and observability under failure.",
            "policy": "Architecture notes allowed.",
            "questions": ["How do you bound tail latency during failover?"],
        }).raise_for_status()
        phrase = "Isolate noisy shards behind circuit breakers before shedding background traffic."
        sids = []
        for candidate in ("Jordan Alvarez", "Morgan Patel"):
            sid = c.post("/api/sessions", json={
                "candidate": candidate, "role": "Distributed Systems Engineer",
                "policy": "Architecture notes allowed.", "consent": True,
            }).json()["id"]
            c.post(f"/api/sessions/{sid}/answers", json={
                "question": "How do you bound tail latency during failover?",
                "answer": phrase, "references": [{"label": "Runbook", "text": phrase}],
            }).raise_for_status()
            sids.append(sid)
        c.post("/api/admin/models", json={
            "slug": "visual-openai-ref", "display_name": "Primary GPT-4o", "provider": "openai",
            "capability": "reference", "model_id": "gpt-4o", "apiKey": "sk-visual-fixture-key-1234",
            "parameters": {"temperature": 0.2, "max_tokens": 1024, "timeout_s": 2.0, "fallback_priority": 10},
            "enabled": True, "is_default": True,
        }).raise_for_status()
        err_model = c.post("/api/admin/models", json={
            "slug": "visual-anthropic-judge", "display_name": "Audit Judge Claude", "provider": "anthropic",
            "capability": "judge", "model_id": "claude-sonnet-4-6", "apiKey": "sk-ant-visual-fixture-5678",
            "parameters": {"temperature": 0.0, "max_tokens": 512, "timeout_s": 2.0, "fallback_priority": 20},
            "enabled": True, "is_default": False,
        }).json()["model"]
        c.post(f"/api/admin/models/{err_model['id']}/probe")
    with ws.client() as member:
        signup_user(member, email=MEMBER_EMAIL)
    return sids[0]


class _MiniMonkeyPatch:
    def setenv(self, k, v):
        os.environ[k] = v

    def delenv(self, k, raising=False):
        os.environ.pop(k, None)

    def syspath_prepend(self, p):
        if p not in sys.path:
            sys.path.insert(0, p)

    def chdir(self, p):
        os.chdir(p)


def _capture_audit(page, collector, out_dir: Path, slug: str, url_path: str, auth_state: str, theme: str, vp_label: str) -> dict:
    page.evaluate("() => document.fonts ? document.fonts.ready : Promise.resolve()")
    metrics = page.evaluate(AUDIT_JS)
    fname = f"{slug}__{auth_state}__{theme}__{vp_label}.png"
    page.screenshot(path=str(out_dir / fname), full_page=True)
    return {
        "slug": slug, "route": url_path, "auth_state": auth_state, "theme": theme,
        "viewport": vp_label, "screenshot": fname,
        "console_errors": list(collector.console_errors),
        "page_errors": list(collector.page_errors),
        "server_errors": list(collector.server_errors),
        **metrics,
    }


def _capture_workspace_search(page, collector, out_dir: Path, auth_state: str, theme: str, vp_label: str) -> dict | None:
    search_btn = page.get_by_role("button", name="Search workspace", exact=True)
    if search_btn.count() == 0:
        return None
    collector.reset()
    search_btn.first.click()
    dialog = page.locator("dialog.search-dialog[open]")
    dialog.wait_for(state="visible")
    rec = _capture_audit(page, collector, out_dir, "workspace_search_palette", "/", auth_state, theme, vp_label)
    page.keyboard.press("Escape")
    dialog.wait_for(state="hidden")
    return rec


def _capture_admin_tabs(page, collector, out_dir: Path, auth_state: str, theme: str, vp_label: str) -> list[dict]:
    extra = []
    for tab_label in ADMIN_TABS[1:]:
        tab_loc = page.get_by_role("tab", name=tab_label, exact=True)
        if tab_loc.count() == 0:
            continue
        collector.reset()
        panel_id = tab_loc.first.get_attribute("aria-controls")
        tab_loc.first.click()
        if panel_id:
            page.locator(f"#{panel_id}").wait_for(state="visible")
        page.wait_for_load_state("networkidle")
        tab_slug = "admin_tab_" + re.sub(r"[^a-z0-9]+", "_", tab_label.lower()).strip("_")
        extra.append(_capture_audit(page, collector, out_dir, tab_slug, "/admin/", auth_state, theme, vp_label))
    return extra


def generate_pack(out_dir: Path) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ic-m3-pack-") as tmp:
        ws = IsolatedWorkspace(Path(tmp), _MiniMonkeyPatch(), (None, None, 0))
        ws.prepare_env()
        ws.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
        ws.start()
        try:
            sid = _seed_workspace(ws)
            compare_ready = (QA_ROOT.parent / "web" / "out" / "interviews" / "compare" / "index.html").is_file()
            routes = [
                ("overview_populated", "/", "signed_in_admin"),
                ("interviews", "/interviews/", "signed_in_admin"),
                ("interviews_new", "/interviews/new/", "signed_in_admin"),
                ("interviews_review", f"/interviews/review/?id={sid}", "signed_in_admin"),
                ("interviews_brief", f"/interviews/brief/?id={sid}", "signed_in_admin"),
                ("interviews_compare", "/interviews/compare/", "signed_in_admin"),
                ("roles", "/roles/", "signed_in_admin"),
                ("connections", "/connections/", "signed_in_admin"),
                ("data", "/data/", "signed_in_admin"),
                ("account_unauth", "/account/", "unauth"),
                ("account_admin", "/account/", "signed_in_admin"),
                ("sample", "/sample/", "signed_in_admin"),
                ("trash", "/trash/", "signed_in_admin"),
                ("admin_unauth", "/admin/", "unauth"),
                ("admin_panel", "/admin/", "signed_in_admin"),
            ]
            parent = load_parent_qa_conftest()
            records = []
            with sync_playwright() as pw:
                browser = parent.launch_chromium(pw)
                try:
                    for theme in ("dark", "light"):
                        for vp_label, vp, is_mob in (("1440x900", DESKTOP_VIEWPORT, False), ("390x844", MOBILE_VIEWPORT, True)):
                            for auth_state in ("unauth", "signed_in_admin"):
                                ctx = browser.new_context(
                                    viewport=vp, reduced_motion="reduce", color_scheme=theme, is_mobile=is_mob, has_touch=is_mob,
                                )
                                page = ctx.new_page()
                                page.set_default_timeout(10_000)
                                page.add_init_script(
                                    f"localStorage.setItem('interviewcheck.appearance', {json.dumps(theme)});"
                                    "window.__icCspViolations = [];"
                                    "window.addEventListener('securitypolicyviolation', e => window.__icCspViolations.push(e.violatedDirective));"
                                )
                                collector = ConsoleErrorCollector()
                                collector.attach(page)
                                if auth_state == "signed_in_admin":
                                    page.goto(ws.base_url + "/account/", wait_until="domcontentloaded")
                                    page.get_by_label("Operator email").fill(ADMIN_EMAIL)
                                    page.get_by_label("Password", exact=True).fill("Synthetic-E2E-Pass-9876")
                                    page.get_by_role("button", name="Sign in", exact=True).click()
                                    page.get_by_text(ADMIN_EMAIL).wait_for(state="visible")
                                    collector.reset()
                                for slug, url_path, wanted_auth in routes:
                                    if wanted_auth != auth_state or (url_path == "/interviews/compare/" and not compare_ready):
                                        continue
                                    collector.reset()
                                    resp = page.goto(ws.base_url + url_path, wait_until="networkidle")
                                    if url_path == "/interviews/compare/" and resp and resp.status == 404:
                                        collector.reset()
                                        continue
                                    records.append(_capture_audit(page, collector, out_dir, slug, url_path, auth_state, theme, vp_label))
                                    if slug == "overview_populated" and auth_state == "signed_in_admin":
                                        search_rec = _capture_workspace_search(page, collector, out_dir, auth_state, theme, vp_label)
                                        if search_rec:
                                            records.append(search_rec)
                                    if slug == "admin_panel" and auth_state == "signed_in_admin":
                                        records.extend(_capture_admin_tabs(page, collector, out_dir, auth_state, theme, vp_label))
                                ctx.close()
                finally:
                    browser.close()
        finally:
            ws.stop()

    summary = summarize_records(records)
    manifest_path = out_dir / "manifest.json"
    manifest_path.write_text(json.dumps({**summary, "records": records}, indent=2), encoding="utf-8")
    return manifest_path


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()
    path = generate_pack(args.out_dir)
    data = json.loads(path.read_text(encoding="utf-8"))
    print(json.dumps({k: v for k, v in data.items() if k != "records"}, indent=2))
    raise SystemExit(0 if data.get("passed") else 1)
