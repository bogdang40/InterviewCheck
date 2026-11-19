"""Atomic bulk archive, restore, tagging, and CSV/JSON export for interviews."""
from datetime import datetime, timezone
import json
import sqlite3
from tempfile import SpooledTemporaryFile
from typing import Annotated, Literal
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import Response, StreamingResponse
from pydantic import AfterValidator, Field, StringConstraints, field_validator, model_validator
from starlette.background import BackgroundTask

from . import exports, store
from .access import require_entitlement
from .models import Input, RequestID

router = APIRouter(dependencies=[Depends(require_entitlement)])

TagStr = Annotated[str, StringConstraints(min_length=1, max_length=32, pattern=r"^[^\x00-\x1f\x7f,]+$")]
MAX_TAGS_PER_SESSION = 10

CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS session_tags (
 session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
 tag TEXT NOT NULL,
 created_at TEXT NOT NULL,
 PRIMARY KEY (session_id, tag)
)"""
CREATE_INDEX_SQL = "CREATE INDEX IF NOT EXISTS idx_session_tags_tag ON session_tags(tag, session_id)"

CSV_HEADER = [
    "Session ID", "Date", "Candidate", "Role", "Resource policy", "Notice recorded",
    "Question", "Answer", "Comparison", "Source", "First matched excerpt",
    "Interviewer disposition", "Interviewer note", "Native score", "Native verdict",
    "Permitted source snapshot", "Exchange ID", "Parent exchange ID", "Planned slot",
    "Planned question", "Tags",
]


def has_tags_table(db: sqlite3.Connection) -> bool:
    return db.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_tags'"
    ).fetchone() is not None


def ensure_table(db: sqlite3.Connection) -> None:
    db.execute(CREATE_TABLE_SQL)
    db.execute(CREATE_INDEX_SQL)


def migrate(db: sqlite3.Connection) -> None:
    ensure_table(db)


def tags_for_sessions(db: sqlite3.Connection, session_ids: list[str]) -> dict[str, list[str]]:
    result: dict[str, list[str]] = {sid: [] for sid in session_ids}
    if not session_ids or not has_tags_table(db):
        return result
    placeholders = ",".join("?" for _ in session_ids)
    rows = db.execute(
        f"SELECT session_id, tag FROM session_tags WHERE session_id IN ({placeholders}) "
        "ORDER BY tag COLLATE NOCASE ASC, tag ASC",
        tuple(session_ids),
    ).fetchall()
    for row in rows:
        result.setdefault(row["session_id"], []).append(row["tag"])
    return result


def _unique_ids(ids: list) -> list:
    if len({str(item) for item in ids}) != len(ids):
        raise ValueError("Duplicate session IDs are not permitted.")
    return ids


SessionIDList = Annotated[list[RequestID], Field(min_length=1, max_length=100), AfterValidator(_unique_ids)]


class BulkArchiveInput(Input):
    session_ids: SessionIDList
    confirm_count: int = Field(ge=1, le=100)


class BulkRestoreItem(Input):
    session_id: RequestID
    operation_version: RequestID


class BulkRestoreInput(Input):
    items: list[BulkRestoreItem] = Field(min_length=1, max_length=100)

    @field_validator("items")
    @classmethod
    def unique_item_ids(cls, value):
        _unique_ids([item.session_id for item in value])
        return value


class BulkTagInput(Input):
    session_ids: SessionIDList
    add: list[TagStr] = Field(default_factory=list, max_length=10)
    remove: list[TagStr] = Field(default_factory=list, max_length=10)

    @model_validator(mode="after")
    def validate_tag_sets(self):
        self.add = list(dict.fromkeys(self.add))
        self.remove = list(dict.fromkeys(self.remove))
        if not self.add and not self.remove:
            raise ValueError("Provide at least one tag to add or remove.")
        if set(self.add) & set(self.remove):
            raise ValueError("Cannot both add and remove the same tag.")
        return self


class BulkExportInput(Input):
    session_ids: Annotated[list[RequestID], Field(min_length=1, max_length=200), AfterValidator(_unique_ids)]
    format: Literal["csv", "json"] = "csv"


def _require_sessions(db: sqlite3.Connection, keys: list[str], *, active_only: bool) -> None:
    table = "active_sessions" if active_only else "sessions"
    placeholders = ",".join("?" for _ in keys)
    found = {
        row[0] for row in db.execute(f"SELECT id FROM {table} WHERE id IN ({placeholders})", tuple(keys))
    }
    missing = [k for k in keys if k not in found]
    if missing:
        raise HTTPException(404, f"Interview not found: {missing[0]}")


@router.post("/interviews/bulk/archive")
def bulk_archive(payload: BulkArchiveInput):
    keys = [str(sid) for sid in payload.session_ids]
    if payload.confirm_count != len(keys):
        raise HTTPException(409, "Confirmation count does not match the selected interview count.")
    from . import trash

    now = store.timestamp()
    with store.connection(write=True) as db:
        _require_sessions(db, keys, active_only=False)
        placeholders = ",".join("?" for _ in keys)
        db.execute(f"DELETE FROM ats_access_versions WHERE session_id IN ({placeholders})", tuple(keys))
        newly_archived = 0
        for key in keys:
            cur = db.execute(
                """INSERT INTO session_trash(session_id, trashed_at, operation_version) VALUES (?,?,?)
                   ON CONFLICT(session_id) DO NOTHING""",
                (key, now, str(uuid4())),
            )
            newly_archived += cur.rowcount
        rows = db.execute(
            trash.BIN + f" WHERE s.id IN ({placeholders}) ORDER BY t.trashed_at DESC, t.session_id",
            tuple(keys),
        ).fetchall()
    return {"archived": len(keys), "newly_archived": newly_archived, "items": [dict(r) for r in rows]}


@router.post("/interviews/bulk/restore")
def bulk_restore(payload: BulkRestoreInput):
    from . import trash

    keys = [str(item.session_id) for item in payload.items]
    with store.connection(write=True) as db:
        for item in payload.items:
            trash.active_marker(db, str(item.session_id), item.operation_version)
        placeholders = ",".join("?" for _ in keys)
        db.execute(f"DELETE FROM session_trash WHERE session_id IN ({placeholders})", tuple(keys))
        restored = [store.get_summary(db, key) for key in keys]
    return {"restored": len(keys), "session_ids": keys, "items": restored}


@router.post("/interviews/bulk/tag")
def bulk_tag(payload: BulkTagInput):
    keys = [str(sid) for sid in payload.session_ids]
    now = datetime.now(timezone.utc).isoformat()
    with store.connection(write=True) as db:
        ensure_table(db)
        _require_sessions(db, keys, active_only=True)
        for key in keys:
            if payload.remove:
                rm_ph = ",".join("?" for _ in payload.remove)
                db.execute(
                    f"DELETE FROM session_tags WHERE session_id=? AND tag IN ({rm_ph})",
                    (key, *payload.remove),
                )
            for tag in payload.add:
                db.execute(
                    """INSERT INTO session_tags(session_id, tag, created_at) VALUES (?,?,?)
                       ON CONFLICT(session_id, tag) DO NOTHING""",
                    (key, tag, now),
                )
            count = db.execute("SELECT count(*) FROM session_tags WHERE session_id=?", (key,)).fetchone()[0]
            if count > MAX_TAGS_PER_SESSION:
                raise HTTPException(422, f"An interview can have at most {MAX_TAGS_PER_SESSION} tags.")
        tags_map = tags_for_sessions(db, keys)
    return {"updated": len(keys), "tags_by_session": tags_map}


def _export_csv_rows(db: sqlite3.Connection, keys: list[str], tags_map: dict[str, list[str]]) -> list[str]:
    placeholders = ",".join("?" for _ in keys)
    cursor = db.execute(
        f"""SELECT s.id,s.created_at,s.candidate,s.role,s.policy,s.consent,
                   a.question,a.answer,a.status,a.result,a.disposition,a.note,a.legacy,c.permitted_sources,
                   a.id exchange_id,a.parent_answer_id,a.planned_slot,
                   CASE WHEN a.planned_slot>0 THEN json_extract(c.questions,'$['||(a.planned_slot-1)||']') END planned_question
            FROM active_sessions s
            LEFT JOIN answers a ON a.session_id=s.id
            LEFT JOIN session_context c ON c.session_id=s.id
            WHERE s.id IN ({placeholders})
            ORDER BY s.created_at DESC, s.id, a.rowid""",
        tuple(keys),
    )
    rows = ["\ufeff" + exports.csv_row(CSV_HEADER)]
    for row in cursor:
        result = json.loads(row["result"]) if row["result"] else {}
        passage = next(iter(result.get("passages", [])), {})
        legacy = json.loads(row["legacy"]) if row["legacy"] else {}
        tag_text = "; ".join(tags_map.get(row["id"], []))
        rows.append(
            exports.csv_row([
                row["id"], row["created_at"], row["candidate"], row["role"], row["policy"],
                "Yes" if row["consent"] else "Unknown", row["question"], row["answer"], row["status"],
                passage.get("label"), passage.get("answer_excerpt"), row["disposition"], row["note"],
                (legacy.get("score") or {}).get("percent"), (legacy.get("label") or {}).get("label"),
                row["permitted_sources"] or "[]", row["exchange_id"], row["parent_answer_id"],
                row["planned_slot"], row["planned_question"], tag_text,
            ])
        )
    return rows


@router.post("/interviews/bulk/export")
def bulk_export(payload: BulkExportInput):
    keys = [str(sid) for sid in payload.session_ids]
    with store.connection() as db:
        _require_sessions(db, keys, active_only=True)
        tags_map = tags_for_sessions(db, keys)
        if payload.format == "json":
            sessions = [{**store.get_session(db, key), "tags": tags_map.get(key, [])} for key in keys]
            body = json.dumps(
                {
                    "format": "interviewcheck.bulk_export",
                    "exported_at": store.timestamp(),
                    "count": len(sessions),
                    "sessions": sessions,
                },
                ensure_ascii=False,
                indent=2,
            ).encode("utf-8")
            return Response(
                body,
                media_type="application/json",
                headers={
                    "Content-Disposition": 'attachment; filename="interviews-bulk.json"',
                    "Cache-Control": "no-store",
                },
            )
        csv_lines = _export_csv_rows(db, keys, tags_map)

    output = SpooledTemporaryFile(max_size=1024 * 1024)
    try:
        for line in csv_lines:
            output.write(line.encode("utf-8"))
        output.seek(0)
        return StreamingResponse(
            iter(lambda: output.read(65536), b""),
            media_type="text/csv; charset=utf-8",
            background=BackgroundTask(output.close),
            headers={
                "Content-Disposition": 'attachment; filename="interviews-bulk.csv"',
                "Cache-Control": "no-store",
            },
        )
    except BaseException:
        output.close()
        raise
