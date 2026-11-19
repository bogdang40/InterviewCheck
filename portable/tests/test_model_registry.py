import hashlib
import json
from uuid import uuid4

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest

from api import model_registry, model_resolver, secret_box, store
from api.main import app


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "fixture-registry-key")
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def _insert_model(*, slug, capability="reference", provider="openai", model_id="gpt-4o", is_default=False, enabled=True, secret="sk-fixture-secret-9999"):
    uid = str(uuid4())
    enc = secret_box.encrypt_secret(secret, aad=uid) if secret else None
    hint = secret_box.mask_key_hint(secret) if secret else None
    with store.connection(write=True) as db:
        return model_registry.create_model(
            db,
            model_uuid=uid,
            slug=slug,
            display_name=f"Model {slug}",
            provider=provider,
            capability=capability,
            model_id=model_id,
            endpoint=None,
            api_version=None,
            parameters={"fallback_priority": 100},
            encrypted_api_key=enc,
            key_hint=hint,
            enabled=enabled,
            is_default=is_default,
        )


def test_schema_created_on_initialize(client):
    with store.connection() as db:
        tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert {"connected_models", "model_audit"}.issubset(tables)


def test_default_switching_duplicate_slug_and_secret_omission(client):
    first = _insert_model(slug="openai-primary", capability="reference", is_default=True, secret="sk-first-secret-1111")
    other_cap = _insert_model(slug="deepgram-tx", capability="transcription", provider="deepgram", model_id="nova-3", is_default=True, secret="dg-secret-2222")
    second = _insert_model(slug="openai-secondary", capability="reference", is_default=True, secret="sk-second-secret-3333")

    assert "encrypted_api_key" not in first and first["hasKey"] is True and first["key_hint"] == "...1111"
    with store.connection() as db:
        rows = {r["id"]: r for r in model_registry.list_models(db)}
    assert rows[first["id"]]["is_default"] is False
    assert rows[second["id"]]["is_default"] is True
    assert rows[other_cap["id"]]["is_default"] is True

    with pytest.raises(HTTPException) as exc:
        _insert_model(slug="openai-primary", capability="reference")
    assert exc.value.status_code == 409

    resolved = model_resolver.resolve_capability("reference")
    assert resolved is not None
    assert resolved.id == second["id"]
    assert resolved.api_key == "sk-second-secret-3333"
    assert "sk-second-secret-3333" not in repr(resolved)


def test_backup_export_and_restore_isolate_connected_models(client):
    secret = "sk-never-export-this-secret-8888"
    created = _insert_model(slug="isolated-model", capability="reference", is_default=True, secret=secret)

    role = client.post("/api/roles", json={"name": "SRE", "description": "Keep systems up", "questions": ["Q1"]}).json()
    export_resp = client.get("/api/backups/workspace")
    assert export_resp.status_code == 200
    assert secret not in export_resp.text
    assert "connected_models" not in export_resp.text
    assert "model_audit" not in export_resp.text
    assert "encrypted_api_key" not in export_resp.text
    exported = export_resp.json()
    assert set(exported.keys()) == {"format", "version", "roles", "sessions"}

    injected = json.dumps({**exported, "models": [created]}).encode("utf-8")
    assert client.post("/api/backups/preview", content=injected).status_code == 422

    # Delete the role and restore from the clean backup; connected_models must remain intact.
    with store.connection(write=True) as db:
        db.execute("DELETE FROM roles WHERE id=?", (role["id"],))
    raw_backup = export_resp.content
    digest = hashlib.sha256(raw_backup).hexdigest()
    assert client.post("/api/backups/preview", content=raw_backup).status_code == 200
    assert client.post("/api/backups/restore", content=raw_backup, headers={"x-backup-preview": digest}).status_code == 200

    with store.connection() as db:
        models = model_registry.list_models(db)
        roles = db.execute("SELECT id FROM roles").fetchall()
    assert [m["id"] for m in models] == [created["id"]]
    assert [r["id"] for r in roles] == [role["id"]]
