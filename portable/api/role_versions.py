"""Immutable rubric and template version history, diffing, and safe restore."""
from collections import Counter
from datetime import datetime, timezone
import json
import sqlite3
from typing import Annotated, Any
from uuid import UUID, uuid4

from fastapi import APIRouter, HTTPException, Path, Query, Request
from starlette.concurrency import run_in_threadpool

from . import access, role_kits, sql_script
from .models import RoleRestoreInput

router = APIRouter()

SCHEMA = """
CREATE TABLE IF NOT EXISTS role_versions (
 id TEXT PRIMARY KEY,
 role_id TEXT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
 version_number INTEGER NOT NULL,
 content_sha256 TEXT NOT NULL,
 name TEXT NOT NULL,
 description TEXT NOT NULL,
 questions TEXT NOT NULL,
 policy TEXT NOT NULL,
 permitted_sources TEXT NOT NULL,
 rubric_json TEXT NOT NULL DEFAULT '[]',
 change_note TEXT NOT NULL DEFAULT '',
 created_by TEXT NOT NULL DEFAULT 'local-operator',
 created_at TEXT NOT NULL,
 UNIQUE(role_id, version_number)
);
CREATE INDEX IF NOT EXISTS idx_role_versions_role ON role_versions(role_id, version_number DESC);
"""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def migrate(db: sqlite3.Connection) -> None:
    sql_script.execute(db, SCHEMA)
    prev_factory = db.row_factory
    db.row_factory = sqlite3.Row
    try:
        missing = db.execute(
            "SELECT * FROM roles r WHERE NOT EXISTS (SELECT 1 FROM role_versions v WHERE v.role_id=r.id)"
        ).fetchall()
        for row in missing:
            record_snapshot_row(db, row, change_note="Initial version", created_by="local-operator")
    finally:
        db.row_factory = prev_factory


def record_snapshot_row(
    db: sqlite3.Connection, row: sqlite3.Row, *, change_note: str = "", created_by: str = "local-operator"
) -> None:
    parsed = role_kits.role_row(row)
    db.execute(
        """INSERT INTO role_versions(
               id, role_id, version_number, content_sha256, name, description, questions,
               policy, permitted_sources, rubric_json, change_note, created_by, created_at
           ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
           ON CONFLICT(role_id, version_number) DO NOTHING""",
        (str(uuid4()), row["id"], int(row["version_number"]), parsed["version"], row["name"],
         row["description"], row["questions"], row["policy"], row["permitted_sources"],
         row["rubric_json"], change_note or "", created_by or "local-operator", _now()),
    )


def ensure_initial_snapshot(
    db: sqlite3.Connection, role_id: str, *, change_note: str = "Initial version", created_by: str = "local-operator"
) -> None:
    if db.execute("SELECT 1 FROM role_versions WHERE role_id=? LIMIT 1", (role_id,)).fetchone() is not None:
        return
    row = db.execute("SELECT * FROM roles WHERE id=?", (role_id,)).fetchone()
    if row is not None:
        record_snapshot_row(db, row, change_note=change_note, created_by=created_by)


def _version_dict(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "role_id": row["role_id"],
        "version_number": int(row["version_number"]),
        "version": row["content_sha256"],
        "content_sha256": row["content_sha256"],
        "name": row["name"],
        "description": row["description"],
        "questions": json.loads(row["questions"]),
        "policy": row["policy"],
        "permitted_sources": json.loads(row["permitted_sources"]),
        "rubric": json.loads(row["rubric_json"]),
        "change_note": row["change_note"],
        "created_by": row["created_by"],
        "created_at": row["created_at"],
    }


def _fallback_from_live(live: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": live["id"],
        "role_id": live["id"],
        "version_number": live["version_number"],
        "version": live["version"],
        "content_sha256": live["version"],
        "name": live["name"],
        "description": live["description"],
        "questions": live["questions"],
        "policy": live["policy"],
        "permitted_sources": live["permitted_sources"],
        "rubric": live["rubric"],
        "change_note": "Initial version",
        "created_by": "local-operator",
        "created_at": "",
    }


def _ordered_excess(items, counts):
    excess = []
    for item in items:
        if counts[item] > 0:
            excess.append(item)
            counts[item] -= 1
    return excess


def _diff_list(old_items: list[str], new_items: list[str]) -> dict[str, Any]:
    old, new = Counter(old_items), Counter(new_items)
    return {
        "added": _ordered_excess(new_items, new - old),
        "removed": _ordered_excess(old_items, old - new),
        "occurrences": [{"text": text, "before": old[text], "after": new[text]}
                        for text in dict.fromkeys([*old_items, *new_items]) if old[text] != new[text]],
        # Repeated prompts have no persistent identity. Report a reorder only for a pure permutation.
        "reordered": old == new and old_items != new_items,
    }


def _diff_materials(old_items, new_items):
    old = [(r["label"], r["text"]) for r in old_items]
    new = [(r["label"], r["text"]) for r in new_items]
    old_counts, new_counts = Counter(old), Counter(new)
    labels = _diff_list([label for label, _ in old], [label for label, _ in new])
    return {
        **labels,
        "reordered": old_counts == new_counts and old != new,
        "added_entries": [{"label": label, "text": text} for label, text in _ordered_excess(new, new_counts - old_counts)],
        "removed_entries": [{"label": label, "text": text} for label, text in _ordered_excess(old, old_counts - new_counts)],
    }


def _diff_rubric(old_rubric: list[dict[str, Any]], new_rubric: list[dict[str, Any]]) -> dict[str, Any]:
    old_map = {item["id"]: item for item in old_rubric}
    new_map = {item["id"]: item for item in new_rubric}
    return {
        "added": [item for item in new_rubric if item["id"] not in old_map],
        "removed": [item for item in old_rubric if item["id"] not in new_map],
        "reordered": [key for key in old_map if key in new_map] != [key for key in new_map if key in old_map],
        "modified": [
            {"id": key, "version": old_map[key], "live": new_map[key]}
            for key in new_map if key in old_map and old_map[key] != new_map[key]
        ],
    }


def compute_diff(version: dict[str, Any], live: dict[str, Any]) -> dict[str, Any]:
    fields = ("name", "description", "policy", "questions", "permitted_sources", "rubric")
    changes = {f: {"version": version[f], "live": live[f]} for f in fields if version[f] != live[f]}
    return {
        "against_version_number": live["version_number"],
        "against_version": live["version"],
        "has_changes": bool(changes),
        "changed_fields": list(changes),
        "changes": changes,
        "questions": _diff_list(version["questions"], live["questions"]),
        "rubric": _diff_rubric(version["rubric"], live["rubric"]),
        "permitted_sources": _diff_materials(version["permitted_sources"], live["permitted_sources"]),
    }


@router.get("/roles/{rid}/versions")
def list_versions(rid: UUID):
    from . import store

    key = str(rid)
    with store.connection() as db:
        role_row = db.execute("SELECT * FROM roles WHERE id=?", (key,)).fetchone()
        if role_row is None:
            raise HTTPException(404, "Role does not exist.")
        live = role_kits.role_row(role_row)
        rows = db.execute("SELECT * FROM role_versions WHERE role_id=? ORDER BY version_number DESC", (key,)).fetchall()
        versions = [_version_dict(row) for row in rows] if rows else [_fallback_from_live(live)]
    return {"role_id": key, "current_version": live["version"], "current_version_number": live["version_number"], "versions": versions}


def _saved_version(db, live, number):
    row = db.execute("SELECT * FROM role_versions WHERE role_id=? AND version_number=?", (live["id"], number)).fetchone()
    if row is not None:
        return _version_dict(row)
    if number == live["version_number"]:
        history = db.execute("SELECT 1 FROM role_versions WHERE role_id=? LIMIT 1", (live["id"],)).fetchone()
        if history is None:
            return _fallback_from_live(live)
    raise HTTPException(404, "Role version does not exist.")


@router.get("/roles/{rid}/versions/{version_number}")
def version_detail(rid: UUID, version_number: int = Path(ge=1, le=2**63 - 1),
                   compare_to: Annotated[int | None, Query(ge=1, le=2**63 - 1)] = None):
    from . import store

    key = str(rid)
    with store.connection() as db:
        role_row = db.execute("SELECT * FROM roles WHERE id=?", (key,)).fetchone()
        if role_row is None:
            raise HTTPException(404, "Role does not exist.")
        live = role_kits.role_row(role_row)
        source = _saved_version(db, live, version_number)
        target = live
        if compare_to is not None:
            target = source if compare_to == version_number else _saved_version(db, live, compare_to)
    return {
        "role_id": key,
        "current_version": live["version"],
        "current_version_number": live["version_number"],
        "version": source,
        "diff": compute_diff(source, target),
    }


@router.post("/roles/{rid}/versions/{version_number}/restore")
async def restore_version(
    rid: UUID, item: RoleRestoreInput, request: Request, version_number: int = Path(ge=1, le=2**63 - 1)
):
    _, actor_email = await access.optional_actor(request)
    return await run_in_threadpool(_restore_version, str(rid), item, version_number, actor_email)


def _restore_version(key: str, item: RoleRestoreInput, version_number: int, actor_email: str):
    from . import store

    with store.connection(write=True) as db:
        existing = db.execute("SELECT * FROM roles WHERE id=?", (key,)).fetchone()
        if existing is None:
            raise HTTPException(404, "Role does not exist.")
        role_kits.check_role_version(existing, item.expected_version)
        ensure_initial_snapshot(db, key)
        target = db.execute(
            "SELECT * FROM role_versions WHERE role_id=? AND version_number=?", (key, version_number)
        ).fetchone()
        if target is None:
            raise HTTPException(404, "Role version does not exist.")
        next_version = int(existing["version_number"]) + 1
        db.execute(
            """UPDATE roles
               SET name=?, description=?, questions=?, policy=?, permitted_sources=?, rubric_json=?, version_number=?
               WHERE id=?""",
            (target["name"], target["description"], target["questions"], target["policy"],
             target["permitted_sources"], target["rubric_json"], next_version, key),
        )
        updated = db.execute("SELECT * FROM roles WHERE id=?", (key,)).fetchone()
        note = item.change_note or f"Restored from version {version_number}"
        record_snapshot_row(db, updated, change_note=note, created_by=actor_email)
        result = role_kits.role_row(updated)
    return {**result, "restored_from_version": version_number}
