"""Tests for M8-W1: audit log filtering/export and backup integrity hardening."""
import csv
from datetime import datetime, timedelta, timezone
import hashlib
from io import StringIO
import json
from unittest.mock import AsyncMock
from urllib.parse import parse_qs, urlsplit
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import access, account_db, backup, store
from api.main import app


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    for key in (
        "INTERVIEWCHECK_ACCESS_MODE",
        "INTERVIEWCHECK_ACCESS_URL",
        "INTERVIEWCHECK_OPERATOR_EMAIL",
        "INTERVIEWCHECK_OPERATOR_ID",
        "INTERVIEWCHECK_PUBLIC_ORIGIN",
        "INTERVIEWCHECK_PRODUCTION",
        "INTERVIEWCHECK_SIGNUP_SECRET",
    ):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("ADMIN_EMAILS", "admin@example.invalid")
    monkeypatch.setenv("ADMIN_BOOTSTRAP_SECRET", "bootstrap-secret")
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        res = client.post(
            "/api/integrations/access/signup",
            json={
                "email": "admin@example.invalid",
                "password": "admin-password-123",
                "adminSecret": "bootstrap-secret",
            },
        )
        res.raise_for_status()
        yield client


def _seed_user(role: str = "user", disabled: bool = False) -> tuple[str, str]:
    uid = str(uuid4())
    with account_db.connection(write=True) as db:
        ts = account_db.now()
        db.execute(
            "INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,?,?,?)",
            (uid, f"{uid[:8]}@example.invalid", account_db.DECOY, role, 1 if disabled else 0, ts, ts),
        )
        tok = account_db.issue(db, uid, "pytest")
    return uid, tok


def _insert_audit(at_ms: int, action: str, actor: str | None, target: str | None, details: dict | str | None):
    with account_db.connection(write=True) as db:
        raw_details = json.dumps(details) if details is not None else None
        db.execute(
            "INSERT INTO audit_log(at,actor_user_id,action,target_user_id,details) VALUES (?,?,?,?,?)",
            (at_ms, actor, action, target, raw_details),
        )


def test_audit_export_requires_admin_auth(env):
    unauth = TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"})
    assert unauth.get("/api/integrations/admin/audit/export").status_code == 401
    _, member_tok = _seed_user(role="user")
    unauth.cookies.set(access.COOKIE, member_tok)
    assert unauth.get("/api/integrations/admin/audit/export").status_code == 403
    _, disabled_tok = _seed_user(role="admin", disabled=True)
    unauth.cookies.set(access.COOKIE, disabled_tok)
    assert unauth.get("/api/integrations/admin/audit/export").status_code == 401


def test_v1_audit_filtering_wildcards_dates_and_cursor_pagination(env):
    admin_tok = env.cookies[access.COOKIE]
    auth = {"Authorization": f"Bearer {admin_tok}"}
    actor_a = str(uuid4())
    actor_b = str(uuid4())
    base = datetime(2026, 11, 10, 12, 0, tzinfo=timezone.utc)
    ms = lambda dt: int(dt.timestamp() * 1000)

    _insert_audit(ms(base), "admin.model.create", actor_a, str(uuid4()), {"slug": "alpha_100%"})
    _insert_audit(ms(base + timedelta(minutes=1)), "admin.model.probe", actor_b, str(uuid4()), {"slug": "beta"})
    _insert_audit(ms(base + timedelta(minutes=2)), "admin.update_user", actor_a, str(uuid4()), {"role": "admin"})
    _insert_audit(ms(base + timedelta(minutes=3)), "auth.login", actor_b, actor_b, None)

    # Naive since/until rejected with 422
    assert env.get("/v1/admin/audit?since=2026-11-10T12:00:00", headers=auth).status_code == 422
    assert env.get("/v1/admin/audit?until=2026-11-10T12:00:00", headers=auth).status_code == 422

    # Literal % and _ in instr() must not behave as LIKE wildcards
    pct = env.get("/v1/admin/audit", params={"q": "100%"}, headers=auth).json()
    assert [e["action"] for e in pct["entries"]] == ["admin.model.create"]
    under = env.get("/v1/admin/audit", params={"q": "alpha_"}, headers=auth).json()
    assert [e["action"] for e in under["entries"]] == ["admin.model.create"]
    assert env.get("/v1/admin/audit", params={"q": "%"}, headers=auth).json()["entries"] == pct["entries"]

    # Substring action/actor vs dot-prefix action
    exact = env.get("/v1/admin/audit", params={"action": "admin.update_user"}, headers=auth).json()
    assert [e["action"] for e in exact["entries"]] == ["admin.update_user"]
    partial_action = env.get("/v1/admin/audit", params={"action": "admin.model"}, headers=auth).json()
    assert [e["action"] for e in partial_action["entries"]] == ["admin.model.probe", "admin.model.create"]
    prefix = env.get("/v1/admin/audit", params={"action": "admin.model."}, headers=auth).json()
    assert [e["action"] for e in prefix["entries"]] == ["admin.model.probe", "admin.model.create"]
    by_actor = env.get("/v1/admin/audit", params={"actor": actor_a.upper()}, headers=auth).json()
    assert len(by_actor["entries"]) == 2
    by_actor_prefix = env.get("/v1/admin/audit", params={"actor": actor_a[:8].upper()}, headers=auth).json()
    assert len(by_actor_prefix["entries"]) == 2

    # Timezone-aware since/until window
    window = env.get(
        "/v1/admin/audit",
        params={"since": (base + timedelta(minutes=1)).isoformat(), "until": (base + timedelta(minutes=2)).isoformat()},
        headers=auth,
    ).json()
    assert [e["action"] for e in window["entries"]] == ["admin.update_user", "admin.model.probe"]

    # Cursor pagination with limit=2 across all entries
    p1 = env.get("/v1/admin/audit", params={"limit": 2}, headers=auth).json()
    assert len(p1["entries"]) == 2 and p1["nextBeforeId"] == p1["entries"][-1]["id"]
    p2 = env.get("/v1/admin/audit", params={"limit": 2, "before_id": p1["nextBeforeId"]}, headers=auth).json()
    assert len(p2["entries"]) == 2 and p2["entries"][0]["id"] < p1["entries"][-1]["id"]
    p3 = env.get("/v1/admin/audit", params={"limit": 2, "before_id": p2["nextBeforeId"]}, headers=auth).json()
    assert p3["nextBeforeId"] is None
    seen_ids = [e["id"] for p in (p1, p2, p3) for e in p["entries"]]
    assert len(seen_ids) == len(set(seen_ids)) == 5


def test_integrations_audit_category_filtering_and_export(env, monkeypatch):
    actor = str(uuid4())
    now_ms = account_db.now()
    _insert_audit(now_ms + 10, "admin.model.create", actor, str(uuid4()), {"slug": "gpt-4o"})
    _insert_audit(now_ms + 20, "=CMD|'/C calc'!A0", "+1+2", "@evil", "\t-formula")
    _insert_audit(now_ms + 30, "admin.update_user", actor, str(uuid4()), {"role": "admin"})

    models = env.get("/api/integrations/admin/audit", params={"category": "models"}).json()
    assert models["entries"] and all(e["action"].startswith("admin.model.") for e in models["entries"])

    accounts = env.get("/api/integrations/admin/audit", params={"category": "accounts"}).json()
    assert accounts["entries"] and all(not e["action"].startswith("admin.model.") for e in accounts["entries"])

    assert env.get("/api/integrations/admin/audit/export", params={"since": "2026-11-10T00:00:00"}).status_code == 422

    # CSV export includes UTF-8 BOM, no-store, attachment filename, and formula neutralization
    csv_resp = env.get("/api/integrations/admin/audit/export", params={"format": "csv", "q": "CMD"})
    assert csv_resp.status_code == 200
    assert csv_resp.headers["content-type"].startswith("text/csv; charset=utf-8")
    assert csv_resp.headers["content-disposition"] == 'attachment; filename="audit-log.csv"'
    assert "no-store" in csv_resp.headers["cache-control"]
    assert csv_resp.content.startswith(b"\xef\xbb\xbf")
    rows = list(csv.DictReader(StringIO(csv_resp.content.decode("utf-8-sig"))))
    assert len(rows) == 1
    assert rows[0]["action"] == "'=CMD|'/C calc'!A0"
    assert rows[0]["actorUserId"] == "'+1+2"
    assert rows[0]["targetUserId"] == "'@evil"
    assert rows[0]["details"] == "'\t-formula"

    # JSON export
    json_resp = env.get("/api/integrations/admin/audit/export", params={"format": "json", "category": "models"})
    assert json_resp.status_code == 200
    assert json_resp.headers["content-type"].startswith("application/json")
    assert json_resp.headers["content-disposition"] == 'attachment; filename="audit-log.json"'
    assert "no-store" in json_resp.headers["cache-control"]
    assert all(e["action"].startswith("admin.model.") for e in json_resp.json()["entries"])


def test_remote_mode_audit_cursor_uses_before_id_camel_case(env, monkeypatch):
    actor = str(uuid4())
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "remote")
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://accounts.example.invalid")

    remote_rows = [
        {"id": 60, "at": "2026-11-10T12:05:00Z", "action": "auth.login"},
        {"id": 50, "at": "2026-11-10T12:04:00Z", "action": "admin.update_user"},
        {"id": 40, "at": "2026-11-10T12:03:00Z", "action": "admin.model.create"},
        {"id": 30, "at": "2026-11-10T12:02:00Z", "action": "auth.login"},
        {"id": 20, "at": "2026-11-10T12:01:00Z", "action": "admin.model.probe"},
        {"id": 10, "at": "2026-11-10T12:00:00Z", "action": "auth.logout"},
    ]
    recorded_queries: list[dict[str, list[str]]] = []

    async def fake_upstream(path, method="GET", **kwargs):
        if path == "me":
            return {
                "user": {"id": actor, "email": "admin@example.invalid", "role": "admin", "disabled": False},
                "entitlement": {"active": True},
            }
        parsed = urlsplit(path)
        assert parsed.path == "admin/audit"
        qs = parse_qs(parsed.query)
        assert "before_id" not in qs, f"Remote mode must send beforeId, got {qs}"
        recorded_queries.append(qs)
        before_id = int(qs["beforeId"][0]) if "beforeId" in qs else None
        filtered = [r for r in remote_rows if before_id is None or r["id"] < before_id]
        # Force 2-row pages during category scans to exercise multi-page cursor loops.
        page_size = min(int(qs["limit"][0]), 2)
        page = filtered[:page_size]
        next_cursor = page[-1]["id"] if len(filtered) > page_size else None
        return {"entries": page, "nextBeforeId": next_cursor}

    monkeypatch.setattr(access, "upstream", AsyncMock(side_effect=fake_upstream))

    # 1. category="all" multi-page cursor pagination forwards beforeId= and avoids duplicates.
    p1 = env.get("/api/integrations/admin/audit", params={"category": "all", "limit": 2})
    assert p1.status_code == 200 and [e["id"] for e in p1.json()["entries"]] == [60, 50]
    p2 = env.get("/api/integrations/admin/audit", params={"category": "all", "limit": 2, "before_id": p1.json()["nextBeforeId"]})
    assert p2.status_code == 200 and [e["id"] for e in p2.json()["entries"]] == [40, 30]
    assert recorded_queries[1]["beforeId"] == ["50"]

    # 2. category="models" scan across 3 upstream pages forwards beforeId= without duplicating entries.
    recorded_queries.clear()
    models = env.get("/api/integrations/admin/audit", params={"category": "models", "limit": 10})
    assert models.status_code == 200
    model_ids = [e["id"] for e in models.json()["entries"]]
    assert model_ids == [40, 20]
    assert len(model_ids) == len(set(model_ids))
    assert models.json()["nextBeforeId"] is None
    assert [qs.get("beforeId") for qs in recorded_queries] == [None, ["50"], ["30"]]

    # 3. Export with category="accounts" and before_id cursor also forwards beforeId= cleanly.
    recorded_queries.clear()
    exported = env.get("/api/integrations/admin/audit/export", params={"format": "json", "category": "accounts", "before_id": 60})
    assert exported.status_code == 200
    assert [e["id"] for e in exported.json()["entries"]] == [50, 30, 10]
    assert [qs.get("beforeId") for qs in recorded_queries] == [["60"], ["40"], ["20"]]


@pytest.fixture
def backup_bundle(tmp_path, monkeypatch):
    src = tmp_path / "src.sqlite"
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(src))
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL"):
        monkeypatch.delenv(key, raising=False)
    phrase = "Measure insulation resistance across every winding terminal before testing."
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        role = client.post("/api/roles", json={"name": "Tech", "questions": ["Why?"]}).json()
        sid = client.post(
            "/api/sessions",
            json={"candidate": "Alice", "role": "Tech", "role_id": role["id"], "consent": True, "policy": "Strict"},
        ).json()["id"]
        client.post(
            f"/api/sessions/{sid}/answers",
            json={"question": "Q1?", "answer": phrase, "references": [{"label": "Doc", "text": phrase}]},
        ).raise_for_status()
        client.post(f"/api/sessions/{sid}/finish").raise_for_status()
        client.post(f"/api/sessions/{sid}/trash").raise_for_status()
        exported = client.get("/api/backups/workspace")
        exported.raise_for_status()
        dst = tmp_path / "dst.sqlite"
        store.initialize(dst)
        monkeypatch.setenv("INTERVIEWCHECK_DB", str(dst))
        yield client, exported


def test_backup_sha256_headers_and_foreign_key_check(backup_bundle, monkeypatch):
    client, exported = backup_bundle
    raw = exported.content
    expected_digest = hashlib.sha256(raw).hexdigest()
    assert exported.headers["x-backup-sha256"] == expected_digest

    # Malformed / mismatched X-Backup-SHA256 on preview and restore
    assert client.post("/api/backups/preview", content=raw, headers={"X-Backup-SHA256": "bad"}).status_code == 422
    assert client.post("/api/backups/preview", content=raw, headers={"X-Backup-SHA256": "0" * 64}).status_code == 409
    ok_preview = client.post("/api/backups/preview", content=raw, headers={"X-Backup-SHA256": expected_digest.upper()})
    assert ok_preview.status_code == 200
    fp = ok_preview.json()["fingerprint"]

    # X-Backup-Preview validation: malformed -> 422, wrong hex -> 409
    assert client.post("/api/backups/restore", content=raw, headers={"X-Backup-Preview": "Z" * 64}).status_code == 422
    assert client.post("/api/backups/restore", content=raw, headers={"X-Backup-Preview": expected_digest.upper()}).status_code == 422
    assert client.post("/api/backups/restore", content=raw, headers={"X-Backup-Preview": "b" * 64}).status_code == 409
    assert client.post("/api/backups/restore", content=raw, headers={"X-Backup-Preview": fp, "X-Backup-SHA256": "c" * 64}).status_code == 409

    # Post-restore PRAGMA foreign_key_check catches deferred FK violations and rolls back
    orig_restore = backup.restore_records

    def corrupt_restore(db, actions):
        orig_restore(db, actions)
        db.execute(
            "UPDATE answers SET parent_answer_id=? WHERE id=(SELECT id FROM answers LIMIT 1)",
            (str(uuid4()),),
        )

    monkeypatch.setattr(backup, "restore_records", corrupt_restore)
    failed = client.post("/api/backups/restore", content=raw, headers={"X-Backup-Preview": fp, "X-Backup-SHA256": expected_digest})
    assert failed.status_code == 422
    assert "referential integrity" in failed.json()["detail"].lower()
    assert client.get("/api/sessions").json() == []
    assert client.get("/api/roles").json() == []


def test_backup_schema_rejects_null_bytes_legacy_dos_bad_spans_and_chronology(backup_bundle):
    client, exported = backup_bundle
    base = json.loads(exported.content)

    # Null bytes in Role, Session, Answer, SavedDraft, and legacy
    for mutator in (
        lambda d: d["roles"][0].__setitem__("name", "Tech\x00"),
        lambda d: d["sessions"][0].__setitem__("candidate", "Alice\x00"),
        lambda d: d["sessions"][0]["answers"][0].__setitem__("note", "ok\x00bad"),
        lambda d: d["sessions"][0]["answers"][0].__setitem__("legacy", {"k\x00": 1}),
    ):
        doc = json.loads(json.dumps(base))
        mutator(doc)
        assert client.post("/api/backups/preview", json=doc).status_code == 422

    # SavedDraft null byte
    draft_doc = json.loads(json.dumps(base))
    draft_doc["sessions"][0]["ended_at"] = None
    draft_doc["sessions"][0]["draft"] = {
        "id": str(uuid4()),
        "question": "Q\x00",
        "answer": "Draft",
        "references": [],
        "revision": 1,
        "updated_at": draft_doc["sessions"][0]["created_at"],
    }
    assert client.post("/api/backups/preview", json=draft_doc).status_code == 422

    # Legacy nesting depth: 16 allowed, 17 rejected; node count > 2000 rejected
    def nested(depth: int) -> dict:
        node: dict = {"leaf": 1}
        for _ in range(depth - 1):
            node = {"n": node}
        return node

    ok_depth = json.loads(json.dumps(base))
    ok_depth["roles"][0]["legacy"] = nested(16)
    assert client.post("/api/backups/preview", json=ok_depth).status_code == 200

    bad_depth = json.loads(json.dumps(base))
    bad_depth["roles"][0]["legacy"] = nested(17)
    assert client.post("/api/backups/preview", json=bad_depth).status_code == 422

    too_many_nodes = json.loads(json.dumps(base))
    too_many_nodes["sessions"][0]["legacy"] = {f"k{i}": i for i in range(2001)}
    assert client.post("/api/backups/preview", json=too_many_nodes).status_code == 422

    # Passage span bounds
    for bad_span in ([-1, 5], [5, 5], [8, 3]):
        span_doc = json.loads(json.dumps(base))
        span_doc["sessions"][0]["answers"][0]["result"]["passages"][0]["answer_span"] = bad_span
        assert client.post("/api/backups/preview", json=span_doc).status_code == 422

    # Chronological validity (comparing true instants across offsets)
    bad_ended = json.loads(json.dumps(base))
    bad_ended["sessions"][0]["created_at"] = "2026-11-10T12:00:00+02:00"
    bad_ended["sessions"][0]["ended_at"] = "2026-11-10T09:59:59Z"
    assert client.post("/api/backups/preview", json=bad_ended).status_code == 422

    bad_trashed = json.loads(json.dumps(base))
    bad_trashed["sessions"][0]["created_at"] = "2026-11-10T12:00:00Z"
    bad_trashed["sessions"][0]["trashed_at"] = "2026-11-10T11:59:59Z"
    assert client.post("/api/backups/preview", json=bad_trashed).status_code == 422
