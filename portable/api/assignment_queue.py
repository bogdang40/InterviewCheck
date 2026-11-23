"""Page a filtered assignment queue and calculate its workspace totals in one read transaction."""
from datetime import datetime, timedelta, timezone
import sqlite3

SOON_WINDOW_HOURS = 48
# An older workspace has only unassigned sessions until the assignment table exists.
EMPTY_ASSIGNMENTS = """(SELECT NULL session_id, NULL assignee_email, NULL assigned_by,
                               NULL priority, NULL due_at, NULL updated_at WHERE 0)"""

FILTER = """
(:assignee = '' OR
 (:assignee = 'unassigned' AND session_id IS NULL) OR
 (:assignee <> 'unassigned' AND assignee_email = :email COLLATE NOCASE))
AND (:priority = '' OR priority = :priority)
AND (:due = '' OR due_state = :due)
"""

ORDER = """CASE p.priority WHEN 'high' THEN 0 WHEN 'normal' THEN 1 WHEN 'low' THEN 2 ELSE 3 END,
           p.due_at IS NULL, p.due_at, p.last_update DESC, p.id"""


def _due_state(raw, now, cutoff):
    if not raw or not isinstance(raw, str):
        return ""
    try:
        stamp = datetime.fromisoformat(raw.strip())
    except ValueError:
        return ""
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    if stamp < now:
        return "overdue"
    return "soon" if stamp <= cutoff else "scheduled"


def read_page(db: sqlite3.Connection, *, viewer: str, assignee: str, priority: str, due: str,
              limit: int, page: int, has_assignments: bool, now: datetime) -> dict:
    relation = "session_assignments" if has_assignments else EMPTY_ASSIGNMENTS
    query = f"FROM active_sessions s LEFT JOIN {relation} sa ON sa.session_id = s.id"
    # Keep the same cutoff for both totals and page contents. Accept the ISO timestamps
    # used by older records, including offsets and microseconds at the 48 hour boundary.
    cutoff = now + timedelta(hours=SOON_WINDOW_HOURS)
    db.create_function("ic_due_state", 1, lambda value: _due_state(value, now, cutoff), deterministic=True)
    assignee = assignee.strip().lower()
    params = {"viewer": viewer, "assignee": assignee, "email": viewer if assignee == "me" else assignee,
              "priority": priority, "due": due, "limit": limit}

    totals = db.execute(f"""WITH states AS MATERIALIZED (
        SELECT sa.session_id, sa.assignee_email, sa.priority, ic_due_state(sa.due_at) due_state {query}
      ) SELECT count(CASE WHEN assignee_email = :viewer COLLATE NOCASE THEN 1 END) assigned_to_me,
               count(CASE WHEN priority = 'high' THEN 1 END) high_priority,
               count(CASE WHEN session_id IS NULL THEN 1 END) unassigned,
               count(CASE WHEN due_state = 'overdue' THEN 1 END) overdue,
               count(CASE WHEN due_state = 'soon' THEN 1 END) due_soon,
               count(CASE WHEN {FILTER} THEN 1 END) filtered
        FROM states""", params).fetchone()
    matched = totals["filtered"]
    pages = max(1, (matched + limit - 1) // limit)
    page = min(page, pages)
    params["offset"] = (page - 1) * limit

    # Page before loading candidate text and counting pending answers. The hint also
    # prevents SQLite from flattening the result projection into the full-set sort.
    rows = db.execute(f"""WITH candidates AS (
        SELECT s.id, sa.session_id, sa.assignee_email, sa.assigned_by, sa.priority, sa.due_at, sa.updated_at,
               coalesce(sa.updated_at, s.created_at) last_update, ic_due_state(sa.due_at) due_state
        {query}
      ), paged AS MATERIALIZED (
        SELECT * FROM candidates p WHERE {FILTER} ORDER BY {ORDER} LIMIT :limit OFFSET :offset
      ) SELECT p.id session_id, substr(s.candidate,1,180) candidate, substr(s.role,1,180) role,
               CASE WHEN c.ended_at IS NOT NULL THEN 'finished' WHEN s.consent THEN 'active' ELSE 'archived' END lifecycle,
               (SELECT count(*) FROM answers a WHERE a.session_id=p.id AND a.status='match' AND a.disposition='pending') review_count,
               p.assignee_email, p.assigned_by, p.priority, p.due_at, p.updated_at
        FROM paged p JOIN sessions s ON s.id=p.id
        LEFT JOIN session_context c ON c.session_id=p.id
        ORDER BY {ORDER}""", params)
    return {"viewer_email": viewer, "counts": {k: totals[k] for k in ("assigned_to_me", "high_priority", "unassigned")},
            "due_counts": {k: totals[k] for k in ("overdue", "due_soon")}, "items": [dict(r) for r in rows],
            "limit": limit, "page": page, "pages": pages, "filtered": matched}
