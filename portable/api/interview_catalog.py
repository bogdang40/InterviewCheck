"""Compact, paged projections of the interview ledger."""

from typing import Literal

from fastapi import APIRouter, Query

from . import store

router = APIRouter()
State = Literal["", "active", "finished", "archived"]
Review = Literal["", "pending", "clear"]
Order = Literal["newest", "oldest", "candidate", "pending"]

FILTER_COUNT = """SELECT count(*) FROM interview_catalog
 WHERE (:status='' OR lifecycle=:status)
 AND (:review='' OR (:review='pending')=(review_count>0))
 AND (:search=0 OR ic_name_match(candidate,role))"""
PAGE = """SELECT id,candidate,role,created_at,consent,ended_at,answer_count,review_count,first_pending_answer_id
 FROM interview_catalog WHERE (:status='' OR lifecycle=:status)
 AND (:review='' OR (:review='pending')=(review_count>0)) AND (:search=0 OR ic_name_match(candidate,role))
 ORDER BY CASE WHEN :sort='pending' THEN review_count END DESC,
          CASE WHEN :sort='candidate' THEN candidate END COLLATE NOCASE,
          CASE WHEN :sort='oldest' THEN created_at END,
          created_at DESC,id LIMIT :limit OFFSET :offset"""


def filters(db, query, status, review):
    terms = tuple(query.casefold().split())

    def matches(candidate, role):
        text = f"{candidate} {role}".casefold()
        return all(term in text for term in terms)

    db.create_function("ic_name_match", 2, matches, deterministic=True)
    return {"status": status, "review": review, "search": bool(terms)}


def cards(db, params, order, limit, offset=0):
    rows = db.execute(PAGE, {**params, "sort": order, "limit": limit, "offset": offset})
    return [{**dict(row), "consent": bool(row["consent"])} for row in rows]


@router.get("/interviews/feed")
def feed(
    q: str = Query(default="", max_length=160),
    status: State = "",
    review: Review = "",
    sort: Order = "newest",
    page: int = Query(default=1, ge=1, le=2_147_483_647),
    page_size: int = Query(default=25, ge=1, le=100),
):
    with store.connection() as db:
        params = filters(db, q, status, review)
        total = db.execute("SELECT count(*) FROM active_sessions").fetchone()[0]
        filtered = (
            total
            if not (params["search"] or status or review)
            else db.execute(FILTER_COUNT, params).fetchone()[0]
        )
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
        totals = db.execute("""SELECT count(*),count(CASE WHEN lifecycle='active' THEN 1 END)
                               FROM interview_catalog""").fetchone()
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
