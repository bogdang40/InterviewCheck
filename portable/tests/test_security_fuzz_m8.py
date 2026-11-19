"""M8-W4 parametrized security fuzzing suite (XSS, CSV, SSRF, CSRF, SQLi, Backup)."""
import asyncio, csv, hashlib, html, json, re, socket
from io import StringIO
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import access, account_db, backup, exports, local_boundary, ssrf_guard, store
from api.main import app

PASSAGE = "Deterministic reference wording verified across multiple distributed replicas safely."
XSS_PAYLOADS = [
    "<script>alert(1)</script>",
    '<img src=x onerror="alert(1)">',
    "</title><svg/onload=alert(1)>",
    "</pre><iframe src=javascript:alert(1)>",
    "' onclick='alert(1)",
]
CSV_FORMULAS = [
    "=CMD|'/C calc'!A0", "+1+1", "-1+1", "@SUM(1,1)",
    "\t=1+1", "\r=1+1", "\n=1+1", "  =1+1", " \t+cmd", "\u00a0=1+1", "\r\n@SUM(1,1)",
]
SQLI_AND_WILDCARDS = [
    "' OR 1=1 --", "'; DROP TABLE audit_log; --", '" OR ""="',
    "' UNION SELECT 1,2,3,4,5,6 --", "%", "_", "%%", "____",
]
SSRF_URLS = [
    ("openai_compatible", "https://[::ffff:127.0.0.1]/v1"),
    ("openai_compatible", "https://[2002:7f00:0001::]/v1"),
    ("openai_compatible", "https://[2001:0::]/v1"),
    ("openai_compatible", "https://2130706433/v1"),
    ("openai_compatible", "https://0177.0.0.1/v1"),
    ("openai_compatible", "https://0x7f000001/v1"),
    ("openai_compatible", "https://0x7f.0x00.0x00.0x01/v1"),
    ("openai_compatible", "https://127.1/v1"),
    ("openai_compatible", "https://api.openai.com@127.0.0.1/v1"),
    ("openai_compatible", "https://api.example.com:8443/v1"),
    ("openai_compatible", "https://api.example.com:80/v1"),
    ("openai_compatible", "https://metadata.google.internal/v1"),
    ("openai_compatible", "https://evil.localhost/v1"),
    ("openai_compatible", "https://printer.local/v1"),
    ("openai_compatible", "https://169.254.169.254/latest/meta-data"),
    ("azure_openai", "https://openai.azure.com.evil.com"),
    ("azure_openai", "https://res.openai.azure.com.evil.com"),
    ("azure_openai", "https://openai.azure.com"),
    ("openai_compatible", "http://api.example.com/v1"),
]


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "m8-fuzz-secret-key")
    for k in ("INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_OPERATOR_ID",
              "INTERVIEWCHECK_PUBLIC_ORIGIN", "INTERVIEWCHECK_PRODUCTION", "INTERVIEWCHECK_SIGNUP_SECRET"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("ADMIN_EMAILS", "admin@example.invalid")
    monkeypatch.setenv("ADMIN_BOOTSTRAP_SECRET", "bootstrap-secret")
    monkeypatch.setattr(ssrf_guard.socket, "getaddrinfo", lambda h, p, type=0: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", p))])
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        client.post("/api/integrations/access/signup", json={
            "email": "admin@example.invalid", "password": "admin-password-123", "adminSecret": "bootstrap-secret",
        }).raise_for_status()
        yield client


def _create_session(client, *, candidate="Alice", role="Engineer", policy="Standard", q="Why?", a=PASSAGE, note="Note"):
    s = client.post("/api/sessions", json={
        "candidate": candidate, "role": role, "policy": policy, "consent": True,
        "permitted_sources": [{"label": f"Perm {candidate}", "text": policy}],
    })
    s.raise_for_status()
    sid = s.json()["id"]
    ans = client.post(f"/api/sessions/{sid}/answers", json={
        "question": q, "answer": a, "references": [{"label": f"Ref {candidate}", "text": PASSAGE}],
    })
    ans.raise_for_status()
    aid = ans.json()["id"]
    client.patch(f"/api/sessions/{sid}/answers/{aid}", json={"disposition": "explained", "note": note}).raise_for_status()
    return sid, aid


@pytest.mark.parametrize("payload", XSS_PAYLOADS)
def test_fuzz_xss_escaping_print_brief_and_csv(env, payload):
    sid, aid = _create_session(env, candidate=payload, role=payload, policy=payload, q=payload, a=f"{PASSAGE} {payload}", note=payload)
    printed = env.get(f"/api/sessions/{sid}/print")
    assert printed.status_code == 200
    assert printed.headers["x-content-type-options"] == "nosniff"
    csp = printed.headers["content-security-policy"]
    assert "script-src 'self'" in csp and "'unsafe-inline'" not in csp
    assert payload not in printed.text
    assert html.escape(payload, quote=True) in printed.text
    assert len(re.findall(r"<script\b", printed.text, re.I)) == 1

    brief = env.post(f"/api/sessions/{sid}/brief", json={"excerpt_ids": [aid], "note_ids": [aid]})
    assert brief.status_code == 200
    md = brief.json()["markdown"]
    assert all(line.startswith("    ") for line in md.splitlines() if payload in line)
    dl = env.post(f"/api/sessions/{sid}/brief/download", json={"excerpt_ids": [aid], "note_ids": [aid], "preview_sha256": brief.json()["preview_sha256"]})
    assert dl.status_code == 200 and dl.headers["x-content-type-options"] == "nosniff"
    assert "attachment" in dl.headers["content-disposition"]

    csv_resp = env.get("/api/exports/interviews.csv")
    assert csv_resp.status_code == 200 and csv_resp.headers["x-content-type-options"] == "nosniff"
    assert "attachment" in csv_resp.headers["content-disposition"]
    audit_csv = env.get("/api/integrations/admin/audit/export", params={"format": "csv"})
    assert audit_csv.status_code == 200 and audit_csv.headers["x-content-type-options"] == "nosniff"
    assert "default-src 'none'" in audit_csv.headers["content-security-policy"]


@pytest.mark.parametrize("payload", CSV_FORMULAS)
def test_fuzz_csv_formula_injection_exports_and_audit(env, payload):
    assert exports.csv_cell(payload) == "'" + payload
    assert exports.csv_cell("safe-value") == "safe-value"

    with account_db.connection(write=True) as db:
        db.execute(
            "INSERT INTO audit_log(at,actor_user_id,action,target_user_id,details) VALUES (?,?,?,?,?)",
            (account_db.now() + 100, payload, payload, payload, json.dumps(payload)),
        )
    resp = env.get("/api/integrations/admin/audit/export", params={"format": "csv", "limit": 200})
    assert resp.status_code == 200 and resp.content.startswith(b"\xef\xbb\xbf")
    rows = list(csv.DictReader(StringIO(resp.content.decode("utf-8-sig"))))
    match = next(r for r in rows if r["action"] == "'" + payload)
    assert match["actorUserId"] == "'" + payload and match["targetUserId"] == "'" + payload
    assert match["details"] == "'" + payload

    sid, _ = _create_session(env, candidate="SafeCand", note="SafeNote")
    with store.connection(write=True) as db:
        db.execute("UPDATE sessions SET candidate=?,role=?,policy=? WHERE id=?", (payload, payload, payload, sid))
        db.execute("UPDATE answers SET question=?,answer=?,note=? WHERE session_id=?", (payload, payload, payload, sid))
    csv_rows = list(csv.DictReader(StringIO(env.get("/api/exports/interviews.csv").content.decode("utf-8-sig"))))
    for col in ("Candidate", "Role", "Resource policy", "Question", "Answer", "Interviewer note"):
        assert csv_rows[0][col] == "'" + payload


@pytest.mark.parametrize("bad_ip", [
    "::ffff:127.0.0.1", "::ffff:7f00:1", "::ffff:169.254.169.254", "::ffff:10.0.0.1",
    "2002:7f00:0001::", "2002:a9fe:a9fe::", "2001:0::", "2001:0:4136:e378:8000:63bf:3fff:fdd2",
    "169.254.169.254", "127.0.0.1", "::1", "fe80::1%en0", "0.0.0.0", "100.64.0.1",
])
def test_fuzz_ssrf_disallowed_ips(bad_ip):
    assert ssrf_guard.is_disallowed_ip(bad_ip) is True


@pytest.mark.parametrize(("provider", "url"), SSRF_URLS)
def test_fuzz_ssrf_bypass_vectors_blocked_in_guard_and_model_admin(env, provider, url):
    with pytest.raises(ssrf_guard.SSRFValidationError):
        ssrf_guard.validate_endpoint_url(url, provider=provider, resolve_dns=False)

    payload = {
        "display_name": "SSRF Fuzz", "provider": provider, "capability": "reference",
        "model_id": "fuzz-model", "endpoint": url, "apiKey": "sk-fuzz-1234",
        **({"api_version": "2024-10-21"} if provider == "azure_openai" else {}),
    }
    res = env.post("/api/admin/models", json=payload)
    assert res.status_code in {400, 422}
    assert env.get("/api/admin/models").json()["models"] == []


def test_fuzz_ssrf_dns_rebinding_and_patch_rejected(env, monkeypatch):
    valid = env.post("/api/admin/models", json={
        "display_name": "Valid Compat", "provider": "openai_compatible", "capability": "reference",
        "model_id": "llama-3", "endpoint": "https://llm.example.com/v1",
    })
    assert valid.status_code == 201
    mid = valid.json()["model"]["id"]
    for url in ("https://169.254.169.254/latest", "https://api.openai.com@127.0.0.1/v1", "https://svc.internal/v1"):
        assert env.patch(f"/api/admin/models/{mid}", json={"endpoint": url}).status_code in {400, 422}
    monkeypatch.setattr(ssrf_guard.socket, "getaddrinfo", lambda h, p, type=0: [(socket.AF_INET6, socket.SOCK_STREAM, 6, "", ("::ffff:169.254.169.254", p))])
    assert env.patch(f"/api/admin/models/{mid}", json={"endpoint": "https://rebind.example.com/v1"}).status_code == 400
    assert env.get("/api/admin/models").json()["models"][0]["endpoint"] == "https://llm.example.com/v1"


@pytest.mark.parametrize("csrf", [None, "0", "true", "", "1, 1"])
def test_fuzz_csrf_header_enforced(env, csrf):
    headers = {} if csrf is None else {"X-InterviewCheck": csrf}
    with TestClient(app, base_url="http://127.0.0.1", headers=headers) as raw:
        raw.cookies.update(env.cookies)
        assert raw.post("/api/sessions", json={"candidate": "A", "role": "R", "policy": "P", "consent": True}).status_code == 403
        assert raw.post("/api/admin/models", json={"display_name": "M", "provider": "openai", "capability": "reference", "model_id": "gpt-4o", "apiKey": "sk-1"}).status_code == 403
        assert raw.post("/v1/auth/login", json={"email": "admin@example.invalid", "password": "admin-password-123"}).status_code == 403


@pytest.mark.parametrize("origin", ["https://evil.example", "http://127.0.0.1:8123", "http://localhost:9999", "null"])
def test_fuzz_cross_origin_rejected(env, origin):
    assert env.get("/api/sessions", headers={"Origin": origin}).status_code == 403
    assert env.post("/api/sessions", json={"candidate": "A", "role": "R", "consent": True}, headers={"Origin": origin}).status_code == 403


@pytest.mark.parametrize("bad_host", ["evil.example", "127.0.0.1@evil.example", "127.0.0.1, evil.example", "127.0.0.1/path", "10.0.0.1"])
def test_fuzz_bad_host_rejected(env, bad_host):
    assert env.get("/api/sessions", headers={"Host": bad_host}).status_code == 400
    assert env.get("/api/sessions", headers={"X-Forwarded-Host": bad_host}).status_code == 400


def test_fuzz_oversized_declared_and_chunked_bodies(env):
    assert env.post("/api/sessions", content=b"{}", headers={"Content-Length": str(2 * 1024**2 + 1)}).status_code == 413
    assert env.post("/v1/auth/login", content=b"{}", headers={"Content-Length": str(256 * 1024 + 1)}).status_code == 413
    assert env.post("/api/sessions", content=b"{}", headers={"Content-Length": "-5"}).status_code == 413
    assert env.post("/api/sessions", content=b"{}", headers={"Content-Length": "abc"}).status_code == 400

    async def stream_over_limit(path, chunks):
        sent, queue = [], list(chunks)
        mw = local_boundary.LocalBoundary(lambda s, r, se: se({"type": "http.response.start", "status": 200, "headers": []}))
        await mw({"type": "http", "method": "POST", "scheme": "http", "path": path, "headers": [(b"host", b"127.0.0.1"), (b"x-interviewcheck", b"1")]},
                 lambda: asyncio.sleep(0, result=queue.pop(0) if queue else {"type": "http.disconnect"}),
                 lambda msg: asyncio.sleep(0, result=sent.append(msg)))
        return sent[0]["status"]

    assert asyncio.run(stream_over_limit("/v1/auth/login", [{"type": "http.request", "body": b"a" * (200 * 1024), "more_body": True}, {"type": "http.request", "body": b"b" * (60 * 1024), "more_body": False}])) == 413


@pytest.mark.parametrize("probe", SQLI_AND_WILDCARDS)
def test_fuzz_sqli_and_like_wildcards_literal_matching(env, probe):
    tok = env.cookies[access.COOKIE]
    auth = {"Authorization": f"Bearer {tok}"}
    with account_db.connection(write=True) as db:
        ts = account_db.now()
        db.execute("INSERT INTO audit_log(at,actor_user_id,action,target_user_id,details) VALUES (?,?,?,?,?)", (ts + 1, "actor_x", "admin.model.create", "t1", json.dumps({"slug": "alpha_100%"})))
        db.execute("INSERT INTO audit_log(at,actor_user_id,action,target_user_id,details) VALUES (?,?,?,?,?)", (ts + 2, "actory", "auth.login", "t2", json.dumps({"slug": "beta"})))
        db.execute("INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,0,?,?)", (str(uuid4()), "user_100%@example.invalid", account_db.DECOY, "user", ts, ts))
    _create_session(env, candidate="Alice_100%", role="Eng")
    _create_session(env, candidate="Bob", role="SRE")

    v1_audit = env.get("/v1/admin/audit", params={"q": probe}, headers=auth)
    api_audit = env.get("/api/integrations/admin/audit", params={"q": probe})
    users = env.get("/v1/admin/users", params={"q": probe}, headers=auth)
    api_users = env.get("/api/integrations/admin/users", params={"q": probe})
    feed = env.get("/api/interviews/feed", params={"q": probe})
    search = env.post("/api/search", json={"query": probe})
    for resp in (v1_audit, api_audit, users, api_users, feed, search):
        assert resp.status_code == 200

    if probe in {"%", "_"}:
        assert [e["action"] for e in v1_audit.json()["entries"]] == ["admin.model.create"]
        assert [e["action"] for e in api_audit.json()["entries"]] == ["admin.model.create"]
        assert [u["user"]["email"] for u in users.json()["users"]] == ["user_100%@example.invalid"]
        assert [u["user"]["email"] for u in api_users.json()["users"]] == ["user_100%@example.invalid"]
        assert [i["candidate"] for i in feed.json()["items"]] == ["Alice_100%"]
        assert [i["label"] for i in search.json()["items"]] == ["Alice_100%"]
    else:
        assert v1_audit.json()["entries"] == [] and api_audit.json()["entries"] == []
        assert users.json()["users"] == [] and api_users.json()["users"] == [] and feed.json()["items"] == [] and search.json()["items"] == []

    assert env.get("/v1/admin/audit", params={"action": probe}, headers=auth).json()["entries"] == []
    expected_actors = ["actor_x"] if probe == "_" else []
    actor_entries = env.get("/v1/admin/audit", params={"actor": probe}, headers=auth).json()["entries"]
    assert [e["actorUserId"] for e in actor_entries] == expected_actors


@pytest.fixture
def backup_doc(env, tmp_path, monkeypatch):
    role = env.post("/api/roles", json={"name": "Tech", "questions": ["Why?"]}).json()
    sid = env.post("/api/sessions", json={"candidate": "Alice", "role": "Tech", "role_id": role["id"], "policy": "Strict", "consent": True}).json()["id"]
    env.post(f"/api/sessions/{sid}/answers", json={"question": "Q1?", "answer": PASSAGE, "references": [{"label": "Doc", "text": PASSAGE}]}).raise_for_status()
    exported = env.get("/api/backups/workspace")
    exported.raise_for_status()
    dst = tmp_path / "restore.sqlite3"
    store.initialize(dst)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(dst))
    return exported.content, json.loads(exported.content)


@pytest.mark.parametrize(("hdr_sha", "hdr_prev", "expected_status"), [
    ("bad-sha", None, 422), ("z" * 64, None, 422), ("0" * 64, None, 409),
    (None, "BAD" + "a" * 61, 422), (None, "a" * 63, 422), (None, "f" * 64, 409),
])
def test_fuzz_backup_tampered_integrity_headers(env, backup_doc, hdr_sha, hdr_prev, expected_status):
    raw, _ = backup_doc
    if hdr_sha is not None:
        assert env.post("/api/backups/preview", content=raw, headers={"X-Backup-SHA256": hdr_sha}).status_code == expected_status
    if hdr_prev is not None:
        assert env.post("/api/backups/restore", content=raw, headers={"X-Backup-Preview": hdr_prev}).status_code == expected_status


def test_fuzz_backup_malicious_payloads_and_fk_tampering(env, backup_doc, monkeypatch):
    raw, base = backup_doc
    nested_dict = {"leaf": 1}
    nested_list: object = ["leaf"]
    for _ in range(16):
        nested_dict = {"n": nested_dict}
        nested_list = [nested_list]

    mutators = [
        lambda d: d["roles"][0].__setitem__("name", "Tech\x00"),
        lambda d: d["roles"][0].__setitem__("questions", ["Why?\x00"]),
        lambda d: d["sessions"][0].__setitem__("candidate", "Alice\x00"),
        lambda d: d["sessions"][0]["answers"][0].__setitem__("answer", "A\x00"),
        lambda d: d["sessions"][0]["answers"][0].__setitem__("note", "N\x00"),
        lambda d: d["sessions"][0]["answers"][0]["references"][0].__setitem__("text", "R\x00"),
        lambda d: d["roles"][0].__setitem__("legacy", {"k\x00": 1}),
        lambda d: d["sessions"][0].__setitem__("legacy", {"arr": ["ok", "bad\x00"]}),
        lambda d: d["roles"][0].__setitem__("legacy", nested_dict),
        lambda d: d["roles"][0].__setitem__("legacy", {"deep": nested_list}),
        lambda d: d["sessions"][0].__setitem__("ended_at", "2020-01-01T00:00:00Z"),
        lambda d: d["sessions"][0].__setitem__("trashed_at", "2020-01-01T00:00:00Z"),
        lambda d: d["sessions"][0].__setitem__("role_id", str(uuid4())),
        lambda d: d["sessions"][0]["answers"][0].__setitem__("parent_answer_id", str(uuid4())),
        lambda d: d["sessions"][0]["answers"][0].__setitem__("parent_answer_id", d["sessions"][0]["answers"][0]["id"]),
    ]
    for mutate in mutators:
        doc = json.loads(json.dumps(base))
        mutate(doc)
        assert env.post("/api/backups/preview", json=doc).status_code == 422

    fp = hashlib.sha256(raw).hexdigest()
    orig_restore = backup.restore_records

    def tamper_fk(db, actions):
        orig_restore(db, actions)
        db.execute("UPDATE answers SET parent_answer_id=?", (str(uuid4()),))

    monkeypatch.setattr(backup, "restore_records", tamper_fk)
    res = env.post("/api/backups/restore", content=raw, headers={"X-Backup-Preview": fp, "X-Backup-SHA256": fp})
    assert res.status_code == 422 and "referential integrity" in res.json()["detail"].lower()
    assert env.get("/api/sessions").json() == [] and env.get("/api/roles").json() == []
