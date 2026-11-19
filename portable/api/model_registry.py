"""Persistent SQLite storage for connected AI and speech models."""
import json
import re
import sqlite3
from typing import Any
from uuid import uuid4

from fastapi import HTTPException

from . import store
from .error_sanitizer import sanitize_error_text

PROVIDERS = ("openai", "anthropic", "azure_openai", "deepgram", "openai_compatible")
CAPABILITIES = ("reference", "question_planning", "transcription", "embedding", "judge")
STATUSES = ("connected", "unverified", "error", "disabled")
RESERVED_SLUGS = frozenset({
    "openai",
    "anthropic",
    "azure_openai",
    "azure-openai",
    "deepgram",
    "openai_compatible",
    "openai-compatible",
})
DEFAULT_PARAMETERS = {
    "temperature": None,
    "max_tokens": None,
    "timeout_s": None,
    "fallback_priority": 100,
}

SCHEMA = """
CREATE TABLE IF NOT EXISTS connected_models (
 id TEXT PRIMARY KEY,
 slug TEXT NOT NULL UNIQUE,
 display_name TEXT NOT NULL,
 provider TEXT NOT NULL CHECK(provider IN ('openai','anthropic','azure_openai','deepgram','openai_compatible')),
 capability TEXT NOT NULL CHECK(capability IN ('reference','question_planning','transcription','embedding','judge')),
 model_id TEXT NOT NULL,
 endpoint TEXT,
 api_version TEXT,
 config_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(config_json)),
 encrypted_api_key TEXT,
 key_hint TEXT,
 enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
 is_default INTEGER NOT NULL DEFAULT 0 CHECK(is_default IN (0,1)),
 status TEXT NOT NULL DEFAULT 'unverified' CHECK(status IN ('connected','unverified','error','disabled')),
 last_error TEXT,
 last_latency_ms INTEGER,
 last_checked_at TEXT,
 created_at TEXT NOT NULL,
 updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_connected_models_resolve
 ON connected_models(capability, enabled, is_default DESC, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_connected_models_provider
 ON connected_models(provider, enabled);
CREATE UNIQUE INDEX IF NOT EXISTS idx_connected_models_default_cap
 ON connected_models(capability) WHERE is_default = 1;
CREATE TABLE IF NOT EXISTS model_audit (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 at TEXT NOT NULL,
 actor_user_id TEXT,
 action TEXT NOT NULL,
 model_id TEXT NOT NULL,
 details TEXT
);
CREATE INDEX IF NOT EXISTS idx_model_audit_at ON model_audit(at DESC);
"""


def migrate(db: sqlite3.Connection) -> None:
    db.executescript(SCHEMA)


def parse_parameters(config_json: str | None) -> dict[str, Any]:
    try:
        loaded = json.loads(config_json or "{}")
    except (ValueError, TypeError):
        loaded = {}
    if not isinstance(loaded, dict):
        loaded = {}
    params = dict(DEFAULT_PARAMETERS)
    for key in ("temperature", "max_tokens", "timeout_s", "fallback_priority"):
        if key in loaded and loaded[key] is not None:
            params[key] = loaded[key]
    return params


def encode_parameters(parameters: dict[str, Any]) -> str:
    clean: dict[str, Any] = {"fallback_priority": int(parameters.get("fallback_priority", 100))}
    for key in ("temperature", "max_tokens", "timeout_s"):
        value = parameters.get(key)
        if value is not None:
            clean[key] = value
    return json.dumps(clean, separators=(",", ":"), allow_nan=False)


def public_model(row: sqlite3.Row) -> dict[str, Any]:
    """Canonical non-secret DTO shared by model_registry, model_admin, and tests."""
    return {
        "id": row["id"],
        "slug": row["slug"],
        "display_name": row["display_name"],
        "provider": row["provider"],
        "capability": row["capability"],
        "model_id": row["model_id"],
        "endpoint": row["endpoint"],
        "api_version": row["api_version"],
        "parameters": parse_parameters(row["config_json"]),
        "hasKey": bool(row["encrypted_api_key"]),
        "key_hint": row["key_hint"],
        "enabled": bool(row["enabled"]),
        "is_default": bool(row["is_default"]),
        "status": row["status"],
        "last_error": row["last_error"],
        "last_latency_ms": row["last_latency_ms"],
        "last_checked_at": row["last_checked_at"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


def get_row(db: sqlite3.Connection, model_uuid: str) -> sqlite3.Row:
    row = db.execute("SELECT * FROM connected_models WHERE id=?", (model_uuid,)).fetchone()
    if row is None:
        raise HTTPException(404, "Model not found.")
    return row


def list_models(
    db: sqlite3.Connection, *, capability: str | None = None, provider: str | None = None
) -> list[dict[str, Any]]:
    clauses: list[str] = []
    args: list[Any] = []
    if capability:
        clauses.append("capability=?")
        args.append(capability)
    if provider:
        clauses.append("provider=?")
        args.append(provider)
    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    rows = db.execute(
        f"SELECT * FROM connected_models {where} ORDER BY capability ASC, is_default DESC, updated_at DESC, id ASC",
        args,
    ).fetchall()
    return [public_model(row) for row in rows]


def generate_unique_slug(db: sqlite3.Connection, base: str) -> str:
    stem = re.sub(r"[^a-z0-9]+", "-", base.lower()).strip("-")[:50].strip("-")
    if len(stem) < 2:
        stem = "model"
    candidate = stem if stem not in RESERVED_SLUGS else f"{stem[:43]}-{uuid4().hex[:6]}"
    for _ in range(8):
        if candidate not in RESERVED_SLUGS and db.execute("SELECT 1 FROM connected_models WHERE slug=?", (candidate,)).fetchone() is None:
            return candidate
        candidate = f"{stem[:43]}-{uuid4().hex[:6]}"
    return f"{stem[:38]}-{uuid4().hex[:10]}"


def create_model(
    db: sqlite3.Connection,
    *,
    model_uuid: str,
    slug: str | None,
    display_name: str,
    provider: str,
    capability: str,
    model_id: str,
    endpoint: str | None,
    api_version: str | None,
    parameters: dict[str, Any],
    encrypted_api_key: str | None,
    key_hint: str | None,
    enabled: bool,
    is_default: bool,
) -> dict[str, Any]:
    now = store.timestamp()
    resolved_slug = slug or generate_unique_slug(db, f"{provider}-{model_id}")
    status = "unverified" if enabled else "disabled"
    if is_default:
        db.execute(
            "UPDATE connected_models SET is_default=0, updated_at=? WHERE capability=? AND is_default=1",
            (now, capability),
        )
    try:
        db.execute(
            """INSERT INTO connected_models(
                id, slug, display_name, provider, capability, model_id, endpoint, api_version,
                config_json, encrypted_api_key, key_hint, enabled, is_default, status,
                last_error, last_latency_ms, last_checked_at, created_at, updated_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL,NULL,NULL,?,?)""",
            (
                model_uuid,
                resolved_slug,
                display_name,
                provider,
                capability,
                model_id,
                endpoint,
                api_version,
                encode_parameters(parameters),
                encrypted_api_key,
                key_hint,
                1 if enabled else 0,
                1 if is_default else 0,
                status,
                now,
                now,
            ),
        )
    except sqlite3.IntegrityError as exc:
        raise HTTPException(409, "A model with that slug already exists.") from exc
    return public_model(get_row(db, model_uuid))


def update_model(
    db: sqlite3.Connection,
    model_uuid: str,
    *,
    slug: str,
    display_name: str,
    capability: str,
    model_id: str,
    endpoint: str | None,
    api_version: str | None,
    parameters: dict[str, Any],
    encrypted_api_key: str | None,
    key_hint: str | None,
    enabled: bool,
    is_default: bool,
    status: str,
    last_error: str | None,
    last_latency_ms: int | None,
    last_checked_at: str | None,
    expected_updated_at: str | None = None,
) -> dict[str, Any]:
    if expected_updated_at is not None:
        current = get_row(db, model_uuid)
        if current["updated_at"] != expected_updated_at:
            raise HTTPException(409, "Model was modified concurrently; retry the update.")
    now = store.timestamp()
    if is_default:
        db.execute(
            "UPDATE connected_models SET is_default=0, updated_at=? WHERE capability=? AND is_default=1 AND id!=?",
            (now, capability, model_uuid),
        )
    try:
        cur = db.execute(
            """UPDATE connected_models SET
                slug=?, display_name=?, capability=?, model_id=?, endpoint=?, api_version=?,
                config_json=?, encrypted_api_key=?, key_hint=?, enabled=?, is_default=?,
                status=?, last_error=?, last_latency_ms=?, last_checked_at=?, updated_at=?
               WHERE id=?""",
            (
                slug,
                display_name,
                capability,
                model_id,
                endpoint,
                api_version,
                encode_parameters(parameters),
                encrypted_api_key,
                key_hint,
                1 if enabled else 0,
                1 if is_default else 0,
                status,
                last_error,
                last_latency_ms,
                last_checked_at,
                now,
                model_uuid,
            ),
        )
    except sqlite3.IntegrityError as exc:
        raise HTTPException(409, "A model with that slug already exists.") from exc
    if cur.rowcount == 0:
        raise HTTPException(404, "Model not found.")
    return public_model(get_row(db, model_uuid))


def toggle_model(db: sqlite3.Connection, model_uuid: str, *, enabled: bool) -> dict[str, Any]:
    row = get_row(db, model_uuid)
    now = store.timestamp()
    if not enabled:
        new_status = "disabled"
    elif row["last_error"]:
        new_status = "error"
    elif row["last_checked_at"]:
        new_status = "connected"
    else:
        new_status = "unverified"
    db.execute(
        "UPDATE connected_models SET enabled=?, status=?, updated_at=? WHERE id=?",
        (1 if enabled else 0, new_status, now, model_uuid),
    )
    return public_model(get_row(db, model_uuid))


def record_probe_result(
    db: sqlite3.Connection,
    model_uuid: str,
    *,
    ok: bool,
    latency_ms: int | None,
    error: str | None,
    checked_at: str,
    expected_updated_at: str | None = None,
) -> dict[str, Any]:
    row = get_row(db, model_uuid)
    if expected_updated_at is not None and row["updated_at"] != expected_updated_at:
        raise HTTPException(409, "Model was modified during probe; retry probe.")
    now = store.timestamp()
    if row["enabled"]:
        new_status = "connected" if ok else "error"
    else:
        new_status = "disabled"
    safe_error = sanitize_error_text(error, "Provider probe failed.") if (not ok and error) else None
    db.execute(
        """UPDATE connected_models
           SET status=?, last_error=?, last_latency_ms=?, last_checked_at=?, updated_at=?
           WHERE id=?""",
        (new_status, safe_error, latency_ms, checked_at, now, model_uuid),
    )
    return public_model(get_row(db, model_uuid))


def delete_model(db: sqlite3.Connection, model_uuid: str) -> dict[str, Any]:
    row = get_row(db, model_uuid)
    snapshot = {"id": row["id"], "slug": row["slug"], "provider": row["provider"], "capability": row["capability"]}
    cur = db.execute("DELETE FROM connected_models WHERE id=?", (model_uuid,))
    if cur.rowcount == 0:
        raise HTTPException(404, "Model not found.")
    return snapshot


def write_fallback_audit(
    db: sqlite3.Connection,
    *,
    actor_user_id: str | None,
    action: str,
    model_uuid: str,
    details: dict[str, Any] | None = None,
) -> None:
    db.execute(
        "INSERT INTO model_audit(at, actor_user_id, action, model_id, details) VALUES (?,?,?,?,?)",
        (store.timestamp(), actor_user_id, action, model_uuid, json.dumps(details) if details else None),
    )
