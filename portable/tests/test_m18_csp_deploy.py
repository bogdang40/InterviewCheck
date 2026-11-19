"""Tests for M18-W3: CSP violation reporting, fallback audit hash chain, and deploy validator."""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import account_db, model_registry, rate_limit, store
from api.main import app

ROOT = Path(__file__).resolve().parents[2]
DEPLOY_SCRIPT = ROOT / "scripts" / "check_deploy_config.py"


def _load_deploy_mod():
    spec = importlib.util.spec_from_file_location("check_deploy_config", DEPLOY_SCRIPT)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def _seed_user(role: str = "admin", email: str = "admin@example.invalid") -> tuple[str, str]:
    uid = str(uuid4())
    with account_db.connection(write=True) as db:
        ts = account_db.now()
        db.execute(
            "INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,0,?,?)",
            (uid, email, account_db.DECOY, role, ts, ts),
        )
        tok = account_db.issue(db, uid, "pytest")
    return uid, tok


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "m18-csp-deploy-secret")
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL",
                "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_PUBLIC_ORIGIN", "INTERVIEWCHECK_PRODUCTION"):
        monkeypatch.delenv(key, raising=False)
    with TestClient(app, base_url="http://127.0.0.1") as client:
        yield client


def test_csp_report_boundary_sanitization_and_admin_lifecycle(env):
    # Browser-originated POST /api/csp-report succeeds WITHOUT X-InterviewCheck: 1
    payload = {
        "csp-report": {
            "document-uri": "https://app.example.test/interviews/review?token=secret123#frag",
            "violated-directive": "script-src-elem",
            "effective-directive": "script-src",
            "blocked-uri": "https://cdn.evil.test/evil.js?cb=999#hash",
            "source-file": "blob:https://app.example.test/abc-1?x=1#y",
            "line-number": 42,
            "column-number": 7,
            "disposition": "enforce",
            "status-code": 200,
        }
    }
    res = env.post(
        "/api/csp-report",
        content=json.dumps(payload),
        headers={"Content-Type": "application/csp-report", "Origin": "http://127.0.0.1"},
    )
    assert res.status_code == 204

    # application/reports+json format + data: payload truncation
    batch = [
        {
            "type": "csp-violation",
            "url": "http://127.0.0.1/admin?session=abc#tab",
            "body": {
                "effectiveDirective": "img-src",
                "blockedURL": "data:image/png;base64,SECRETBASE64DATA",
                "sourceFile": "/app.js?v=1#top",
                "lineNumber": 9,
                "columnNumber": 2,
                "disposition": "report",
                "statusCode": 200,
            },
        },
        {"type": "deprecation", "url": "http://127.0.0.1/", "body": {"id": "ignored"}},
    ]
    res2 = env.post(
        "/api/csp-report",
        content=json.dumps(batch),
        headers={"Content-Type": "application/reports+json; charset=utf-8"},
    )
    assert res2.status_code == 204

    # Host / Origin boundary and 8192-byte cap still enforced
    assert env.post("/api/csp-report", content=json.dumps(payload), headers={"Content-Type": "application/csp-report", "Host": "evil.example"}).status_code == 400
    assert env.post("/api/csp-report", content=json.dumps(payload), headers={"Content-Type": "application/csp-report", "Origin": "https://evil.example"}).status_code == 403
    oversized = json.dumps({"csp-report": {"document-uri": "http://127.0.0.1/", "blocked-uri": "x" * 8200}})
    assert len(oversized.encode("utf-8")) > 8192
    assert env.post("/api/csp-report", content=oversized, headers={"Content-Type": "application/csp-report"}).status_code == 413
    assert env.post("/api/csp-report", content=json.dumps(payload), headers={"Content-Type": "application/json"}).status_code == 415
    assert env.post("/api/csp-report", content=b"{bad", headers={"Content-Type": "application/csp-report"}).status_code == 400

    # Admin auth enforced on GET & DELETE /api/admin/security/csp-reports
    assert env.get("/api/admin/security/csp-reports").status_code == 401
    _, user_tok = _seed_user("user", "user@example.invalid")
    env.cookies.set("ic_access", user_tok)
    assert env.get("/api/admin/security/csp-reports").status_code == 403
    assert env.delete("/api/admin/security/csp-reports", headers={"X-InterviewCheck": "1"}).status_code == 403

    _, admin_tok = _seed_user("admin", "admin@example.invalid")
    env.cookies.set("ic_access", admin_tok)
    listed = env.get("/api/admin/security/csp-reports")
    assert listed.status_code == 200
    assert listed.headers["cache-control"] == "no-store"
    body = listed.json()
    assert body["total"] == 2
    newest, oldest = body["reports"][0], body["reports"][1]
    assert newest["document_uri"] == "http://127.0.0.1/admin"
    assert newest["blocked_uri"] == "data:image/png"
    assert newest["source_file"] == "/app.js"
    assert oldest["document_uri"] == "https://app.example.test/interviews/review"
    assert oldest["blocked_uri"] == "https://cdn.evil.test/evil.js"
    assert oldest["source_file"] == "blob:https://app.example.test/abc-1"
    assert "secret123" not in listed.text and "SECRETBASE64DATA" not in listed.text

    cleared = env.delete("/api/admin/security/csp-reports", headers={"X-InterviewCheck": "1"})
    assert cleared.status_code == 200 and cleared.json() == {"ok": True, "cleared": 2}
    assert env.get("/api/admin/security/csp-reports").json()["total"] == 0


def test_csp_ring_buffer_rate_limit_and_html_report_uri(env, tmp_path):
    # Ring buffer caps stored rows at 500
    with store.connection(write=True) as db:
        for i in range(505):
            db.execute(
                """INSERT INTO csp_violations(
                    received_at, document_uri, violated_directive, effective_directive, blocked_uri, source_file
                ) VALUES (?,?,?,?,?,?)""",
                (store.timestamp(), f"http://127.0.0.1/p{i}", "script-src", "script-src", "inline", ""),
            )
    res = env.post(
        "/api/csp-report",
        content=json.dumps({"csp-report": {"document-uri": "http://127.0.0.1/last", "violated-directive": "script-src"}}),
        headers={"Content-Type": "application/csp-report"},
    )
    assert res.status_code == 204
    _, admin_tok = _seed_user("admin", "ring@example.invalid")
    env.cookies.set("ic_access", admin_tok)
    reports = env.get("/api/admin/security/csp-reports?limit=500").json()
    assert reports["total"] == 500
    assert reports["reports"][0]["document_uri"] == "http://127.0.0.1/last"
    assert all(r["document_uri"] != "http://127.0.0.1/p0" for r in reports["reports"])

    # Print HTML CSP includes report-uri /api/csp-report; API CSP does not
    created = env.post(
        "/api/sessions",
        json={"candidate": "Ada", "role": "Staff", "policy": "None", "consent": True},
        headers={"X-InterviewCheck": "1"},
    )
    assert created.status_code == 201
    sid = created.json()["id"]
    printed = env.get(f"/api/sessions/{sid}/print")
    assert printed.status_code == 200
    assert "; report-uri /api/csp-report" in printed.headers["content-security-policy"]
    assert "report-uri" not in env.get("/api/health").headers["content-security-policy"]

    # Rate limit: 60/min/client on POST /api/csp-report (already sent 1 above)
    rate_limit.CSP_REPORT.reset()
    for _ in range(60):
        ok = env.post(
            "/api/csp-report",
            content=json.dumps({"csp-report": {"document-uri": "http://127.0.0.1/", "violated-directive": "script-src"}}),
            headers={"Content-Type": "application/csp-report"},
        )
        assert ok.status_code == 204
    blocked = env.post(
        "/api/csp-report",
        content=json.dumps({"csp-report": {"document-uri": "http://127.0.0.1/", "violated-directive": "script-src"}}),
        headers={"Content-Type": "application/csp-report"},
    )
    assert blocked.status_code == 429 and int(blocked.headers["retry-after"]) >= 1


def test_fallback_model_audit_hash_chain_and_tamper_detection(env):
    # Auth gating on /api/admin/audit/verify
    assert env.get("/api/admin/audit/verify").status_code == 401
    _, user_tok = _seed_user("user", "u@example.invalid")
    env.cookies.set("ic_access", user_tok)
    assert env.get("/api/admin/audit/verify").status_code == 403

    _, admin_tok = _seed_user("admin", "a@example.invalid")
    env.cookies.set("ic_access", admin_tok)

    # Seed legacy unchained row followed by chained rows
    with store.connection(write=True) as db:
        db.execute(
            "INSERT INTO model_audit(at, actor_user_id, action, model_id, details, prev_hash, entry_hash) VALUES (?,?,?,?,?,NULL,NULL)",
            ("2026-01-01T00:00:00.000Z", "legacy-admin", "legacy.action", "m-legacy", '{"v":1}'),
        )
        model_registry.write_fallback_audit(
            db, actor_user_id="admin-1", action="admin.model.create", model_uuid="m-1", details={"slug": "one"}
        )
        model_registry.write_fallback_audit(
            db, actor_user_id=None, action="admin.model.toggle", model_uuid="m-1", details=None
        )
        rows = db.execute("SELECT * FROM model_audit ORDER BY id ASC").fetchall()

    # Verify canonical SHA-256 chain formula explicitly
    first_chained, second_chained = rows[1], rows[2]
    assert first_chained["prev_hash"] is None
    expected_1 = hashlib.sha256(
        f"GENESIS|{first_chained['at']}|admin-1|admin.model.create|m-1|{first_chained['details']}".encode("utf-8")
    ).hexdigest()
    assert first_chained["entry_hash"] == expected_1
    assert second_chained["prev_hash"] == expected_1
    expected_2 = hashlib.sha256(
        f"{expected_1}|{second_chained['at']}||admin.model.toggle|m-1|".encode("utf-8")
    ).hexdigest()
    assert second_chained["entry_hash"] == expected_2

    verify_ok = env.get("/api/admin/audit/verify")
    assert verify_ok.status_code == 200
    assert verify_ok.headers["cache-control"] == "no-store"
    assert verify_ok.json() == {
        "ok": True,
        "verifiedCount": 2,
        "legacyUnchainedCount": 1,
        "firstBrokenId": None,
        "headHash": expected_2,
    }

    # Tamper with chained row details -> verification fails at that row's id
    with store.connection(write=True) as db:
        db.execute("UPDATE model_audit SET details=? WHERE id=?", ('{"slug":"tampered"}', first_chained["id"]))
    tampered = env.get("/api/admin/audit/verify").json()
    assert tampered["ok"] is False
    assert tampered["firstBrokenId"] == first_chained["id"]


def test_deploy_config_validator_cli(tmp_path):
    mod = _load_deploy_mod()
    ok_report = mod.run_checks(ROOT, strict_prod=False)
    assert ok_report["ok"] is True
    assert ok_report["errors"] == []

    # Invalid Caddyfile + missing Dockerfile + strict-prod validation
    bad_deploy = tmp_path / "deploy"
    bad_deploy.mkdir()
    (bad_deploy / "Caddyfile").write_text("{$SITE_ADDRESS} {\n reverse_proxy 127.0.0.1:3000\n}\n", encoding="utf-8")
    (bad_deploy / "compose.yml").write_text("services:\n  app:\n    network_mode: bridge\n", encoding="utf-8")
    (bad_deploy / "vm-rollout.sh").write_text("#!/bin/bash\necho hi\n", encoding="utf-8")

    bad_report = mod.run_checks(
        tmp_path,
        strict_prod=True,
        env={
            "INTERVIEWCHECK_PUBLIC_ORIGIN": "http://127.0.0.1:3000",
            "INTERVIEWCHECK_ACCESS_MODE": "embedded",
            "INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP": "0",
        },
    )
    assert bad_report["ok"] is False
    assert any("caddyfile.max_size" in e for e in bad_report["errors"])
    assert any("dockerfile.exists" in e for e in bad_report["errors"])
    assert any("prod.public_origin" in e for e in bad_report["errors"])
    assert any("prod.trust_proxy_client_ip" in e for e in bad_report["errors"])

    strict_ok = mod.run_checks(
        ROOT,
        strict_prod=True,
        env={
            "INTERVIEWCHECK_PUBLIC_ORIGIN": "https://review.example.com",
            "INTERVIEWCHECK_ACCESS_MODE": "embedded",
            "INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP": "1",
            "ADMIN_EMAILS": "ops@example.com",
            "INTERVIEWCHECK_SIGNUP_SECRET": "long-random-secret",
        },
    )
    assert strict_ok["ok"] is True
    assert mod.main(["--json", "--root", str(ROOT)]) == 0
    assert mod.main(["--json", "--root", str(tmp_path)]) == 1

    env_file = tmp_path / "app.env"
    env_file.write_text(
        "INTERVIEWCHECK_PUBLIC_ORIGIN=https://review.example.com\n"
        "INTERVIEWCHECK_ACCESS_MODE=embedded\n"
        "INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP=1\n"
        "INTERVIEWCHECK_OPERATOR_EMAIL=ops@example.com\n"
        "ADMIN_BOOTSTRAP_SECRET=bootstrap-secret\n",
        encoding="utf-8",
    )
    proc = subprocess.run(
        [sys.executable, str(DEPLOY_SCRIPT), "--json", "--strict-prod", "--env-file", str(env_file)],
        capture_output=True, text=True, check=False,
    )
    assert proc.returncode == 0
    assert json.loads(proc.stdout)["ok"] is True

    # Static HTML document CSP also includes report-uri /api/csp-report while static asset CSP does not
    from api import security_headers
    from starlette.datastructures import Headers

    static_dir = tmp_path / "out"
    static_dir.mkdir()
    (static_dir / "index.html").write_text("<html></html>", encoding="utf-8")
    mw = security_headers.SecurityHeadersMiddleware(lambda *a: None, static_dir=static_dir)
    html_csp = mw._csp_for("/", 200, "text/html", Headers({"host": "127.0.0.1:3000"}), "http")
    asset_csp = mw._csp_for("/app.js", 200, "application/javascript", Headers({"host": "127.0.0.1:3000"}), "http")
    assert html_csp.endswith("; report-uri /api/csp-report")
    assert asset_csp == security_headers._STATIC_ASSET_CSP


def test_sanitize_uri_strips_http_userinfo_and_handles_edge_cases():
    from api.csp_reports import sanitize_uri

    assert sanitize_uri("https://user:secretpass@app.example.test/p?q=1#f") == "https://app.example.test/p"
    assert sanitize_uri("https://user@app.example.test/") == "https://app.example.test/"
    assert sanitize_uri("http://user:pass@[::1]:8080/admin?x=1#y") == "http://[::1]:8080/admin"
    assert sanitize_uri("http://user:pass@[2001:db8::1]/") == "http://[2001:db8::1]/"
    assert sanitize_uri("https://user:pass@/path") == "https:///path"
    assert sanitize_uri("https://user:pass@app.example.test:notaport/p") == "https://app.example.test/p"
    assert sanitize_uri("https://user:pass@[::1/p?q=1") == "https://[::1/p"
    assert sanitize_uri("blob:https://user:pass@app.example.test/id?x=1") == "blob:https://app.example.test/id"
    assert sanitize_uri("blob:https://example.test/x", max_len=3) == "blob:"

