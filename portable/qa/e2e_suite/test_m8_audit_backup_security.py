"""Playwright E2E tests for M8 audit log filtering/export, backup integrity, and browser security."""
import csv
from datetime import datetime, timedelta, timezone
import hashlib
from io import StringIO
import json
from uuid import uuid4

from playwright.sync_api import expect
import pytest

from api import account_db, store
from e2e_suite.harness import (
    ConsoleErrorCollector,
    assert_no_horizontal_overflow,
    login_user,
    signup_user,
)

ADMIN_EMAIL = "admin-m8@example.test"
MEMBER_EMAIL = "member-m8@example.test"
BOOTSTRAP_SECRET = "m8-bootstrap-secret-1234"
ADMIN_PASS = "Synthetic-M8-Admin-Pass-1"
MEMBER_PASS = "Synthetic-M8-Member-Pass-1"


def _setup_auth(e2e_workspace, *, include_member: bool = False) -> None:
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
    if include_member:
        with e2e_workspace.client() as c:
            signup_user(c, email=MEMBER_EMAIL, password=MEMBER_PASS)


def _sign_in_admin(page, base_url: str) -> None:
    page.goto(base_url + "/admin/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Administrator sign in required")).to_be_visible()
    page.get_by_label("Operator email").fill(ADMIN_EMAIL)
    page.get_by_label("Password", exact=True).fill(ADMIN_PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_role("tablist", name="Admin sections")).to_be_visible()


def _insert_audit(at_ms: int, action: str, actor: str | None, target: str | None, details) -> None:
    with account_db.connection(write=True) as db:
        raw = json.dumps(details) if isinstance(details, (dict, list)) else details
        db.execute(
            "INSERT INTO audit_log(at,actor_user_id,action,target_user_id,details) VALUES (?,?,?,?,?)",
            (at_ms, actor, action, target, raw),
        )


def _assert_security_headers(headers: dict[str, str], *, is_print: bool = False) -> None:
    lowered = {k.lower(): v for k, v in headers.items()}
    assert lowered.get("x-content-type-options") == "nosniff"
    assert lowered.get("x-frame-options") == "DENY"
    assert lowered.get("referrer-policy") == "no-referrer"
    csp = lowered.get("content-security-policy", "")
    assert "frame-ancestors 'none'" in csp and "object-src 'none'" in csp
    if is_print:
        assert "default-src 'none'" in csp and "script-src 'self'" in csp
    else:
        assert "default-src 'self'" in csp and "'unsafe-inline'" not in csp.split("script-src")[1].split(";")[0]


def test_m8_audit_filtering_pagination_export_and_auth(e2e_workspace, desktop_page, tmp_path):
    _setup_auth(e2e_workspace, include_member=True)
    with e2e_workspace.client() as anon:
        assert anon.get("/api/integrations/admin/audit/export").status_code == 401
        assert anon.get("/api/integrations/admin/audit").status_code == 401
    with e2e_workspace.client() as member_api:
        login_user(member_api, email=MEMBER_EMAIL, password=MEMBER_PASS)
        assert member_api.get("/api/integrations/admin/audit/export").status_code == 403
        assert member_api.get("/api/integrations/admin/audit").status_code == 403

    actor_a = str(uuid4())
    actor_b = str(uuid4())
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        res = admin_api.post(
            "/api/admin/models",
            json={
                "slug": "m8-audit-model",
                "display_name": "M8 Audit Model",
                "provider": "openai",
                "capability": "reference",
                "model_id": "gpt-4o",
                "apiKey": "sk-m8-audit-1234",
            },
        )
        res.raise_for_status()

    day1 = datetime(2026, 11, 10, 12, 0, tzinfo=timezone.utc)
    day2 = datetime(2026, 11, 12, 12, 0, tzinfo=timezone.utc)
    ms = lambda dt: int(dt.timestamp() * 1000)
    _insert_audit(ms(day1), "admin.model.probe", actor_a, str(uuid4()), {"slug": "alpha_100%"})
    _insert_audit(ms(day1 + timedelta(minutes=2)), "=cmd|'/C calc'!A0", "+1+2", "-1-2", "@SUM(1,1)")
    _insert_audit(ms(day2), "admin.update_user", actor_b, str(uuid4()), {"role": "admin"})
    for idx in range(19):
        _insert_audit(ms(day2 + timedelta(seconds=idx + 1)), "auth.login", actor_b, actor_b, {"seq": idx})

    page, collector = desktop_page
    _sign_in_admin(page, e2e_workspace.base_url)
    page.get_by_role("tab", name="Audit log").click()

    # Preserve initial visibility of admin.model.create before filtering.
    expect(page.get_by_text("admin.model.create").first).to_be_visible()
    total_rows = page.locator("tbody tr").count()
    assert total_rows >= 25

    # Cursor pagination via Page size + Load older.
    page.get_by_label("Page size").select_option("20")
    expect(page.locator("tbody tr")).to_have_count(20)
    load_older = page.get_by_role("button", name="Load older")
    expect(load_older).to_be_visible()
    load_older.click()
    expect(page.locator("tbody tr")).to_have_count(total_rows)
    expect(load_older).to_have_count(0)

    # Category filter.
    page.get_by_label("Category").select_option("models")
    expect(page.get_by_text("auth.login")).to_have_count(0)
    expect(page.get_by_text("admin.model.create").first).to_be_visible()
    page.get_by_label("Category").select_option("accounts")
    expect(page.get_by_text("admin.model.create")).to_have_count(0)
    expect(page.get_by_text("auth.login").first).to_be_visible()
    page.get_by_label("Category").select_option("all")

    # Literal % / _ search and SQLi resistance.
    q_input = page.get_by_label("Filter events")
    q_input.fill("100%")
    expect(page.locator("tbody tr")).to_have_count(1)
    expect(page.locator("tbody")).to_contain_text("alpha_100%")
    q_input.fill("alpha_")
    expect(page.locator("tbody tr")).to_have_count(1)
    q_input.fill("' OR 1=1 --")
    expect(page.get_by_text("No audit events match the selected filter.")).to_be_visible()
    q_input.fill("")

    # Action and Actor ID filters.
    page.get_by_label("Action").fill("admin.model.probe")
    expect(page.locator("tbody tr")).to_have_count(1)
    page.get_by_label("Actor ID").fill(actor_a)
    expect(page.locator("tbody tr")).to_have_count(1)
    page.get_by_role("button", name="Clear filters").click()
    expect(page.get_by_text("admin.model.create").first).to_be_visible()

    # Date range validation + valid window filtering.
    page.get_by_label("From date").fill("2026-11-12")
    page.get_by_label("To date").fill("2026-11-10")
    expect(page.locator('p[role="alert"]')).to_contain_text("From date must be on or before To date.")
    page.get_by_label("From date").fill("2026-11-10")
    page.get_by_label("To date").fill("2026-11-10")
    expect(page.locator("tbody tr")).to_have_count(2)
    page.get_by_role("button", name="Clear filters").click()

    # Export CSV with formula neutralization and UTF-8 BOM.
    q_input.fill("@SUM")
    expect(page.locator("tbody tr")).to_have_count(1)
    export_csv_btn = page.get_by_role("button", name="Export CSV")
    expect(export_csv_btn).to_be_enabled()
    with page.expect_download() as csv_dl:
        export_csv_btn.click()
    csv_path = tmp_path / "audit-log.csv"
    csv_dl.value.save_as(csv_path)
    raw_csv = csv_path.read_bytes()
    assert raw_csv.startswith(b"\xef\xbb\xbf")
    rows = list(csv.DictReader(StringIO(raw_csv.decode("utf-8-sig"))))
    assert len(rows) == 1
    assert rows[0]["action"] == "'=cmd|'/C calc'!A0"
    assert rows[0]["actorUserId"] == "'+1+2"
    assert rows[0]["targetUserId"] == "'-1-2"
    assert rows[0]["details"] == "'@SUM(1,1)"

    # Export JSON filtered to models.
    page.get_by_role("button", name="Clear filters").click()
    page.get_by_label("Category").select_option("models")
    export_json_btn = page.get_by_role("button", name="Export JSON")
    expect(export_json_btn).to_be_enabled()
    with page.expect_download() as json_dl:
        export_json_btn.click()
    json_path = tmp_path / "audit-log.json"
    json_dl.value.save_as(json_path)
    exported = json.loads(json_path.read_text(encoding="utf-8"))
    assert len(exported["entries"]) >= 2
    assert all(e["action"].startswith("admin.model.") for e in exported["entries"])
    collector.assert_clean()


def test_m8_backup_checksum_ui_and_tamper_rejection(e2e_workspace, desktop_page, monkeypatch, tmp_path):
    phrase = "Calibrate the receiver across three cold baselines before comparing packet counts."
    with e2e_workspace.client() as c:
        role = c.post(
            "/api/roles",
            json={"name": "M8 Role", "description": "Integrity", "questions": ["Why?"]},
        ).json()
        sid = c.post(
            "/api/sessions",
            json={"candidate": "M8 Candidate", "role": "M8 Role", "role_id": role["id"], "consent": True, "policy": "Strict"},
        ).json()["id"]
        c.post(
            f"/api/sessions/{sid}/answers",
            json={"question": "Why?", "answer": phrase, "references": [{"label": "Doc", "text": phrase}]},
        ).raise_for_status()
        c.post(f"/api/sessions/{sid}/finish").raise_for_status()
        exported = c.get("/api/backups/workspace")
        exported.raise_for_status()

    raw_bytes = exported.content
    expected_sha256 = hashlib.sha256(raw_bytes).hexdigest()
    assert exported.headers.get("x-backup-sha256") == expected_sha256
    base_doc = json.loads(raw_bytes)
    assert set(base_doc.keys()) == {"format", "version", "roles", "sessions"}

    backup_file = tmp_path / "valid-backup.json"
    backup_file.write_bytes(raw_bytes)

    target_db = tmp_path / "restore_target.sqlite"
    store.initialize(target_db)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target_db))

    page, collector = desktop_page
    page.goto(e2e_workspace.base_url + "/data/", wait_until="domcontentloaded")
    page.get_by_label("Workspace backup file").set_input_files(backup_file)
    sha_input = page.get_by_label("Expected SHA-256 checksum (optional)")

    # Mismatched checksum on Preview -> explicit 409 role="alert" without restoring records.
    sha_input.fill("0" * 64)
    page.get_by_role("button", name="Preview restore").click()
    expect(page.locator('p[role="alert"]')).to_contain_text("does not match")
    with e2e_workspace.client() as c:
        assert c.get("/api/sessions").json() == []
        assert c.get("/api/roles").json() == []
    assert not collector.page_errors and not collector.server_errors
    assert all("409" in msg for msg in collector.console_errors)
    collector.reset()

    # Matching checksum on Preview -> shows [data-testid="backup-sha256"] fingerprint.
    sha_input.fill(expected_sha256)
    page.get_by_role("button", name="Preview restore").click()
    expect(page.get_by_test_id("backup-sha256")).to_have_text(expected_sha256)

    # Mismatched checksum before clicking Restore new records -> explicit 409 alert, zero partial writes.
    sha_input.fill("f" * 64)
    page.get_by_role("button", name="Restore new records").click()
    expect(page.locator('p[role="alert"]')).to_contain_text("does not match")
    with e2e_workspace.client() as c:
        assert c.get("/api/sessions").json() == []
        assert c.get("/api/roles").json() == []
    assert not collector.page_errors and not collector.server_errors
    assert all("409" in msg for msg in collector.console_errors)
    collector.reset()

    # Matching checksum -> Preview + Restore succeeds.
    sha_input.fill(expected_sha256)
    page.get_by_role("button", name="Preview restore").click()
    expect(page.get_by_test_id("backup-sha256")).to_have_text(expected_sha256)
    page.get_by_role("button", name="Restore new records").click()
    expect(page.get_by_role("status").filter(has_text="Restored 1 interviews and 1 roles")).to_be_visible()
    with e2e_workspace.client() as c:
        assert len(c.get("/api/sessions").json()) == 1
        assert len(c.get("/api/roles").json()) == 1
    collector.assert_clean()

    # Tampered JSON payloads rejected cleanly with role="alert" and zero restores.
    tamper_db = tmp_path / "tamper_target.sqlite"
    store.initialize(tamper_db)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tamper_db))
    page.reload(wait_until="domcontentloaded")

    nested = {"leaf": 1}
    for _ in range(16):
        nested = {"n": nested}
    cases = [
        ("null_byte", lambda d: d["sessions"][0].__setitem__("candidate", "Eve\x00Bad")),
        ("legacy_depth", lambda d: d["roles"][0].__setitem__("legacy", nested)),
        ("bad_span", lambda d: d["sessions"][0]["answers"][0]["result"]["passages"][0].__setitem__("answer_span", [5, 5])),
        ("chronology", lambda d: d["sessions"][0].__setitem__("ended_at", "2020-01-01T00:00:00Z")),
    ]
    for label, mutate in cases:
        tampered = json.loads(json.dumps(base_doc))
        mutate(tampered)
        path = tmp_path / f"tamper_{label}.json"
        path.write_text(json.dumps(tampered), encoding="utf-8")
        page.get_by_label("Workspace backup file").set_input_files(path)
        page.get_by_role("button", name="Preview restore").click()
        expect(page.locator('p[role="alert"]')).to_be_visible()
        with e2e_workspace.client() as c:
            assert c.get("/api/sessions").json() == []
            assert c.get("/api/roles").json() == []
        assert not collector.page_errors and not collector.server_errors
        assert all("422" in msg for msg in collector.console_errors), (label, collector.console_errors)
        collector.reset()


def test_m8_browser_xss_escaping_csp_and_responsive_viewports(e2e_workspace, e2e_browser):
    _setup_auth(e2e_workspace)
    xss_role = '<img src=x onerror="window.__xss=1;alert(\'role\')">'
    xss_cand = '<img src=y onerror="window.__xss=2;alert(\'cand\')">'
    xss_q = '<svg onload="window.__xss=3;alert(\'q\')">'
    xss_ans = '<script>window.__xss=4;alert("ans")</script> safe-word'

    ctx = e2e_browser.new_context(viewport={"width": 1440, "height": 900}, reduced_motion="reduce")
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    dialogs: list[str] = []
    page.on("dialog", lambda d: (dialogs.append(d.message), d.dismiss()))
    try:
        _sign_in_admin(page, e2e_workspace.base_url)

        # Create role with XSS payload.
        page.goto(e2e_workspace.base_url + "/roles/", wait_until="domcontentloaded")
        page.get_by_role("button", name="Add role").click()
        page.get_by_label("Role name").fill(xss_role)
        page.get_by_label("Description").fill(xss_ans)
        page.get_by_label("Planned questions, one per line").fill(xss_q)
        page.get_by_role("button", name="Save role").click()
        expect(page.get_by_text(xss_role, exact=True)).to_be_visible()

        # Create session with XSS payload.
        page.goto(e2e_workspace.base_url + "/interviews/new/", wait_until="domcontentloaded")
        page.get_by_label("Candidate", exact=True).fill(xss_cand)
        page.get_by_label("Role", exact=True).fill(xss_role)
        page.get_by_label("Assistance policy").fill(xss_ans)
        page.get_by_role("checkbox", name="I confirmed", exact=False).check()
        page.get_by_role("button", name="Start interview").click()
        expect(page.get_by_role("heading", name=xss_cand, exact=True)).to_be_visible()
        sid = page.url.split("id=")[-1].split("&")[0]

        # Capture exchange with XSS payload in question and answer (editor opens by default).
        page.get_by_label("Question", exact=True).fill(xss_q)
        page.get_by_label("Candidate answer").fill(xss_ans)
        page.get_by_role("button", name="Save and compare").click()
        expect(page.get_by_role("heading", name=xss_q, exact=True)).to_be_visible()
        expect(page.locator("article > .transcript-text")).to_contain_text(xss_ans)

        # Verify brief, print, roles, data, and admin routes render escaped with strict CSP and no overflow.
        for width, height, mobile in [(1440, 900, False), (390, 844, True)]:
            page.set_viewport_size({"width": width, "height": height})
            checks = [
                ("/roles/", lambda: expect(page.get_by_text(xss_role, exact=True)).to_be_visible()),
                (f"/interviews/review/?id={sid}", lambda: expect(page.get_by_role("heading", name=xss_q, exact=True)).to_be_visible()),
                (f"/interviews/brief/?id={sid}", lambda: expect(page.get_by_role("heading", name="Interview review brief")).to_be_visible()),
                ("/data/", lambda: expect(page.get_by_role("heading", name="Restore from a backup")).to_be_visible()),
                ("/admin/", lambda: expect(page.get_by_role("tablist", name="Admin sections")).to_be_visible()),
            ]
            for route, ready in checks:
                resp = page.goto(e2e_workspace.base_url + route, wait_until="domcontentloaded")
                assert resp is not None and resp.status == 200
                _assert_security_headers(resp.headers)
                ready()
                assert_no_horizontal_overflow(page)
            if mobile:
                expect(page.get_by_role("button", name="Open navigation menu")).to_be_visible()
            page.get_by_role("tab", name="Audit log").click()
            expect(page.get_by_role("heading", name="Audit log")).to_be_visible()
            assert_no_horizontal_overflow(page)
            print_resp = page.goto(e2e_workspace.base_url + f"/api/sessions/{sid}/print", wait_until="domcontentloaded")
            assert print_resp is not None and print_resp.status == 200
            _assert_security_headers(print_resp.headers, is_print=True)
            expect(page.get_by_role("heading", name=f"Interview review for {xss_cand}")).to_be_visible()
            expect(page.locator("main")).to_contain_text(xss_ans)
            assert_no_horizontal_overflow(page)

        assert dialogs == []
        assert page.evaluate("() => window.__xss || 0") == 0
        collector.assert_clean()
    finally:
        ctx.close()
