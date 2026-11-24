"""Page a filtered assignment queue and calculate its workspace totals in one read transaction."""
from datetime import datetime, timezone
import sqlite3

SOON_WINDOW_US = 48 * 60 * 60 * 1_000_000
# An older workspace has only unassigned sessions until the assignment table exists.
EMPTY_ASSIGNMENTS = """(SELECT NULL session_id, NULL assignee_email, NULL assigned_by,
                               NULL priority, NULL due_at, NULL updated_at WHERE 0)"""

ASSIGNMENT_FILTER = """
(:assignee = '' OR
 (:assignee = 'unassigned' AND session_id IS NULL) OR
 (:assignee <> 'unassigned' AND assignee_email = :email COLLATE NOCASE))
AND (:priority = '' OR priority = :priority)
"""
DUE_FILTER = "CASE :due WHEN '' THEN 1 WHEN 'overdue' THEN due_us < 0 WHEN 'soon' THEN due_us BETWEEN 0 AND :soon_us END"

ORDER = """CASE p.priority WHEN 'high' THEN 0 WHEN 'normal' THEN 1 WHEN 'low' THEN 2 ELSE 3 END,
           p.due_us IS NULL, p.due_us, p.last_update DESC, p.id"""


def _due_microseconds(raw, now):
    if not raw or not isinstance(raw, str):
        return None
    try:
        stamp = datetime.fromisoformat(raw.strip())
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    delta = stamp - now
    return (delta.days * 86400 + delta.seconds) * 1_000_000 + delta.microseconds


def read_page(db: sqlite3.Connection, *, viewer: str, assignee: str, priority: str, due: str,
              limit: int, page: int, has_assignments: bool, now: datetime, include_transition: bool = False) -> dict:
    relation = "session_assignments" if has_assignments else EMPTY_ASSIGNMENTS
    query = f"FROM active_sessions s LEFT JOIN {relation} sa ON sa.session_id = s.id"
    # Keep the same cutoff for both totals and page contents. Accept the ISO timestamps
    # used by older records, including offsets and microseconds at the 48 hour boundary.
    db.create_function("ic_due_us", 1, lambda value: _due_microseconds(value, now), deterministic=True)
    assignee = assignee.strip().lower()
    params = {"viewer": viewer, "assignee": assignee, "email": viewer if assignee == "me" else assignee,
              "priority": priority, "due": due, "limit": limit, "soon_us": SOON_WINDOW_US}

    # Scheduled becomes soon at the 48-hour boundary. A deadline remains
    # soon through its precise timestamp and becomes overdue one microsecond later.
    transition = "" if not include_transition else """,
               min(CASE WHEN due_us > :soon_us THEN due_us - :soon_us
                        WHEN due_us >= 0 THEN due_us + 1 END) next_us"""
    totals = db.execute(f"""WITH states AS MATERIALIZED (
        SELECT sa.session_id, sa.assignee_email, sa.priority, ic_due_us(sa.due_at) due_us {query}
      ) SELECT count(CASE WHEN assignee_email = :viewer COLLATE NOCASE THEN 1 END) assigned_to_me,
               count(CASE WHEN priority = 'high' THEN 1 END) high_priority,
               count(CASE WHEN session_id IS NULL THEN 1 END) unassigned,
               count(CASE WHEN due_us < 0 THEN 1 END) overdue,
               count(CASE WHEN due_us BETWEEN 0 AND :soon_us THEN 1 END) due_soon,
               count(CASE WHEN {ASSIGNMENT_FILTER} AND {DUE_FILTER} THEN 1 END) filtered{transition}
        FROM states""", params).fetchone()
    matched = totals["filtered"]
    pages = max(1, (matched + limit - 1) // limit)
    page = min(page, pages)
    params["offset"] = (page - 1) * limit

    # Page before loading candidate text and counting pending answers. The hint also
    # prevents SQLite from flattening the result projection into the full-set sort.
    rows = db.execute(f"""WITH candidates AS MATERIALIZED (
        SELECT s.id, sa.priority, coalesce(sa.updated_at, s.created_at) last_update,
               CASE WHEN sa.due_at IS NOT NULL THEN ic_due_us(sa.due_at) END due_us
        {query} WHERE {ASSIGNMENT_FILTER}
      ), paged AS MATERIALIZED (
        SELECT p.id,p.priority,p.due_us,p.last_update FROM candidates p
        WHERE {DUE_FILTER} ORDER BY {ORDER} LIMIT :limit OFFSET :offset
      ) SELECT p.id session_id, substr(s.candidate,1,180) candidate, substr(s.role,1,180) role,
               CASE WHEN c.ended_at IS NOT NULL THEN 'finished' WHEN s.consent THEN 'active' ELSE 'archived' END lifecycle,
               (SELECT count(*) FROM answers a WHERE a.session_id=p.id AND a.status='match' AND a.disposition='pending') review_count,
               sa.assignee_email, sa.assigned_by, p.priority, sa.due_at, sa.updated_at
        FROM paged p JOIN sessions s ON s.id=p.id
        LEFT JOIN {relation} sa ON sa.session_id=p.id
        LEFT JOIN session_context c ON c.session_id=p.id
        ORDER BY {ORDER}""", params)
    result = {"viewer_email": viewer, "counts": {k: totals[k] for k in ("assigned_to_me", "high_priority", "unassigned")},
              "due_counts": {k: totals[k] for k in ("overdue", "due_soon")}, "items": [dict(r) for r in rows],
              "limit": limit, "page": page, "pages": pages, "filtered": matched}
    if include_transition:
        result["next_transition_ms"] = None if totals["next_us"] is None else (totals["next_us"] + 999) // 1000
    return result
