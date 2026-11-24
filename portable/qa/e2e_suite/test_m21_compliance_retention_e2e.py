"""Opaque-box Playwright E2E tests for M21 compliance posture, retention/PII scrub, audit export, and CORS/auth."""
import json
from uuid import uuid4

import httpx
from playwright.sync_api import expect

from api import store
from e2e_suite.harness import assert_no_horizontal_overflow, login_user, signup_user

ADMIN_EMAIL = "admin-m21@example.test"
MEMBER_EMAIL = "member-m21@example.test"
BOOTSTRAP_SECRET = "m21-bootstrap-secret-1234"
ADMIN_PASS = "Synthetic-M21-Admin-Pass-1"
MEMBER_PASS = "Synthetic-M21-Member-Pass-1"


def _setup_auth(e2e_workspace) -> None:
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    e2e_workspace.restart()
    with e2e_workspace.client() as c:
        signup_user(c, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
        signup_user(c, email=MEMBER_EMAIL, password=MEMBER_PASS)


def _sign_in_admin(page, base_url: str) -> None:
    page.goto(base_url + "/admin/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Administrator sign in required")).to_be_visible()
    page.get_by_label("Operator email").fill(ADMIN_EMAIL)
    page.get_by_label("Password", exact=True).fill(ADMIN_PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_role("heading", name="Model administration")).to_be_visible()


def _seed_compliance_sessions(c) -> tuple[str, str, str]:
    role = c.post(
        "/api/roles",
        json={
            "name": "Platform Security Engineer",
            "description": "Security architecture evaluation",
            "policy": "Declared reference material only.",
            "questions": ["How do you isolate tenant credentials?"],
            "permitted_sources": [],
            "rubric": [{"id": "sec", "criterion": "Credential Isolation", "weight": 2}],
        },
    )
    role.raise_for_status()
    role_data = role.json()

    def make_session(candidate: str, answer_text: str) -> tuple[str, str]:
        s_res = c.post(
            "/api/sessions",
            json={
                "candidate": candidate,
                "role": role_data["name"],
                "role_id": role_data["id"],
                "policy": role_data["policy"],
                "consent": True,
            },
        )
        s_res.raise_for_status()
        sid = s_res.json()["id"]
        a_res = c.post(
            f"/api/sessions/{sid}/answers",
            json={
                "question": "How do you isolate tenant credentials?",
                "answer": answer_text,
                "references": [],
            },
        )
        a_res.raise_for_status()
        return sid, a_res.json()["id"]

    old_sid, old_aid = make_session("Elena RedactMe", "Elena uses per-tenant KMS envelopes and strict isolation.")
    c.patch(
        f"/api/sessions/{old_sid}/answers/{old_aid}",
        json={"disposition": "explained", "note": "Private interviewer note for Elena"},
    ).raise_for_status()
    c.put(
        f"/api/sessions/{old_sid}/scorecard",
        json={
            "items": [
                {
                    "criterion_id": "sec",
                    "criterion_label": "Credential Isolation",
                    "weight": 2,
                    "rating": 5,
                    "rationale": "Strong envelope encryption breakdown.",
                }
            ]
        },
    ).raise_for_status()
    c.post(
        f"/api/sessions/{old_sid}/handoff-notes",
        json={"category": "observation", "body": "Handoff observation note for panel"},
    ).raise_for_status()
    c.post(f"/api/sessions/{old_sid}/finish").raise_for_status()

    recent_sid, _ = make_session("Marcus KeepMe", "Marcus rotates signing keys every 30 days.")
    trashed_sid, _ = make_session("Trashed Expired", "Old trashed interview transcript.")
    c.post("/api/interviews/bulk/archive", json={"session_ids": [trashed_sid], "confirm_count": 1}).raise_for_status()

    with store.connection(write=True) as db:
        db.execute("UPDATE sessions SET created_at=? WHERE id=?", ("2025-01-10T10:00:00Z", old_sid))
        db.execute("UPDATE session_context SET ended_at=? WHERE session_id=?", ("2025-01-10T11:00:00Z", old_sid))
        db.execute("UPDATE session_trash SET trashed_at=? WHERE session_id=?", ("2025-01-10T12:00:00Z", trashed_sid))
    return old_sid, recent_sid, trashed_sid


def test_m21_compliance_auth_cors_and_proxy_gating(e2e_workspace):
    _setup_auth(e2e_workspace)
    dummy_sid = str(uuid4())
    get_paths = (
        "/api/admin/compliance/report",
        "/api/admin/compliance/retention",
        "/api/admin/compliance/headers-check",
        f"/api/admin/compliance/sessions/{dummy_sid}/audit",
    )

    with e2e_workspace.client() as anon:
        for path in get_paths:
            assert anon.get(path).status_code == 401
        assert anon.put(
            "/api/admin/compliance/retention",
            json={"anonymize_after_days": 30, "purge_trashed_after_days": 15, "preserve_scorecard_aggregates": True, "enabled": True},
        ).status_code == 401
        assert anon.post("/api/admin/compliance/retention/run", json={"dry_run": True}).status_code == 401

        for path in ("/api/admin/compliance/report", "/v1/admin/compliance/summary"):
            preflight = anon.options(
                path,
                headers={"Origin": "https://evil.example", "Access-Control-Request-Method": "GET"},
            )
            assert preflight.status_code == 403
            assert "access-control-allow-origin" not in preflight.headers

    api_origin = f"http://127.0.0.1:{e2e_workspace._bound_api_port}"
    with httpx.Client(base_url=api_origin, trust_env=False, timeout=10.0) as direct:
        dup_host = direct.get(
            "/api/admin/compliance/report",
            headers=[("X-Forwarded-Host", "127.0.0.1"), ("X-Forwarded-Host", "evil.example")],
        )
        assert dup_host.status_code == 400
        dup_ip = direct.get(
            "/api/admin/compliance/report",
            headers={"X-InterviewCheck-Client-IP": "127.0.0.1, 10.0.0.2"},
        )
        assert dup_ip.status_code == 400

    with e2e_workspace.client() as member_api:
        login_user(member_api, email=MEMBER_EMAIL, password=MEMBER_PASS)
        for path in get_paths:
            assert member_api.get(path).status_code == 403
        assert member_api.put(
            "/api/admin/compliance/retention",
            json={"anonymize_after_days": 30, "purge_trashed_after_days": 15, "preserve_scorecard_aggregates": True, "enabled": True},
        ).status_code == 403
        assert member_api.post("/api/admin/compliance/retention/run", json={"dry_run": True}).status_code == 403

    with e2e_workspace.client() as no_csrf:
        login_user(no_csrf, email=ADMIN_EMAIL, password=ADMIN_PASS)
        no_csrf.headers.pop("X-InterviewCheck", None)
        assert no_csrf.put(
            "/api/admin/compliance/retention",
            json={"anonymize_after_days": 30, "purge_trashed_after_days": 15, "preserve_scorecard_aggregates": True, "enabled": True},
        ).status_code == 403
        assert no_csrf.post("/api/admin/compliance/retention/run", json={"dry_run": True}).status_code == 403

    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        rep = admin_api.get("/api/admin/compliance/report")
        assert rep.status_code == 200
        assert rep.headers.get("cache-control") == "no-store"
        body = rep.text
        for secret in (ADMIN_PASS, MEMBER_PASS, BOOTSTRAP_SECRET, "e2e-deterministic-test-secret-key"):
            assert secret not in body


def test_m21_compliance_tab_retention_audit_and_mobile(e2e_workspace, desktop_page, mobile_page):
    _setup_auth(e2e_workspace)
    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        old_sid, recent_sid, trashed_sid = _seed_compliance_sessions(admin_api)
        pre_search = admin_api.post("/api/search", json={"query": "Elena"})
        pre_search.raise_for_status()
        assert any(item["session_id"] == old_sid for item in pre_search.json()["items"])

    page, collector = desktop_page
    _sign_in_admin(page, e2e_workspace.base_url)

    tabs = page.get_by_role("tablist", name="Admin sections").get_by_role("tab")
    expect(tabs).to_have_count(9)
    compliance_tab = page.get_by_role("tab", name="Compliance")
    compliance_tab.click()
    expect(compliance_tab).to_have_attribute("aria-selected", "true")

    posture = page.locator("section[aria-label='Compliance posture and reports']")
    expect(posture.get_by_role("heading", name="Compliance posture & reports")).to_be_visible()
    expect(posture.get_by_text("Audit hash chains")).to_be_visible()
    expect(posture.get_by_text("Intact")).to_be_visible()
    expect(posture.get_by_text("0 anonymized")).to_be_visible()
    expect(posture.get_by_text("2 active, 1 trashed")).to_be_visible()
    expect(posture.get_by_text("Access DB: v8")).to_be_visible()

    headers_sec = page.locator("section[aria-label='Edge header and boundary checks']")
    headers_sec.get_by_role("button", name="Run header check").click()
    expect(page.get_by_text("Edge header and boundary checks passed.")).to_be_visible()
    expect(headers_sec.get_by_text("Boundary OK")).to_be_visible()
    expect(headers_sec.get_by_text("host_header")).to_be_visible()
    expect(headers_sec.get_by_text("duplicate_proxy_headers")).to_be_visible()

    with page.expect_download() as rep_json_dl:
        posture.get_by_role("button", name="Report JSON").click()
    assert rep_json_dl.value.suggested_filename == "compliance-report.json"
    rep_json = json.loads(rep_json_dl.value.path().read_text(encoding="utf-8"))
    assert rep_json["format"] == "interviewcheck.compliance_report"
    assert rep_json["sessions"]["total"] == 3
    assert rep_json["access_db"]["schema_version"] == 8

    with page.expect_download() as rep_md_dl:
        posture.get_by_role("button", name="Report Markdown").click()
    assert rep_md_dl.value.suggested_filename == "compliance-report.md"
    rep_md = rep_md_dl.value.path().read_text(encoding="utf-8")
    assert "# InterviewCheck Compliance Report" in rep_md
    assert "schema v8" in rep_md

    ret_sec = page.locator("section[aria-label='Data retention and PII anonymization']")
    ret_sec.get_by_label("Anonymize finished sessions after (days, 0 disables)").fill("30")
    ret_sec.get_by_label("Purge trashed sessions after (days, 0 disables)").fill("15")
    ret_sec.get_by_label("Policy enabled").check()
    ret_sec.get_by_role("button", name="Save policy").click()
    expect(page.get_by_text("Retention policy saved.")).to_be_visible()

    ret_sec.get_by_role("button", name="Dry-run preview").click()
    expect(page.get_by_text("Dry-run preview complete: 1 anonymized, 1 purged.")).to_be_visible()
    latest_region = ret_sec.get_by_role("region", name="Latest retention execution result")
    expect(latest_region).to_contain_text("1 anonymized, 1 purged")
    expect(latest_region).to_contain_text(old_sid)

    live_btn = ret_sec.get_by_role("button", name="Run live retention")
    expect(live_btn).to_be_disabled()
    ret_sec.get_by_label("Type RUN to enable live execution").fill("RUN")
    expect(live_btn).to_be_enabled()
    live_btn.click()
    expect(page.get_by_text("Live retention complete: 1 anonymized, 1 purged.")).to_be_visible()

    expect(posture.get_by_text("1 anonymized")).to_be_visible()
    expect(posture.get_by_text("2 active, 0 trashed")).to_be_visible()
    history_rows = ret_sec.locator("table.admin-table tbody tr")
    expect(history_rows).to_have_count(2)
    expect(ret_sec.locator("table.admin-table")).to_contain_text("Dry run")
    expect(ret_sec.locator("table.admin-table")).to_contain_text("Live")

    with e2e_workspace.client() as admin_api:
        login_user(admin_api, email=ADMIN_EMAIL, password=ADMIN_PASS)
        assert admin_api.post("/api/search", json={"query": "Elena"}).json()["items"] == []
        assert admin_api.post("/api/search", json={"query": "per-tenant KMS"}).json()["items"] == []
        kept_hits = admin_api.post("/api/search", json={"query": "Marcus"}).json()["items"]
        assert any(item["session_id"] == recent_sid for item in kept_hits)
        assert admin_api.get(f"/api/sessions/{trashed_sid}").status_code == 404

    audit_sec = page.locator("section[aria-label='Single-session audit export']")
    audit_sec.get_by_label("Session UUID").fill(old_sid)
    audit_sec.get_by_role("button", name="Preview").click()
    expect(audit_sec.get_by_text(f"Candidate [Anonymized {old_sid[:8]}]")).to_be_visible()
    expect(audit_sec.get_by_text("Anonymized", exact=True)).to_be_visible()
    expect(audit_sec.locator("table.admin-table")).to_contain_text("session.anonymized")
    expect(audit_sec.locator("table.admin-table")).to_contain_text("answer.review")
    expect(audit_sec.locator("table.admin-table")).to_contain_text("scorecard.updated")
    expect(audit_sec.locator("table.admin-table")).to_contain_text("handoff_note.created")

    with page.expect_download() as audit_json_dl:
        audit_sec.get_by_role("button", name="Export JSON").click()
    assert audit_json_dl.value.suggested_filename == f"session-audit-{old_sid}.json"
    audit_json_text = audit_json_dl.value.path().read_text(encoding="utf-8")
    assert "Private interviewer note for Elena" not in audit_json_text
    assert "Handoff observation note for panel" not in audit_json_text
    audit_json = json.loads(audit_json_text)
    assert audit_json["session"]["anonymization"]["anonymized"] is True
    assert audit_json["counts"]["timeline_events"] >= 6

    with page.expect_download() as audit_csv_dl:
        audit_sec.get_by_role("button", name="Export CSV").click()
    assert audit_csv_dl.value.suggested_filename == f"session-audit-{old_sid}.csv"
    audit_csv = audit_csv_dl.value.path().read_text(encoding="utf-8-sig")
    assert "session.anonymized" in audit_csv and "scorecard.updated" in audit_csv

    assert_no_horizontal_overflow(page)
    collector.assert_clean()

    m_page, m_collector = mobile_page
    _sign_in_admin(m_page, e2e_workspace.base_url)
    m_page.get_by_role("tab", name="Compliance").click()
    expect(m_page.get_by_role("heading", name="Compliance posture & reports")).to_be_visible()
    expect(m_page.get_by_text("1 anonymized")).to_be_visible()
    expect(m_page.get_by_role("button", name="Run live retention")).to_be_visible()
    assert_no_horizontal_overflow(m_page)
    m_collector.assert_clean()
