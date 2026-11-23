"""Session interviewer assignment and review queue API."""
from datetime import datetime, timezone
import re
import sqlite3
from typing import Annotated, Any, Literal
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, Request
from pydantic import BeforeValidator, Field, field_validator, model_validator
from starlette.concurrency import run_in_threadpool

from . import access, assignment_queue, store
from .assignment_versions import AssignmentVersion, AssignmentVersions, require_versions, version_for
from .models import Input, RequestID

router = APIRouter()

AssignmentPriority = Literal["low", "normal", "high"]
PriorityFilter = Literal["", "low", "normal", "high"]
DueFilter = Literal["", "overdue", "soon"]
BulkAction = Literal["assign", "clear"]
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

CREATE_TABLE = """
CREATE TABLE IF NOT EXISTS session_assignments (
  session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
  assignee_email TEXT NOT NULL,
  assigned_by TEXT NOT NULL,
  priority TEXT NOT NULL DEFAULT 'normal' CHECK(priority IN ('low','normal','high')),
  due_at TEXT,
  updated_at TEXT NOT NULL
)
"""
CREATE_INDEX = """
CREATE INDEX IF NOT EXISTS idx_session_assignments_assignee
  ON session_assignments(assignee_email, priority, session_id);
"""


def migrate(db: sqlite3.Connection) -> None:
    db.execute(CREATE_TABLE)
    db.execute(CREATE_INDEX)


def _has_table(db: sqlite3.Connection, name: str) -> bool:
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def _clean_email(value: str) -> str | None:
    if not isinstance(value, str) or any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        return None
    cleaned = value.strip().lower()
    if 3 <= len(cleaned) <= 254 and _EMAIL_RE.fullmatch(cleaned):
        return cleaned
    return None


def _parse_due_at(value: Any) -> Any:
    if value is None or isinstance(value, datetime):
        return value
    if not isinstance(value, str) or len(value.strip()) < 10:
        raise ValueError("due_at must be an ISO-8601 datetime string.")
    try:
        return datetime.fromisoformat(value.strip())
    except ValueError as exc:
        raise ValueError("due_at must be a valid ISO-8601 datetime.") from exc


class SessionAssignmentInput(Input):
    expected_version: AssignmentVersion | None = None
    assignee_email: str = Field(min_length=3, max_length=254)
    priority: AssignmentPriority = "normal"
    due_at: Annotated[datetime, BeforeValidator(_parse_due_at)] | None = None

    @field_validator("assignee_email", mode="after")
    @classmethod
    def validate_assignee_email(cls, value: str) -> str:
        cleaned = _clean_email(value)
        if cleaned is None:
            raise ValueError("Enter a valid assignee email address.")
        return cleaned

    @field_validator("due_at", mode="after")
    @classmethod
    def require_tz_aware_due_at(cls, value: datetime | None) -> datetime | None:
        if value is None:
            return None
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("due_at must include a timezone offset.")
        return value.astimezone(timezone.utc)


class BulkSessionAssignmentInput(Input):
    session_ids: list[RequestID] = Field(min_length=1, max_length=50)
    expected_versions: AssignmentVersions | None = Field(default=None, max_length=50)
    action: BulkAction = "assign"
    assignee_email: str | None = Field(default=None, min_length=3, max_length=254)
    priority: AssignmentPriority = "normal"
    due_at: Annotated[datetime, BeforeValidator(_parse_due_at)] | None = None

    @field_validator("due_at", mode="after")
    @classmethod
    def require_tz_aware_due_at(cls, value: datetime | None) -> datetime | None:
        if value is None:
            return None
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("due_at must include a timezone offset.")
        return value.astimezone(timezone.utc)

    @model_validator(mode="after")
    def validate_bulk_request(self):
        if len({str(item) for item in self.session_ids}) != len(self.session_ids):
            raise ValueError("Duplicate session IDs are not permitted.")
        if self.expected_versions is not None and set(self.expected_versions) != {str(item) for item in self.session_ids}:
            raise ValueError("Provide the assignment version for each selected session and no additional sessions.")
        if self.assignee_email is not None:
            cleaned = _clean_email(self.assignee_email)
            if cleaned is None:
                raise ValueError("Enter a valid assignee email address.")
            self.assignee_email = cleaned
        elif self.action == "assign":
            raise ValueError("assignee_email is required when action is assign.")
        return self


def _require_active_session(db: sqlite3.Connection, session_id: str) -> None:
    if db.execute("SELECT 1 FROM active_sessions WHERE id=?", (session_id,)).fetchone() is None:
        raise HTTPException(404, "Session does not exist.")


def _row_to_assignment(row: sqlite3.Row | None) -> dict[str, Any] | None:
    return dict(row) if row is not None else None


def _suggested_reviewers(db: sqlite3.Connection, actor_email: str) -> list[str]:
    emails: set[str] = set()
    actor = _clean_email(actor_email)
    queries: list[str] = []
    if _has_table(db, "answer_review_events"):
        queries.append("SELECT DISTINCT reviewer_email FROM answer_review_events")
    if _has_table(db, "session_assignments"):
        queries.append("SELECT DISTINCT assignee_email FROM session_assignments UNION SELECT DISTINCT assigned_by FROM session_assignments")
    for sql in queries:
        for row in db.execute(sql):
            cleaned = _clean_email(row[0] or "")
            if cleaned is not None:
                emails.add(cleaned)
    if actor is not None:
        emails.discard(actor)
        return ([actor] + sorted(emails))[:25]
    return sorted(emails)[:25]


@router.get("/sessions/{sid}/assignment")
async def get_assignment(sid: UUID, request: Request, include_version: bool = False):
    _, actor_email = await access.optional_actor(request)
    return await run_in_threadpool(_read_assignment, str(sid), actor_email, include_version)


def _read_assignment(key: str, actor_email: str, include_version: bool = False):
    with store.connection() as db:
        _require_active_session(db, key)
        row = None
        if _has_table(db, "session_assignments"):
            row = db.execute(
                "SELECT session_id, assignee_email, assigned_by, priority, due_at, updated_at FROM session_assignments WHERE session_id=?",
                (key,),
            ).fetchone()
        response = {"assignment": _row_to_assignment(row), "suggested_reviewers": _suggested_reviewers(db, actor_email)}
        if include_version:
            response["version"] = version_for(key, row)
        return response


@router.put("/sessions/{sid}/assignment")
async def put_assignment(sid: UUID, payload: SessionAssignmentInput, request: Request):
    _, actor_email = await access.optional_actor(request)
    return await run_in_threadpool(_save_assignment, str(sid), payload, actor_email)


def _save_assignment(key: str, payload: SessionAssignmentInput, actor_email: str):
    now = store.timestamp()
    with store.connection(write=True) as db:
        _require_active_session(db, key)
        if payload.expected_version is not None:
            require_versions(db, {key: payload.expected_version})
        migrate(db)
        due_iso = _deadline_for_update(db, key, payload.due_at)
        db.execute(
            """INSERT INTO session_assignments(session_id, assignee_email, assigned_by, priority, due_at, updated_at)
               VALUES (?,?,?,?,?,?)
               ON CONFLICT(session_id) DO UPDATE SET
                 assignee_email=excluded.assignee_email, assigned_by=excluded.assigned_by,
                 priority=excluded.priority, due_at=excluded.due_at, updated_at=excluded.updated_at""",
            (key, payload.assignee_email, actor_email, payload.priority, due_iso, now),
        )
    response = {
        "assignment": {
            "session_id": key,
            "assignee_email": payload.assignee_email,
            "assigned_by": actor_email,
            "priority": payload.priority,
            "due_at": due_iso,
            "updated_at": now,
        }
    }
    if payload.expected_version is not None:
        response["version"] = version_for(key, response["assignment"])
    return response


def _deadline_for_update(db: sqlite3.Connection, session_id: str, requested: datetime | None) -> str | None:
    if requested is None:
        return None
    canonical = requested.isoformat()
    row = db.execute("SELECT due_at FROM session_assignments WHERE session_id=?", (session_id,)).fetchone()
    if row and isinstance(row["due_at"], str) and row["due_at"] != canonical:
        # Earlier stores can retain the original offset or use Z for UTC.
        try:
            if datetime.fromisoformat(row["due_at"]) == requested:
                return row["due_at"]
        except ValueError:
            pass  # A valid new deadline can replace an unreadable old value.
    return canonical


@router.delete("/sessions/{sid}/assignment")
def delete_assignment(sid: UUID, expected_version: AssignmentVersion | None = None):
    key = str(sid)
    with store.connection(write=True) as db:
        _require_active_session(db, key)
        if expected_version is not None:
            require_versions(db, {key: expected_version})
        if _has_table(db, "session_assignments"):
            db.execute("DELETE FROM session_assignments WHERE session_id=?", (key,))
    response = {"cleared": True, "session_id": key}
    if expected_version is not None:
        response["version"] = version_for(key, None)
    return response


@router.post("/interviews/assignments/bulk")
async def bulk_assignments(payload: BulkSessionAssignmentInput, request: Request):
    _, actor_email = await access.optional_actor(request)
    return await run_in_threadpool(_save_bulk_assignments, payload, actor_email)


def _save_bulk_assignments(payload: BulkSessionAssignmentInput, actor_email: str):
    ids = [str(item) for item in payload.session_ids]
    placeholders = ",".join("?" for _ in ids)
    now = store.timestamp()
    due_iso = payload.due_at.isoformat() if payload.due_at is not None else None
    with store.connection(write=True) as db:
        found = {
            row[0]
            for row in db.execute(
                f"SELECT id FROM active_sessions WHERE id IN ({placeholders})",
                tuple(ids),
            ).fetchall()
        }
        if len(found) != len(ids):
            raise HTTPException(404, "One or more sessions do not exist.")
        if payload.expected_versions is not None:
            require_versions(db, payload.expected_versions)
        if payload.action == "clear":
            if _has_table(db, "session_assignments"):
                db.execute(
                    f"DELETE FROM session_assignments WHERE session_id IN ({placeholders})",
                    tuple(ids),
                )
            return {"action": "clear", "updated": len(ids), "cleared_ids": ids}
        migrate(db)
        assert payload.assignee_email is not None
        assignments: list[dict[str, Any]] = []
        for sid in ids:
            db.execute(
                """INSERT INTO session_assignments(session_id, assignee_email, assigned_by, priority, due_at, updated_at)
                   VALUES (?,?,?,?,?,?)
                   ON CONFLICT(session_id) DO UPDATE SET
                     assignee_email=excluded.assignee_email, assigned_by=excluded.assigned_by,
                     priority=excluded.priority, due_at=excluded.due_at, updated_at=excluded.updated_at""",
                (sid, payload.assignee_email, actor_email, payload.priority, due_iso, now),
            )
            assignments.append(
                {
                    "session_id": sid,
                    "assignee_email": payload.assignee_email,
                    "assigned_by": actor_email,
                    "priority": payload.priority,
                    "due_at": due_iso,
                    "updated_at": now,
                }
            )
        return {"action": "assign", "updated": len(ids), "assignments": assignments}


@router.get("/interviews/assignments")
async def list_assignments(
    request: Request,
    assignee: str = Query(default="", max_length=200),
    priority: PriorityFilter = "",
    due: DueFilter = "",
    limit: int = Query(default=50, ge=1, le=200),
    page: int = Query(default=1, ge=1),
    include_versions: bool = False,
    include_transition: bool = False,
):
    _, viewer_email = await access.optional_actor(request)
    return await run_in_threadpool(_read_queue_page, viewer_email, assignee, priority, due, limit, page,
                                   include_versions, include_transition)


def _read_queue_page(viewer_email: str, assignee: str, priority: str, due: str, limit: int, page: int,
                     include_versions: bool = False, include_transition: bool = False):
    with store.connection() as db:
        result = assignment_queue.read_page(
            db, viewer=viewer_email, assignee=assignee, priority=priority, due=due, limit=limit, page=page,
            has_assignments=_has_table(db, "session_assignments"), now=datetime.now(timezone.utc), include_transition=include_transition,
        )
    if include_versions:
        for row in result["items"]:
            row["assignment_version"] = version_for(row["session_id"], row)
    return result
