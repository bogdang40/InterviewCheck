"""Tests for M21-W2 compliance report, session audit export, header checks, and edge CLI."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import threading
from uuid import uuid4

from fastapi import FastAPI
from fastapi.testclient import TestClient
import pytest
from starlette.datastructures import Headers
from starlette.responses import JSONResponse

from api import account_db, compliance_export, csp_reports, main, model_registry, rate_limit, secret_box, store
from api.local_boundary import LocalBoundary
from api.models import AnswerInput, RoleInput, SessionInput
from api.security_headers import SecurityHeadersMiddleware

SCRIPTS_DIR = Path(__file__).resolve().parents[2] / "scripts"
_SPEC = importlib.util.spec_from_file_location("verify_edge_security", SCRIPTS_DIR / "verify_edge_security.py")
assert _SPEC and _SPEC.loader
verify_edge_security = importlib.util.module_from_spec(_SPEC)
sys.modules["verify_edge_security"] = verify_edge_security
_SPEC.loader.exec_module(verify_edge_security)


def _build_app():
    if any(getattr(r, "path", "") == "/api/admin/compliance/report" for r in main.app.routes):
        return main.app
    test_app = FastAPI(lifespan=main.lifespan)
    test_app.add_middleware(LocalBoundary)
    test_app.add_middleware(SecurityHeadersMiddleware, static_dir=None)
    for exc_type, handler in main.app.exception_handlers.items():
        test_app.add_exception_handler(exc_type, handler)
    test_app.include_router(compliance_export.router)
    test_app.include_router(main.model_admin.router)
    return test_app


def _seed_user(*, email: str, role: str = "admin", disabled: int = 0) -> tuple[str, str]:
    uid, ts = str(uuid4()), account_db.now()
    with account_db.connection(write=True) as db:
        db.execute(
            "INSERT INTO users(id, email, password_hash, role, disabled, created_at, updated_at) VALUES (?,?,?,?,?,?,?)",
            (uid, email, account_db.DECOY, role, disabled, ts, ts),
        )
        account_db.audit(db, f"test.seed.{role}", uid, uid, {"seeded": True})
        return uid, account_db.issue(db, uid, "pytest")


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "test-m21-secret-master-key-xyz")
    monkeypatch.setenv("INTERVIEWCHECK_SIGNUP_SECRET", "super-secret-signup-token-999")
    monkeypatch.setenv("INTERVIEWCHECK_METRICS_TOKEN", "super-secret-metrics-token-888")
    rate_limit.reset_all()
    store.initialize(store.db_path())
    return tmp_path


def test_compliance_auth_gates_and_format_validation(env):
    del env
    _, user_tok = _seed_user(email="reviewer-m21@example.invalid", role="user")
    _, admin_tok = _seed_user(email="admin-m21@example.invalid", role="admin")
    app_obj = _build_app()
    sid = str(uuid4())

    with TestClient(app_obj, base_url="http://127.0.0.1") as client:
        for path in ("/api/admin/compliance/report", f"/api/admin/compliance/sessions/{sid}/audit", "/api/admin/compliance/headers-check"):
            assert client.get(path).status_code == 401
            client.cookies.set("ic_access", user_tok)
            assert client.get(path).status_code == 403
            client.cookies.clear()

        client.cookies.set("ic_access", admin_tok)
        assert client.get("/api/admin/compliance/report?format=xml").status_code == 422
        assert client.get(f"/api/admin/compliance/sessions/{sid}/audit?format=xml").status_code == 422
        resp = client.get("/api/admin/compliance/headers-check")
        assert resp.status_code == 200
        assert resp.headers["cache-control"] == "no-store"


def test_compliance_report_json_markdown_and_zero_secrets(env):
    del env
    admin_id, admin_tok = _seed_user(email="sec-admin@example.invalid", role="admin")
    _seed_user(email="disabled-user@example.invalid", role="user", disabled=1)
    now_ms = account_db.now()
    with account_db.connection(write=True) as adb:
        adb.execute("INSERT INTO user_totp(user_id, secret_enc, enabled, verified_at, created_at) VALUES (?,?,1,?,?)",
                    (admin_id, "v1:totp-secret-cipher", now_ms, now_ms))
        adb.execute("INSERT INTO api_tokens(id, user_id, name, token_prefix, token_hash, scopes_json, created_at) VALUES (?,?,?,?,?,?,?)",
                    (str(uuid4()), admin_id, "ci", "ict_abc", "hash-active-1", '["read:telemetry"]', now_ms))
        adb.execute("INSERT INTO api_tokens(id, user_id, name, token_prefix, token_hash, scopes_json, created_at, revoked_at) VALUES (?,?,?,?,?,?,?,?)",
                    (str(uuid4()), admin_id, "old", "ict_old", "hash-revoked-2", '["read:telemetry"]', now_ms, now_ms))

    secret_v1, secret_v2 = "sk-plain-v1-secret-value", "sk-plain-v2-secret-value"
    hook_secret = "whsec_do_not_leak_in_report"
    with store.connection(write=True) as db:
        m1, m2, m3 = str(uuid4()), str(uuid4()), str(uuid4())
        model_registry.create_model(
            db, model_uuid=m1, slug="m21-v1", display_name="V1", provider="openai", capability="reference",
            model_id="gpt-4o", endpoint=None, api_version=None, parameters={},
            encrypted_api_key=secret_box.encrypt_secret(secret_v1, aad=m1, envelope="v1"),
            key_hint=secret_box.mask_key_hint(secret_v1), enabled=True, is_default=True,
        )
        model_registry.create_model(
            db, model_uuid=m2, slug="m21-v2", display_name="V2", provider="anthropic", capability="judge",
            model_id="claude-sonnet-4-6", endpoint=None, api_version=None, parameters={},
            encrypted_api_key=secret_box.encrypt_secret(secret_v2, aad=m2, envelope="v2"),
            key_hint=secret_box.mask_key_hint(secret_v2), enabled=True, is_default=True,
        )
        model_registry.create_model(
            db, model_uuid=m3, slug="m21-none", display_name="NoKey", provider="openai_compatible", capability="embedding",
            model_id="bge-large", endpoint="https://llm.example.invalid/v1", api_version=None, parameters={},
            encrypted_api_key=None, key_hint=None, enabled=False, is_default=False,
        )
        model_registry.write_fallback_audit(db, actor_user_id=admin_id, action="model.created", model_uuid=m1, details={"ok": True})
        csp_reports.migrate(db)
        db.execute(
            "INSERT INTO csp_violations(received_at, document_uri, violated_directive, effective_directive, blocked_uri, source_file) "
            "VALUES (?,?,?,?,?,?)",
            ("2026-11-19T10:00:00Z", "http://127.0.0.1:3000/admin/", "script-src", "script-src", "https://bad.example/x.js", ""),
        )
        db.execute(
            "INSERT INTO alert_rules(id, name, trigger_type, threshold_value, webhook_url, encrypted_signing_secret, secret_hint, enabled, created_at, updated_at) "
            "VALUES (?,?,?,?,?,?,?,?,?,?)",
            (str(uuid4()), "ErrStreak", "model_error_streak", 3.0, "https://hooks.example.invalid/secret-path",
             hook_secret, "...port", 1, "2026-11-19T10:00:00Z", "2026-11-19T10:00:00Z"),
        )
        db.executescript("""
            CREATE TABLE IF NOT EXISTS retention_policies(id TEXT PRIMARY KEY, anonymize_after_days INTEGER, purge_trashed_after_days INTEGER, preserve_scorecard_aggregates INTEGER, enabled INTEGER, updated_by TEXT, updated_at TEXT);
            CREATE TABLE IF NOT EXISTS retention_runs(id TEXT PRIMARY KEY, dry_run INTEGER, actor_email TEXT, anonymized_sessions INTEGER, purged_sessions INTEGER, cutoff_anonymize_at TEXT, cutoff_purge_at TEXT, executed_at TEXT);
            CREATE TABLE IF NOT EXISTS session_anonymizations(session_id TEXT PRIMARY KEY, anonymized_at TEXT, anonymized_by TEXT);
        """)
        db.execute("INSERT OR REPLACE INTO retention_policies VALUES ('default', 60, 14, 1, 1, 'admin@example.invalid', '2026-11-19T10:00:00Z')")
        db.execute("INSERT INTO retention_runs VALUES ('run-1', 0, 'admin@example.invalid', 2, 1, '2026-09-20T00:00:00Z', '2026-11-05T00:00:00Z', '2026-11-19T10:05:00Z')")
        sess = store.create_session(db, SessionInput(candidate="Trashed Candidate", role="SWE", policy="No external tools.", consent=True))
        db.execute("INSERT INTO session_trash VALUES (?, '2026-11-19T10:00:00Z', 'v1')", (sess["id"],))
        db.execute("INSERT INTO session_anonymizations VALUES (?, '2026-11-19T10:05:00Z', 'admin@example.invalid')", (sess["id"],))

    with TestClient(_build_app(), base_url="http://127.0.0.1", cookies={"ic_access": admin_tok}) as client:
        r_json = client.get("/api/admin/compliance/report?format=json")
        assert r_json.status_code == 200
        assert r_json.headers["cache-control"] == "no-store"
        data = r_json.json()
        assert data["models"]["encryption_envelopes"] == {"v1": 1, "v2": 1, "none": 1, "other": 0}
        assert data["csp_violations"]["total"] == 1
        assert data["alert_rules"]["total"] == 1 and data["alert_rules"]["enabled"] == 1
        assert data["retention"]["policy"]["anonymize_after_days"] == 60
        assert data["retention"]["latest_run"]["anonymized_sessions"] == 2
        assert data["sessions"]["trashed"] == 1 and data["sessions"]["anonymized"] == 1
        assert data["audit_chains"]["model_fallback"]["ok"] is True
        assert data["audit_chains"]["access"]["ok"] is True
        assert data["access_db"]["schema_version"] == 8
        assert data["access_db"]["totp_enrolled"] == 1
        assert data["access_db"]["api_tokens"] == {"total": 2, "active": 1}

        r_md = client.get("/api/admin/compliance/report?format=markdown")
        assert r_md.status_code == 200
        assert r_md.headers["cache-control"] == "no-store"
        assert "# InterviewCheck Compliance Report" in r_md.text
        for body in (r_json.text, r_md.text):
            for forbidden in (secret_v1, secret_v2, hook_secret, "test-m21-secret-master-key-xyz",
                              "super-secret-signup-token-999", "super-secret-metrics-token-888",
                              "hooks.example.invalid", "sec-admin@example.invalid", "\u2014", "\u2013"):
                assert forbidden not in body


def test_compliance_report_defensive_without_retention_or_access_db(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "missing_access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://access.example.invalid")
    rate_limit.reset_all()
    store.initialize(store.db_path())

    async def fake_fetch_json(_svc, _method, _url, **_kw):
        return {"user": {"id": "remote-admin", "email": "remote@example.invalid", "role": "admin", "disabled": False},
                "entitlement": {"active": True, "source": "admin"}}

    monkeypatch.setattr("api.access.fetch_json", fake_fetch_json)
    with TestClient(_build_app(), base_url="http://127.0.0.1", cookies={"ic_access": "mm_remote_tok"}) as client:
        with store.connection(write=True) as db:
            db.execute("DROP TABLE IF EXISTS retention_runs")
            db.execute("DROP TABLE IF EXISTS retention_policies")
            db.execute("DROP TABLE IF EXISTS session_anonymizations")
        resp = client.get("/api/admin/compliance/report")
    assert resp.status_code == 200
    body = resp.json()
    assert body["retention"]["policy_table_present"] is False
    assert body["sessions"]["anonymization_table_present"] is False
    assert body["access_db"]["available"] is False
    assert not (tmp_path / "missing_access.sqlite3").exists()


def test_session_audit_export_json_csv_formula_safety_and_404(env):
    del env
    _, admin_tok = _seed_user(email="audit-admin@example.invalid", role="admin")
    with store.connection(write=True) as db:
        role = store.create_role(db, RoleInput(name="Backend Engineer", description="Desc", questions=["Q1"], policy="No external tools."))
        sess = store.create_session(db, SessionInput(candidate="Alice Audit", role=role["name"], role_id=role["id"], policy="No external tools.", consent=True))
        sid = sess["id"]
        ans = store.write_answer(db, sid, AnswerInput(question="Q1", answer="Sample answer text."))
        db.execute(
            "INSERT INTO answer_review_events(session_id, answer_id, role_id, reviewer_id, reviewer_email, previous_disposition, disposition, created_at) "
            "VALUES (?,?,?,?,?,?,?,?)",
            (sid, ans["id"], role["id"], "rev-1", "rev@example.invalid", "pending", "explained", "2099-01-01T10:01:00Z"),
        )
        db.execute(
            "INSERT INTO session_handoff_notes(id, session_id, author_email, category, body, created_at) VALUES (?,?,?,?,?,?)",
            (str(uuid4()), sid, "panel@example.invalid", "observation", "PRIVATE_HANDOFF_BODY", "2099-01-01T10:02:00Z"),
        )
        db.execute(
            "INSERT INTO note_exports(id, session_id, provider, remote_id, recipient, draft, state, created_at) VALUES (?,?,?,?,?,?,?,?)",
            (str(uuid4()), sid, "greenhouse", "gh-42", "recruiter", "PRIVATE_EXPORT_DRAFT", "sent", "2099-01-01T10:03:00Z"),
        )
        db.execute(
            "INSERT INTO session_scorecards(session_id, criterion_id, criterion_label, weight, rating, rationale, updated_by, updated_at) "
            "VALUES (?,?,?,?,?,?,?,?)",
            (sid, "=HYPERLINK(\"http://evil\",\"bad\")", "System Design", 3, 4, "PRIVATE_SCORECARD_RATIONALE", "=CMD()", "2099-01-01T10:04:00Z"),
        )

    with TestClient(_build_app(), base_url="http://127.0.0.1", cookies={"ic_access": admin_tok}) as client:
        assert client.get(f"/api/admin/compliance/sessions/{uuid4()}/audit").status_code == 404
        r_json = client.get(f"/api/admin/compliance/sessions/{sid}/audit?format=json")
        assert r_json.status_code == 200
        assert r_json.headers["cache-control"] == "no-store"
        payload = r_json.json()
        assert payload["counts"] == {"review_events": 1, "handoff_notes": 1, "note_exports": 1, "scorecards": 1, "timeline_events": 5}
        assert [ev["event_type"] for ev in payload["timeline"]] == [
            "session.created", "answer.review", "handoff_note.created", "note.export", "scorecard.updated",
        ]
        for secret_text in ("PRIVATE_HANDOFF_BODY", "PRIVATE_EXPORT_DRAFT", "PRIVATE_SCORECARD_RATIONALE"):
            assert secret_text not in r_json.text

        r_csv = client.get(f"/api/admin/compliance/sessions/{sid}/audit?format=csv")
        assert r_csv.status_code == 200
        assert r_csv.headers["cache-control"] == "no-store"
        assert r_csv.text.startswith("\ufeffsession_id,timestamp,event_type,actor,target_id,detail")
        assert "'=CMD()" in r_csv.text
        assert "'=HYPERLINK" in r_csv.text


def test_compliance_headers_check(env):
    del env
    _, admin_tok = _seed_user(email="hdr-admin@example.invalid", role="admin")
    with TestClient(_build_app(), base_url="http://127.0.0.1", cookies={"ic_access": admin_tok}) as client:
        r_ok = client.get("/api/admin/compliance/headers-check")
        assert r_ok.status_code == 200
        assert r_ok.headers["cache-control"] == "no-store"
        data = r_ok.json()
        assert data["ok"] is True
        ids = {item["id"]: item["status"] for item in data["checks"]}
        assert ids["host_header"] == "pass"
        assert ids["duplicate_proxy_headers"] == "pass"
        assert ids["security_headers_middleware"] == "pass"
        assert client.get("/api/admin/compliance/headers-check", headers={"X-Forwarded-Host": "127.0.0.1:3000, evil.example"}).status_code == 400


def test_verify_edge_security_cli_asgi_and_base_url(env):
    del env
    current = verify_edge_security.run_asgi(main.app)
    by_id = {c["id"]: c for c in current["checks"]}
    for cid in ("cors_preflight_cross_origin", "host_injection", "origin_spoofing", "csrf_header_enforcement",
                "duplicate_proxy_header_comma", "mandatory_security_headers"):
        assert by_id[cid]["ok"] is True, by_id[cid]

    class StrictM21W3Wrapper:
        def __init__(self, inner):
            self.inner = inner

        async def __call__(self, scope, receive, send):
            if scope["type"] == "http":
                h = Headers(scope=scope)
                if len(h.getlist("x-forwarded-host")) > 1 or len(h.getlist("x-interviewcheck-client-ip")) > 1:
                    await JSONResponse({"detail": "Duplicate proxy header."}, status_code=400)(scope, receive, send)
                    return
                if scope["method"] == "OPTIONS" and h.get("access-control-request-method"):
                    await JSONResponse({"detail": "Preflight rejected."}, status_code=403)(scope, receive, send)
                    return
            await self.inner(scope, receive, send)

    strict_report = verify_edge_security.run_asgi(StrictM21W3Wrapper(main.app))
    assert strict_report["ok"] is True
    assert all(c["ok"] for c in strict_report["checks"])

    async def permissive_broken_app(scope, receive, send):
        await send({
            "type": "http.response.start", "status": 200,
            "headers": [(b"content-type", b"application/json"), (b"access-control-allow-origin", b"*")],
        })
        await send({"type": "http.response.body", "body": b'{"ok":true}'})

    broken_report = verify_edge_security.run_asgi(permissive_broken_app)
    assert broken_report["ok"] is False

    class _EdgeHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            return

        def _drain_body(self):
            length = int(self.headers.get("Content-Length") or "0")
            if length > 0:
                self.rfile.read(length)

        def _send(self, code: int, body: bytes):
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Permissions-Policy", "camera=()")
            self.send_header("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(body)

        def do_OPTIONS(self):
            self._drain_body()
            self._send(403, b'{"detail":"Preflight denied"}')

        def do_GET(self):
            host = self.headers.get("Host", "")
            if not host.startswith(("127.0.0.1", "localhost")) or len(self.headers.get_all("X-Forwarded-Host") or []) > 1 or "," in (self.headers.get("X-Forwarded-Host") or "") or len(self.headers.get_all("X-InterviewCheck-Client-IP") or []) > 1:
                self._send(400, b'{"detail":"Bad proxy or host header"}')
                return
            self._send(200, b'{"ok":true}')

        def do_POST(self):
            self._drain_body()
            if self.headers.get("Origin") not in (None, f"http://{self.headers.get('Host')}") or self.headers.get("X-InterviewCheck") != "1":
                self._send(403, b'{"detail":"Forbidden"}')
                return
            self._send(201, b'{}')

    server = ThreadingHTTPServer(("127.0.0.1", 0), _EdgeHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        rc = verify_edge_security.main(["--base-url", f"http://127.0.0.1:{server.server_port}", "--json"])
        assert rc == 0
    finally:
        server.shutdown()
        server.server_close()
