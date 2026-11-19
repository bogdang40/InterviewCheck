"""Session interviewer assignment and review queue API."""
from datetime import datetime, timezone
import re
import sqlite3
from typing import Annotated, Any, Literal
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, Request
from pydantic import BeforeValidator, Field, field_validator

from . import access, store
from .models import Input

router = APIRouter()

AssignmentPriority = Literal["low", "normal", "high"]
PriorityFilter = Literal["", "low", "normal", "high"]
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

SCHEMA = """
CREATE TABLE IF NOT EXISTS session_assignments (
  session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
  assignee_email TEXT NOT NULL,
  assigned_by TEXT NOT NULL,
  priority TEXT NOT NULL DEFAULT 'normal' CHECK(priority IN ('low','normal','high')),
  due_at TEXT,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_session_assignments_assignee
  ON session_assignments(assignee_email, priority, session_id);
"""


def migrate(db: sqlite3.Connection) -> None:
    db.executescript(SCHEMA)


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
async def get_assignment(sid: UUID, request: Request):
    key = str(sid)
    _, actor_email = await access.optional_actor(request)
    with store.connection() as db:
        _require_active_session(db, key)
        row = None
        if _has_table(db, "session_assignments"):
            row = db.execute(
                "SELECT session_id, assignee_email, assigned_by, priority, due_at, updated_at FROM session_assignments WHERE session_id=?",
                (key,),
            ).fetchone()
        return {"assignment": _row_to_assignment(row), "suggested_reviewers": _suggested_reviewers(db, actor_email)}


@router.put("/sessions/{sid}/assignment")
async def put_assignment(sid: UUID, payload: SessionAssignmentInput, request: Request):
    key = str(sid)
    _, actor_email = await access.optional_actor(request)
    now = store.timestamp()
    due_iso = payload.due_at.isoformat() if payload.due_at is not None else None
    with store.connection(write=True) as db:
        _require_active_session(db, key)
        migrate(db)
        db.execute(
            """INSERT INTO session_assignments(session_id, assignee_email, assigned_by, priority, due_at, updated_at)
               VALUES (?,?,?,?,?,?)
               ON CONFLICT(session_id) DO UPDATE SET
                 assignee_email=excluded.assignee_email, assigned_by=excluded.assigned_by,
                 priority=excluded.priority, due_at=excluded.due_at, updated_at=excluded.updated_at""",
            (key, payload.assignee_email, actor_email, payload.priority, due_iso, now),
        )
    return {
        "assignment": {
            "session_id": key,
            "assignee_email": payload.assignee_email,
            "assigned_by": actor_email,
            "priority": payload.priority,
            "due_at": due_iso,
            "updated_at": now,
        }
    }


@router.delete("/sessions/{sid}/assignment")
def delete_assignment(sid: UUID):
    key = str(sid)
    with store.connection(write=True) as db:
        _require_active_session(db, key)
        if _has_table(db, "session_assignments"):
            db.execute("DELETE FROM session_assignments WHERE session_id=?", (key,))
    return {"cleared": True, "session_id": key}


@router.get("/interviews/assignments")
async def list_assignments(
    request: Request,
    assignee: str = Query(default="", max_length=200),
    priority: PriorityFilter = "",
    limit: int = Query(default=50, ge=1, le=200),
):
    _, viewer_email = await access.optional_actor(request)
    raw_assignee = assignee.strip()
    clauses: list[str] = []
    params: list[Any] = []
    if raw_assignee:
        lowered = raw_assignee.lower()
        if lowered == "me":
            clauses.append("LOWER(sa.assignee_email) = LOWER(?)")
            params.append(viewer_email)
        elif lowered == "unassigned":
            clauses.append("sa.session_id IS NULL")
        else:
            clauses.append("LOWER(sa.assignee_email) = LOWER(?)")
            params.append(raw_assignee)
    if priority:
        clauses.append("sa.priority = ?")
        params.append(priority)
    where_sql = ("WHERE " + " AND ".join(clauses)) if clauses else ""

    with store.connection() as db:
        if not _has_table(db, "session_assignments"):
            total = db.execute("SELECT COUNT(*) FROM active_sessions").fetchone()[0]
            counts = {"assigned_to_me": 0, "high_priority": 0, "unassigned": total}
            if (raw_assignee and raw_assignee.lower() != "unassigned") or priority:
                return {"viewer_email": viewer_email, "counts": counts, "items": []}
            rows = db.execute(
                """SELECT s.id AS session_id, substr(s.candidate,1,180) AS candidate, substr(s.role,1,180) AS role,
                          CASE WHEN c.ended_at IS NOT NULL THEN 'finished' WHEN s.consent THEN 'active' ELSE 'archived' END AS lifecycle,
                          (SELECT COUNT(*) FROM answers a WHERE a.session_id=s.id AND a.status='match' AND a.disposition='pending') AS review_count,
                          NULL AS assignee_email, NULL AS assigned_by, NULL AS priority, NULL AS due_at, NULL AS updated_at
                   FROM active_sessions s LEFT JOIN session_context c ON c.session_id=s.id
                   ORDER BY s.created_at DESC, s.id ASC LIMIT ?""",
                (limit,),
            ).fetchall()
        else:
            cnt = db.execute(
                """SELECT COUNT(CASE WHEN LOWER(sa.assignee_email) = LOWER(?) THEN 1 END) AS assigned_to_me,
                          COUNT(CASE WHEN sa.priority = 'high' THEN 1 END) AS high_priority,
                          COUNT(CASE WHEN sa.session_id IS NULL THEN 1 END) AS unassigned
                   FROM active_sessions s LEFT JOIN session_assignments sa ON sa.session_id = s.id""",
                (viewer_email,),
            ).fetchone()
            counts = {k: int(cnt[k]) for k in ("assigned_to_me", "high_priority", "unassigned")}
            rows = db.execute(
                f"""SELECT s.id AS session_id, substr(s.candidate,1,180) AS candidate, substr(s.role,1,180) AS role,
                           CASE WHEN c.ended_at IS NOT NULL THEN 'finished' WHEN s.consent THEN 'active' ELSE 'archived' END AS lifecycle,
                           (SELECT COUNT(*) FROM answers a WHERE a.session_id=s.id AND a.status='match' AND a.disposition='pending') AS review_count,
                           sa.assignee_email, sa.assigned_by, sa.priority, sa.due_at, sa.updated_at
                    FROM active_sessions s
                    LEFT JOIN session_context c ON c.session_id = s.id
                    LEFT JOIN session_assignments sa ON sa.session_id = s.id
                    {where_sql}
                    ORDER BY CASE sa.priority WHEN 'high' THEN 0 WHEN 'normal' THEN 1 WHEN 'low' THEN 2 ELSE 3 END ASC,
                             CASE WHEN sa.due_at IS NULL THEN 1 ELSE 0 END ASC,
                             sa.due_at ASC, COALESCE(sa.updated_at, s.created_at) DESC, s.id ASC
                    LIMIT ?""",
                (*params, limit),
            ).fetchall()
    return {"viewer_email": viewer_email, "counts": counts, "items": [dict(row) for row in rows]}
