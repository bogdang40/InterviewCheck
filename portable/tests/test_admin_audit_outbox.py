"""Admin audit entries commit with the change they describe and are never lost."""
import sqlite3
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import access, account_db, main, model_admin, ssrf_guard, store

API_KEY = "sk-outbox-fixture-5678"
AUDIT = account_db.audit


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "fixture-outbox-secret-key")
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(ssrf_guard, "resolve_public_ips", lambda host, port=443: ["93.184.216.34"])
    with TestClient(main.app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        uid, ts = str(uuid4()), account_db.now()
        with account_db.connection(write=True) as db:
            db.execute("INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,0,?,?)",
                       (uid, "admin@example.invalid", account_db.DECOY, "admin", ts, ts))
            web.cookies.set(access.COOKIE, account_db.issue(db, uid, "pytest"))
        yield web


def model_payload(slug):
    return {"slug": slug, "display_name": "Outbox model", "provider": "openai", "capability": "reference",
            "model_id": "gpt-4o", "apiKey": API_KEY, "enabled": True, "is_default": False}


def access_entries(action_prefix="admin.model."):
    with account_db.connection() as db:
        return [row["action"] for row in db.execute(
            "SELECT action FROM audit_log WHERE action LIKE ? ORDER BY id", (action_prefix + "%",))]


def queued():
    with store.connection() as db:
        return [dict(row) for row in db.execute("SELECT * FROM admin_audit_outbox ORDER BY id")]


def busy_access_log(*_args, **_kwargs):
    raise sqlite3.OperationalError("database is locked")


def test_busy_access_database_keeps_the_change_and_queues_its_audit(env, monkeypatch, capsys):
    monkeypatch.setattr(account_db, "audit", busy_access_log)
    created = env.post("/api/admin/models", json=model_payload("outbox-one"))
    assert created.status_code == 201
    model_id = created.json()["model"]["id"]
    assert access_entries() == []
    pending, = queued()
    assert (pending["action"], pending["target"]) == ("admin.model.create", model_id)
    log = capsys.readouterr().err
    assert "[audit]" in log and "admin.model.create" in log and model_id in log and API_KEY not in log

    monkeypatch.setattr(account_db, "audit", AUDIT)
    toggled = env.post(f"/api/admin/models/{model_id}/toggle", json={"enabled": False})
    assert toggled.status_code == 200
    assert access_entries() == ["admin.model.create", "admin.model.toggle"]
    assert queued() == []
    with account_db.connection() as db:
        assert account_db.verify_audit_chain(db)["ok"] is True
        at = db.execute("SELECT at FROM audit_log WHERE action='admin.model.create'").fetchone()[0]
    assert at == pending["at"]


def test_startup_delivers_entries_left_by_an_interrupted_flush(env, monkeypatch):
    monkeypatch.setattr(account_db, "audit", busy_access_log)
    assert env.post("/api/admin/models", json=model_payload("outbox-two")).status_code == 201
    monkeypatch.setattr(account_db, "audit", AUDIT)
    main.open_databases()
    assert access_entries() == ["admin.model.create"] and queued() == []


def test_a_rolled_back_change_leaves_no_audit_entry(env):
    with pytest.raises(RuntimeError):
        with store.connection(write=True) as db:
            model_admin._record_audit(db, actor={"id": "a1"}, action="admin.model.delete", model_uuid="m1",
                                      details={"slug": "gone"}, post_commit=[])
            raise RuntimeError("change failed before commit")
    assert queued() == [] and access_entries() == []
