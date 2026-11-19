"""Compact, paged projections of the interview ledger."""

from typing import Literal

from fastapi import APIRouter, Query

from . import bulk_operations, store

router = APIRouter()
State = Literal["", "active", "finished", "archived"]
Review = Literal["", "pending", "clear"]
Order = Literal["newest", "oldest", "candidate", "pending"]

FAST_ORDERS = {
    "newest": "s.created_at DESC, s.id ASC",
    "oldest": "s.created_at ASC, s.id ASC",
    "candidate": "s.candidate COLLATE NOCASE ASC, s.id ASC",
}
STATUS_FILTERS = {
    "": "",
    "active": "AND c.ended_at IS NULL AND s.consent",
    "finished": "AND c.ended_at IS NOT NULL",
    "archived": "AND c.ended_at IS NULL AND NOT s.consent",
}
TAG_EXISTS_SESSION = "AND EXISTS (SELECT 1 FROM session_tags st WHERE st.session_id=s.id AND st.tag=:tag)"
TAG_EXISTS_CATALOG = "AND EXISTS (SELECT 1 FROM session_tags st WHERE st.session_id=interview_catalog.id AND st.tag=:tag)"


def fast_page_sql(order: str, status: str, *, has_tag: bool) -> str:
    status_clause = STATUS_FILTERS[status]
    tag_clause = TAG_EXISTS_SESSION if has_tag else ""
    order_clause = FAST_ORDERS[order]
    return f"""WITH paged AS MATERIALIZED (
 SELECT s.id, substr(s.candidate,1,180) candidate, substr(s.role,1,180) role,
        s.created_at, s.consent, c.ended_at
 FROM sessions s
 LEFT JOIN session_context c ON c.session_id=s.id
 WHERE NOT EXISTS (SELECT 1 FROM session_trash t WHERE t.session_id=s.id)
 {status_clause}
 {tag_clause}
 ORDER BY {order_clause}
 LIMIT :limit OFFSET :offset
)
SELECT p.id, p.candidate, p.role, p.created_at, p.consent, p.ended_at,
 (SELECT count(*) FROM answers a WHERE a.session_id=p.id) answer_count,
 (SELECT count(*) FROM answers a WHERE a.session_id=p.id AND a.status='match' AND a.disposition='pending') review_count,
 (SELECT a.id FROM answers a WHERE a.session_id=p.id AND a.status='match' AND a.disposition='pending'
  ORDER BY a.rowid LIMIT 1) first_pending_answer_id
FROM paged p"""


def filters(db, query, status, review, tag=""):
    terms = tuple(query.casefold().split())

    def matches(candidate, role):
        text = f"{candidate} {role}".casefold()
        return all(term in text for term in terms)

    db.create_function("ic_name_match", 2, matches, deterministic=True)
    return {"status": status, "review": review, "search": bool(terms), "tag": tag.strip()}


def cards(db, params, order, limit, offset=0):
    has_tag = bool(params.get("tag"))
    if not params["search"] and not params["review"] and order in FAST_ORDERS:
        sql = fast_page_sql(order, params["status"], has_tag=has_tag)
        bind = {"limit": limit, "offset": offset, **({"tag": params["tag"]} if has_tag else {})}
        rows = db.execute(sql, bind)
    else:
        tag_clause = TAG_EXISTS_CATALOG if has_tag else ""
        sql = f"""SELECT id,candidate,role,created_at,consent,ended_at,answer_count,review_count,first_pending_answer_id
         FROM interview_catalog WHERE (:status='' OR lifecycle=:status)
         AND (:review='' OR (:review='pending')=(review_count>0)) AND (:search=0 OR ic_name_match(candidate,role))
         {tag_clause}
         ORDER BY CASE WHEN :sort='pending' THEN review_count END DESC,
                  CASE WHEN :sort='candidate' THEN candidate END COLLATE NOCASE,
                  CASE WHEN :sort='oldest' THEN created_at END,
                  created_at DESC,id LIMIT :limit OFFSET :offset"""
        rows = db.execute(sql, {**params, "sort": order, "limit": limit, "offset": offset})
    items = [{**dict(row), "consent": bool(row["consent"])} for row in rows]
    tags_map = bulk_operations.tags_for_sessions(db, [item["id"] for item in items])
    for item in items:
        item["tags"] = tags_map.get(item["id"], [])
    return items


@router.get("/interviews/feed")
def feed(
    q: str = Query(default="", max_length=160),
    status: State = "",
    review: Review = "",
    tag: str = Query(default="", max_length=32),
    sort: Order = "newest",
    page: int = Query(default=1, ge=1, le=2_147_483_647),
    page_size: int = Query(default=25, ge=1, le=100),
):
    tag_filter = tag.strip()
    with store.connection() as db:
        total = db.execute("SELECT count(*) FROM active_sessions").fetchone()[0]
        if tag_filter and not bulk_operations.has_tags_table(db):
            return {"items": [], "total": total, "filtered": 0, "page": 1, "pages": 1, "page_size": page_size}
        params = filters(db, q, status, review, tag_filter)
        if not (params["search"] or status or review or tag_filter):
            filtered = total
        elif not params["search"] and not review:
            status_clause = STATUS_FILTERS[status]
            tag_clause = TAG_EXISTS_SESSION if tag_filter else ""
            bind = {"tag": tag_filter} if tag_filter else {}
            filtered = db.execute(
                f"SELECT count(*) FROM active_sessions s LEFT JOIN session_context c ON c.session_id=s.id WHERE 1=1 {status_clause} {tag_clause}",
                bind,
            ).fetchone()[0]
        else:
            tag_clause = TAG_EXISTS_CATALOG if tag_filter else ""
            filtered = db.execute(
                f"""SELECT count(*) FROM interview_catalog
                    WHERE (:status='' OR lifecycle=:status)
                    AND (:review='' OR (:review='pending')=(review_count>0))
                    AND (:search=0 OR ic_name_match(candidate,role)) {tag_clause}""",
                params,
            ).fetchone()[0]
        pages = max(1, (filtered + page_size - 1) // page_size)
        page = min(page, pages)
        items = cards(db, params, sort, page_size, (page - 1) * page_size)
    return {
        "items": items,
        "total": total,
        "filtered": filtered,
        "page": page,
        "pages": pages,
        "page_size": page_size,
    }


@router.get("/interviews/overview")
def overview():
    with store.connection() as db:
        totals = db.execute(
            """SELECT count(*),
                      count(CASE WHEN c.ended_at IS NULL AND s.consent THEN 1 END)
               FROM active_sessions s LEFT JOIN session_context c ON c.session_id=s.id"""
        ).fetchone()
        waiting = db.execute("""SELECT count(*),count(DISTINCT a.session_id) FROM answers a
            JOIN active_sessions s ON s.id=a.session_id WHERE a.status='match' AND a.disposition='pending'""").fetchone()
        active = cards(db, filters(db, "", "active", ""), "newest", 5)
        pending = cards(db, filters(db, "", "", "pending"), "pending", 10)
    return {
        "total": totals[0],
        "active_count": totals[1],
        "pending_count": waiting[0],
        "pending_sessions": waiting[1],
        "active": active,
        "pending": pending,
    }
