"""Session interviewer assignment and review queue API."""
from datetime import datetime, timedelta, timezone
import re
import sqlite3
from typing import Annotated, Any, Literal
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, Request
from pydantic import BeforeValidator, Field, field_validator, model_validator

from . import access, store
from .models import Input, RequestID

router = APIRouter()

AssignmentPriority = Literal["low", "normal", "high"]
PriorityFilter = Literal["", "low", "normal", "high"]
DueFilter = Literal["", "overdue", "soon"]
BulkAction = Literal["assign", "clear"]
SOON_WINDOW_HOURS = 48
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


def _due_state(raw: str | None, *, now_utc: datetime, soon_cutoff: datetime) -> str:
    if not raw or not isinstance(raw, str):
        return ""
    try:
        dt = datetime.fromisoformat(raw.strip())
    except ValueError:
        return ""
    if dt.tzinfo is None or dt.utcoffset() is None:
        dt = dt.replace(tzinfo=timezone.utc)
    else:
        dt = dt.astimezone(timezone.utc)
    if dt < now_utc:
        return "overdue"
    if dt <= soon_cutoff:
        return "soon"
    return "scheduled"


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


class BulkSessionAssignmentInput(Input):
    session_ids: list[RequestID] = Field(min_length=1, max_length=50)
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


@router.post("/interviews/assignments/bulk")
async def bulk_assignments(payload: BulkSessionAssignmentInput, request: Request):
    _, actor_email = await access.optional_actor(request)
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
):
    _, viewer_email = await access.optional_actor(request)
    now_utc = datetime.now(timezone.utc)
    soon_cutoff = now_utc + timedelta(hours=SOON_WINDOW_HOURS)
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
    if due:
        clauses.append("sa.due_at IS NOT NULL")
    where_sql = ("WHERE " + " AND ".join(clauses)) if clauses else ""
    due_counts = {"overdue": 0, "due_soon": 0}

    with store.connection() as db:
        if not _has_table(db, "session_assignments"):
            total = db.execute("SELECT COUNT(*) FROM active_sessions").fetchone()[0]
            counts = {"assigned_to_me": 0, "high_priority": 0, "unassigned": total}
            if (raw_assignee and raw_assignee.lower() != "unassigned") or priority or due:
                return {"viewer_email": viewer_email, "counts": counts, "due_counts": due_counts, "items": []}
            rows = db.execute(
                """SELECT s.id AS session_id, substr(s.candidate,1,180) AS candidate, substr(s.role,1,180) AS role,
                          CASE WHEN c.ended_at IS NOT NULL THEN 'finished' WHEN s.consent THEN 'active' ELSE 'archived' END AS lifecycle,
                          (SELECT COUNT(*) FROM answers a WHERE a.session_id=s.id AND a.status='match' AND a.disposition='pending') AS review_count,
                          NULL AS assignee_email, NULL AS assigned_by, NULL AS priority, NULL AS due_at, NULL AS updated_at
                   FROM active_sessions s LEFT JOIN session_context c ON c.session_id=s.id
                   ORDER BY s.created_at DESC, s.id ASC LIMIT ?""",
                (limit,),
            ).fetchall()
            items = [dict(row) for row in rows]
        else:
            cnt = db.execute(
                """SELECT COUNT(CASE WHEN LOWER(sa.assignee_email) = LOWER(?) THEN 1 END) AS assigned_to_me,
                          COUNT(CASE WHEN sa.priority = 'high' THEN 1 END) AS high_priority,
                          COUNT(CASE WHEN sa.session_id IS NULL THEN 1 END) AS unassigned
                   FROM active_sessions s LEFT JOIN session_assignments sa ON sa.session_id = s.id""",
                (viewer_email,),
            ).fetchone()
            counts = {k: int(cnt[k]) for k in ("assigned_to_me", "high_priority", "unassigned")}
            for drow in db.execute(
                """SELECT sa.due_at FROM active_sessions s
                   INNER JOIN session_assignments sa ON sa.session_id = s.id
                   WHERE sa.due_at IS NOT NULL"""
            ):
                state = _due_state(drow["due_at"], now_utc=now_utc, soon_cutoff=soon_cutoff)
                if state == "overdue":
                    due_counts["overdue"] += 1
                elif state == "soon":
                    due_counts["due_soon"] += 1
            limit_sql = "" if due else "LIMIT ?"
            query_params = tuple(params) if due else (*params, limit)
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
                    {limit_sql}""",
                query_params,
            ).fetchall()
            items = [dict(row) for row in rows]
            if due:
                items = [
                    item for item in items
                    if _due_state(item["due_at"], now_utc=now_utc, soon_cutoff=soon_cutoff) == due
                ][:limit]
    return {"viewer_email": viewer_email, "counts": counts, "due_counts": due_counts, "items": items}
