"""Generate F13 desktop/mobile light/dark screenshot pack and rubric telemetry manifest."""
import argparse
import json
from pathlib import Path
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

ADMIN_EMAIL = "admin-visual@example.test"
MEMBER_EMAIL = "member-visual@example.test"
BOOTSTRAP_SECRET = "visual-bootstrap-secret-1234"
DEFAULT_OUT = Path("/Users/abekhadra/Desktop/STARKTECH/.agents/teamwork/teamwork_worker_m3_1/screenshots")

AUDIT_JS = """() => {
  const doc = document.documentElement;
  const scrollWidth = doc.scrollWidth;
  const clientWidth = doc.clientWidth;
  const clipped = [];
  const selectors = "button, a, input, select, textarea, summary, h1, h2";
  for (const el of document.querySelectorAll(selectors)) {
    const cs = getComputedStyle(el);
    if (cs.display === "none" || cs.visibility === "hidden" || el.closest(".sr-only")) continue;
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    if (r.right > window.innerWidth + 1 || r.left < -1) {
      clipped.push({ tag: el.tagName, text: (el.textContent || "").trim().slice(0, 40), left: r.left, right: r.right });
    }
  }
  const overlaps = [];
  const groups = [".studio-actions", ".record-actions", ".role-row", ".sidebar nav", ".admin-model-actions"];
  for (const g of groups) {
    for (const container of document.querySelectorAll(g)) {
      const items = [...container.querySelectorAll(":scope > a, :scope > button")].filter(el => {
        const cs = getComputedStyle(el);
        const r = el.getBoundingClientRect();
        return cs.display !== "none" && cs.visibility !== "hidden" && r.width > 0 && r.height > 0;
      });
      for (let i = 0; i < items.length; i++) {
        for (let j = i + 1; j < items.length; j++) {
          const a = items[i].getBoundingClientRect();
          const b = items[j].getBoundingClientRect();
          const ix = Math.max(0, Math.min(a.right, b.right) - Math.max(a.left, b.left));
          const iy = Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top));
          if (ix > 1 && iy > 1) overlaps.push({ group: g, ix, iy });
        }
      }
    }
  }
  const canvas = document.createElement("canvas");
  canvas.width = 1;
  canvas.height = 1;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  function parseColor(cssColor) {
    ctx.clearRect(0, 0, 1, 1);
    ctx.fillStyle = "rgba(0, 0, 0, 0)";
    ctx.fillStyle = cssColor;
    ctx.fillRect(0, 0, 1, 1);
    const d = ctx.getImageData(0, 0, 1, 1).data;
    return [d[0], d[1], d[2], d[3]];
  }
  function blendOver(cssColor, baseRgb) {
    ctx.clearRect(0, 0, 1, 1);
    ctx.fillStyle = "rgb(" + baseRgb[0] + "," + baseRgb[1] + "," + baseRgb[2] + ")";
    ctx.fillRect(0, 0, 1, 1);
    ctx.fillStyle = cssColor;
    ctx.fillRect(0, 0, 1, 1);
    const d = ctx.getImageData(0, 0, 1, 1).data;
    return [d[0], d[1], d[2]];
  }
  function rgb(token) {
    const n = document.createElement("span");
    n.style.color = "var(" + token + ")";
    document.body.append(n);
    const c = parseColor(getComputedStyle(n).color);
    n.remove();
    return [c[0], c[1], c[2]];
  }
  function lum(c) {
    return c.reduce((acc, v, idx) => {
      const s = v / 255;
      const lin = s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
      return acc + [0.2126, 0.7152, 0.0722][idx] * lin;
    }, 0);
  }
  function contrastPair(c1, c2) {
    const [a, b] = [lum(c1), lum(c2)].sort((x, y) => y - x);
    return Number(((a + 0.05) / (b + 0.05)).toFixed(2));
  }
  function ratio(fg, bg) {
    return contrastPair(rgb(fg), rgb(bg));
  }
  const surfaceRgb = rgb("--surface");
  function nearestOpaqueBg(el) {
    const layers = [];
    let cur = el.parentElement;
    while (cur) {
      const bg = getComputedStyle(cur).backgroundColor;
      const rgba = parseColor(bg);
      if (rgba[3] > 0) {
        layers.push(bg);
        if (rgba[3] >= 254) break;
      }
      cur = cur.parentElement;
    }
    let acc = surfaceRgb;
    for (let i = layers.length - 1; i >= 0; i--) {
      acc = blendOver(layers[i], acc);
    }
    return acc;
  }
  const controlSelector = [
    "select",
    'input:not([type="checkbox"]):not([type="radio"]):not([type="hidden"])',
    "textarea",
    ".search",
    ".archive-search > span",
    '[data-slot="button"][data-variant="outline"]',
    ".header-tools .search-launch",
  ].join(", ");
  const controlRatios = [];
  const controlFailures = [];
  for (const el of document.querySelectorAll(controlSelector)) {
    const cs = getComputedStyle(el);
    if (cs.display === "none" || cs.visibility === "hidden" || el.closest(".sr-only")) continue;
    if (el.matches(":disabled")) continue;
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    if (parseFloat(cs.borderTopWidth) <= 0 || cs.borderTopStyle === "none") continue;
    const borderRgba = parseColor(cs.borderTopColor);
    if (borderRgba[3] === 0) continue;
    const bg = nearestOpaqueBg(el);
    const borderRgb = borderRgba[3] >= 254
      ? [borderRgba[0], borderRgba[1], borderRgba[2]]
      : blendOver(cs.borderTopColor, bg);
    const borderRatio = contrastPair(borderRgb, bg);
    controlRatios.push(borderRatio);
    if (borderRatio < 3.0) {
      controlFailures.push({
        tag: el.tagName,
        className: typeof el.className === "string" ? el.className.slice(0, 60) : "",
        text: (el.getAttribute("aria-label") || el.textContent || "").trim().slice(0, 40),
        ratio: borderRatio,
      });
    }
  }
  return {
    scrollWidth,
    clientWidth,
    overflow: scrollWidth > clientWidth,
    clipped_count: clipped.length,
    clipped,
    overlap_count: overlaps.length,
    overlaps,
    contrast: {
      ink_on_surface: ratio("--ink", "--surface"),
      muted_on_surface: ratio("--muted", "--surface"),
      secondary_on_surface: ratio("--secondary-ink", "--surface"),
      green_ink_on_selected: ratio("--green-ink", "--selected-bg"),
      error_on_error_bg: ratio("--error-text", "--error-bg"),
      attention_on_warning_bg: ratio("--attention", "--warning-bg"),
      input_border_on_surface: ratio("--color-input", "--surface"),
      control_border_min: controlRatios.length ? Math.min(...controlRatios) : null,
      control_border_failures: controlFailures,
    },
    csp_violations: window.__icCspViolations || [],
    data_theme: doc.dataset.theme || "",
    color_scheme: getComputedStyle(doc).colorScheme,
  };
}"""


def _seed_workspace(ws: IsolatedWorkspace) -> str:
    with ws.client() as c:
        signup_user(c, email=ADMIN_EMAIL, admin_secret=BOOTSTRAP_SECRET)
        c.post("/api/roles", json={
            "name": "Distributed Systems Engineer",
            "description": "Evaluates consistency, retries, and observability under failure.",
            "policy": "Architecture notes allowed.",
            "questions": ["How do you bound tail latency during failover?"],
        }).raise_for_status()
        s1 = c.post("/api/sessions", json={
            "candidate": "Jordan Alvarez",
            "role": "Distributed Systems Engineer",
            "policy": "Architecture notes allowed.",
            "consent": True,
        }).json()["id"]
        phrase = "Isolate noisy shards behind circuit breakers before shedding background traffic."
        c.post(f"/api/sessions/{s1}/answers", json={
            "question": "How do you bound tail latency during failover?",
            "answer": phrase,
            "references": [{"label": "Runbook", "text": phrase}],
        }).raise_for_status()
        c.post("/api/admin/models", json={
            "slug": "visual-openai-ref",
            "display_name": "Primary GPT-4o",
            "provider": "openai",
            "capability": "reference",
            "model_id": "gpt-4o",
            "apiKey": "sk-visual-fixture-key-1234",
            "parameters": {"temperature": 0.2, "max_tokens": 1024, "timeout_s": 2.0, "fallback_priority": 10},
            "enabled": True,
            "is_default": True,
        }).raise_for_status()
        err_model = c.post("/api/admin/models", json={
            "slug": "visual-anthropic-judge",
            "display_name": "Audit Judge Claude",
            "provider": "anthropic",
            "capability": "judge",
            "model_id": "claude-sonnet-4-6",
            "apiKey": "sk-ant-visual-fixture-5678",
            "parameters": {"temperature": 0.0, "max_tokens": 512, "timeout_s": 2.0, "fallback_priority": 20},
            "enabled": True,
            "is_default": False,
        }).json()["model"]
        c.post(f"/api/admin/models/{err_model['id']}/probe")
    with ws.client() as member:
        signup_user(member, email=MEMBER_EMAIL)
    return s1


class _MiniMonkeyPatch:
    def __init__(self):
        import os
        self._os = os

    def setenv(self, k, v):
        self._os.environ[k] = v

    def delenv(self, k, raising=False):
        self._os.environ.pop(k, None)

    def syspath_prepend(self, p):
        if p not in sys.path:
            sys.path.insert(0, p)

    def chdir(self, p):
        self._os.chdir(p)


def generate_pack(out_dir: Path) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ic-m3-pack-") as tmp:
        ws = IsolatedWorkspace(Path(tmp), _MiniMonkeyPatch(), (None, None, 0))
        ws.prepare_env()
        ws.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
        ws.start()
        try:
            sid = _seed_workspace(ws)
            routes = [
                ("overview_populated", "/", "signed_in_admin"),
                ("interviews", "/interviews/", "signed_in_admin"),
                ("interviews_new", "/interviews/new/", "signed_in_admin"),
                ("interviews_review", f"/interviews/review/?id={sid}", "signed_in_admin"),
                ("interviews_brief", f"/interviews/brief/?id={sid}", "signed_in_admin"),
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
                                    viewport=vp, reduced_motion="reduce",
                                    color_scheme=theme, is_mobile=is_mob, has_touch=is_mob,
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
                                    if wanted_auth != auth_state:
                                        continue
                                    collector.reset()
                                    page.goto(ws.base_url + url_path, wait_until="networkidle")
                                    page.evaluate("() => document.fonts ? document.fonts.ready : Promise.resolve()")
                                    metrics = page.evaluate(AUDIT_JS)
                                    fname = f"{slug}__{auth_state}__{theme}__{vp_label}.png"
                                    page.screenshot(path=str(out_dir / fname), full_page=True)
                                    records.append({
                                        "slug": slug,
                                        "route": url_path,
                                        "auth_state": auth_state,
                                        "theme": theme,
                                        "viewport": vp_label,
                                        "screenshot": fname,
                                        "console_errors": list(collector.console_errors),
                                        "page_errors": list(collector.page_errors),
                                        "server_errors": list(collector.server_errors),
                                        **metrics,
                                    })
                                ctx.close()
                finally:
                    browser.close()
        finally:
            ws.stop()

    manifest_path = out_dir / "manifest.json"
    summary = {
        "total_screenshots": len(records),
        "overflow_failures": sum(1 for r in records if r["overflow"]),
        "clipped_failures": sum(1 for r in records if r["clipped_count"] > 0),
        "overlap_failures": sum(1 for r in records if r["overlap_count"] > 0),
        "console_error_failures": sum(1 for r in records if r["console_errors"] or r["page_errors"] or r["server_errors"]),
        "csp_failures": sum(1 for r in records if r["csp_violations"]),
        "control_border_min": min(
            (r["contrast"]["control_border_min"] for r in records if r["contrast"]["control_border_min"] is not None),
            default=None,
        ),
        "contrast_failures": sum(
            1 for r in records
            if min(
                r["contrast"]["ink_on_surface"],
                r["contrast"]["muted_on_surface"],
                r["contrast"]["secondary_on_surface"],
                r["contrast"]["green_ink_on_selected"],
                r["contrast"]["error_on_error_bg"],
                r["contrast"]["attention_on_warning_bg"],
            ) < 4.5
            or r["contrast"]["input_border_on_surface"] < 3.0
            or bool(r["contrast"].get("control_border_failures"))
        ),
        "records": records,
    }
    manifest_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return manifest_path


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()
    path = generate_pack(args.out_dir)
    data = json.loads(path.read_text(encoding="utf-8"))
    print(json.dumps({k: v for k, v in data.items() if k != "records"}, indent=2))
    failures = sum(
        data[k] for k in (
            "overflow_failures", "clipped_failures", "overlap_failures",
            "console_error_failures", "csp_failures", "contrast_failures",
        )
    )
    raise SystemExit(1 if failures else 0)
