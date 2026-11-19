"""Playwright M9 scale performance E2E tests on a 5,000-session, 30,000-answer, 500-user, 5,000-audit workspace."""
from __future__ import annotations

import json
from uuid import UUID, uuid4

from playwright.sync_api import TimeoutError as PlaywrightTimeoutError, expect
import pytest

from api import account_db, store
from e2e_suite.harness import (
    ConsoleErrorCollector,
    DESKTOP_VIEWPORT,
    IsolatedWorkspace,
    MOBILE_VIEWPORT,
    assert_no_horizontal_overflow,
    signup_user,
)

ADMIN_EMAIL = "scale-e2e-admin@example.test"
ADMIN_PASS = "Synthetic-M9-Scale-Pass-1"
BOOTSTRAP_SECRET = "m9-scale-bootstrap-secret"
SESSIONS = 5000
ANSWERS_PER_SESSION = 6
USERS = 500
AUDIT_ROWS = 5000
AUDIT_ACTIONS = (
    "admin.model.probe",
    "admin.model.create",
    "admin.update_user",
    "auth.login",
    "auth.logout",
)

VITALS_INIT_SCRIPT = """
(() => {
  window.__icVitals = { lcp: 0, cls: 0 };
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        window.__icVitals.lcp = entry.startTime;
      }
    }).observe({ type: "largest-contentful-paint", buffered: true });
  } catch (_) {}
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        if (!entry.hadRecentInput) {
          window.__icVitals.cls += entry.value;
        }
      }
    }).observe({ type: "layout-shift", buffered: true });
  } catch (_) {}
})();
"""


def _seed_scale_data(admin_email: str) -> None:
    session_ids = [str(UUID(int=i + 1)) for i in range(SESSIONS)]
    with store.connection(write=True) as db:
        db.executemany(
            "INSERT INTO sessions (id,candidate,role,policy,consent,created_at) VALUES (?,?,?,?,?,?)",
            (
                (
                    sid,
                    f"Fixture {i:04}",
                    "Firmware engineer",
                    "Public documentation permitted.",
                    1,
                    f"2026-01-{1 + i % 28:02}T{i % 24:02}:{(i // 24) % 60:02}:00Z",
                )
                for i, sid in enumerate(session_ids)
            ),
        )
        db.executemany(
            "INSERT INTO session_context (session_id,ended_at) VALUES (?,?)",
            ((sid, None if i % 2 else "2026-02-01T00:00:00Z") for i, sid in enumerate(session_ids)),
        )
        db.executemany(
            "INSERT INTO answers (id,session_id,question,answer,refs,result,status) VALUES (?,?,?,?,?,?,?)",
            (
                (
                    str(UUID(int=10000 + i * ANSWERS_PER_SESSION + j)),
                    sid,
                    f"Which clock changes at step {j}?",
                    (
                        "Telemetry synchronization requires an independent oscillator while the primary source is being calibrated."
                    ),
                    "[]",
                    "{}",
                    "match" if i % 3 == j else "no_match",
                )
                for i, sid in enumerate(session_ids)
                for j in range(ANSWERS_PER_SESSION)
            ),
        )

    base_ms = 1_760_000_000_000
    with account_db.connection(write=True) as adb:
        admin_row = adb.execute("SELECT id FROM users WHERE email=?", (admin_email,)).fetchone()
        assert admin_row is not None
        user_ids = [admin_row["id"]] + [str(uuid4()) for _ in range(USERS - 1)]
        adb.executemany(
            "INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,?,?,?)",
            (
                (
                    uid,
                    f"scale-e2e-user-{idx:04}@example.invalid",
                    account_db.DECOY,
                    "user",
                    0,
                    base_ms + idx * 1000,
                    base_ms + idx * 1000,
                )
                for idx, uid in enumerate(user_ids[1:], start=1)
            ),
        )
        adb.executemany(
            "INSERT INTO audit_log(at,actor_user_id,action,target_user_id,details) VALUES (?,?,?,?,?)",
            (
                (
                    base_ms + i * 500,
                    user_ids[i % len(user_ids)],
                    AUDIT_ACTIONS[i % len(AUDIT_ACTIONS)],
                    user_ids[(i + 1) % len(user_ids)],
                    json.dumps({"seq": i, "slug": f"model-{i % 10}"}),
                )
                for i in range(AUDIT_ROWS)
            ),
        )


@pytest.fixture(scope="function")
def seeded_scale_workspace(tmp_path, monkeypatch, frontend):
    ws = IsolatedWorkspace(tmp_path, monkeypatch, frontend)
    ws.prepare_env()
    ws.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    ws.start()
    try:
        with ws.client() as client:
            signup_user(client, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
        _seed_scale_data(ADMIN_EMAIL)
        yield ws
    finally:
        ws.stop()


def _collect_metrics(page) -> dict[str, float | int]:
    try:
        page.wait_for_function(
            "() => Boolean(window.__icVitals && window.__icVitals.lcp > 0)",
            timeout=2500,
        )
    except PlaywrightTimeoutError:
        pass
    return page.evaluate(
        """() => document.fonts.ready.then(() => new Promise((resolve) => {
          requestAnimationFrame(() => requestAnimationFrame(() => {
            const vitals = window.__icVitals || { lcp: 0, cls: 0 };
            resolve({
              lcp: vitals.lcp,
              cls: vitals.cls,
              domNodes: document.querySelectorAll("*").length,
            });
          }));
        }))"""
    )


def _assert_vitals_and_layout(page, route_label: str) -> None:
    metrics = _collect_metrics(page)
    assert 0 < metrics["lcp"] < 2500, f"{route_label} LCP={metrics['lcp']:.1f} ms (expected < 2500 ms)"
    assert metrics["cls"] < 0.05, f"{route_label} CLS={metrics['cls']:.4f} (expected < 0.05)"
    assert metrics["domNodes"] < 1800, f"{route_label} DOM nodes={metrics['domNodes']} (expected < 1800)"
    assert_no_horizontal_overflow(page)


def _wait_archive(page, expected_pager: str) -> None:
    expect(page.get_by_text(expected_pager)).to_be_visible()
    expect(page.locator(".work-list li")).to_have_count(25)


@pytest.mark.parametrize(
    ("viewport_label", "viewport", "mobile"),
    [("1440x900", DESKTOP_VIEWPORT, False), ("390x844", MOBILE_VIEWPORT, True)],
)
def test_m9_scale_routes_web_vitals_dom_and_canvas(
    seeded_scale_workspace, e2e_browser, viewport_label, viewport, mobile
):
    base_url = seeded_scale_workspace.base_url
    context = e2e_browser.new_context(
        viewport=viewport, reduced_motion="no-preference", is_mobile=mobile, has_touch=mobile
    )
    context.add_init_script(VITALS_INIT_SCRIPT)
    try:
        login = context.request.post(
            base_url + "/api/integrations/access/login",
            headers={"X-InterviewCheck": "1"},
            data={"email": ADMIN_EMAIL, "password": ADMIN_PASS},
        )
        assert login.status == 200

        routes = [
            ("/", lambda p: expect(p.get_by_role("link", name="Total interviews").get_by_text("5,000")).to_be_visible()),
            ("/interviews/?page=1", lambda p: _wait_archive(p, "Page 1 of 200")),
            ("/interviews/?page=100", lambda p: _wait_archive(p, "Page 100 of 200")),
            ("/admin/", lambda p: expect(p.get_by_role("heading", name="Model administration")).to_be_visible()),
        ]
        for path, wait_fn in routes:
            page = context.new_page()
            page.set_default_timeout(10_000)
            page.set_default_navigation_timeout(30_000)
            collector = ConsoleErrorCollector()
            collector.attach(page)
            try:
                resp = page.goto(base_url + path, wait_until="domcontentloaded")
                assert resp is not None and resp.status == 200
                wait_fn(page)
                if path == "/" and not mobile:
                    field = page.locator('.signal-field[data-ready="true"]')
                    expect(field).to_be_visible()
                    canvas_ok = field.locator("canvas").evaluate(
                        "c => c.width > 0 && c.height > 0 && Boolean(c.getContext('2d'))"
                    )
                    assert canvas_ok, "Expected 2D SignalField <canvas> with non-zero dimensions"
                _assert_vitals_and_layout(page, f"{path} ({viewport_label})")

                if path == "/admin/":
                    page.get_by_role("tab", name="Audit log").click()
                    expect(page.get_by_text("Showing 50 events")).to_be_visible()
                    expect(page.locator(".admin-table tbody tr")).to_have_count(50)
                    _assert_vitals_and_layout(page, f"/admin/ audit tab ({viewport_label})")
                collector.assert_clean()
            finally:
                page.close()
    finally:
        context.close()
