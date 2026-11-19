"""Bounded interview summaries and literal search for the local operator."""

from typing import Literal

from fastapi import APIRouter
from pydantic import Field

from . import search_fts, store
from .models import Input

router = APIRouter()
Kind = Literal["role", "session", "answer"]


class Search(Input):
    query: str = Field(max_length=160)
    kinds: list[Kind] = Field(
        default_factory=lambda: ["role", "session", "answer"], min_length=1, max_length=3
    )
    limit: int = Field(default=20, ge=1, le=50)


def search_position(pattern, value):
    """Return a source character offset. -2 is exact, -1 is absent."""
    if not value:
        return -1
    folded = value.casefold()
    if folded == pattern:
        return -2
    pos = folded.find(pattern)
    if pos <= 0 or len(value) == len(folded):
        return pos
    # A Unicode case fold can expand. Convert the hit back to a source offset
    # only in that uncommon case; SQLite substr uses source character offsets.
    width = 0
    for offset, char in enumerate(value):
        width += len(char.casefold())
        if width > pos:
            return offset
    return -1


SEARCH_SQL = """
WITH tagged(kind,id,session_id,field,priority,pos) AS (
 SELECT 'role',id,NULL,'role_name',0,ic_position(name) FROM roles WHERE :roles
 UNION ALL SELECT 'session',id,id,'candidate',1,ic_position(candidate) FROM active_sessions WHERE :sessions
 UNION ALL SELECT 'session',id,id,'role',2,ic_position(role) FROM active_sessions WHERE :sessions
 UNION ALL SELECT 'answer',a.id,a.session_id,'question',3,ic_position(a.question)
  FROM answers a JOIN active_sessions s ON s.id=a.session_id WHERE :answers
 UNION ALL SELECT 'answer',a.id,a.session_id,'answer',4,ic_position(a.answer)
  FROM answers a JOIN active_sessions s ON s.id=a.session_id WHERE :answers
), matches AS MATERIALIZED (
 SELECT *, (CASE WHEN field='answer' THEN 3 ELSE 0 END) +
           (CASE pos WHEN -2 THEN 0 WHEN 0 THEN 1 ELSE 2 END) AS rank
 FROM tagged WHERE pos != -1
), best AS (
 SELECT *,row_number() OVER (PARTITION BY kind,id ORDER BY rank,priority) AS pick FROM matches
), page AS MATERIALIZED (
 SELECT * FROM best WHERE pick=1 ORDER BY rank,priority,id LIMIT :limit
), selected AS (
 SELECT p.kind,p.id,p.session_id,p.field,p.pos,p.rank,p.priority,
  substr(COALESCE(r.name,s.candidate,''),1,180) label,
  CASE p.field WHEN 'role_name' THEN r.name WHEN 'candidate' THEN s.candidate WHEN 'role' THEN s.role
    WHEN 'question' THEN a.question ELSE a.answer END AS matched
 FROM page p LEFT JOIN roles r ON p.kind='role' AND r.id=p.id
 LEFT JOIN active_sessions s ON s.id=p.session_id LEFT JOIN answers a ON p.kind='answer' AND a.id=p.id
)
SELECT kind,id,session_id,label,field,
 CASE WHEN pos > :context THEN '…' ELSE '' END ||
 substr(matched,max(1,pos-:context+1),180) ||
 CASE WHEN length(matched)>max(0,pos-:context)+180 THEN '…' ELSE '' END AS snippet
FROM selected ORDER BY rank,priority,id
"""

FTS_STAGE1_SQL = """
WITH tagged(kind,id,session_id,field,priority,pos) AS (
 SELECT 'role',r.id,NULL,'role_name',0,ic_position(r.name)
  FROM roles r WHERE :roles AND r.rowid IN (SELECT rowid FROM fts_roles WHERE name MATCH :fts)
 UNION ALL SELECT 'session',s.id,s.id,'candidate',1,ic_position(s.candidate)
  FROM active_sessions s WHERE :sessions AND s.rowid IN (SELECT rowid FROM fts_sessions WHERE candidate MATCH :fts)
 UNION ALL SELECT 'session',s.id,s.id,'role',2,ic_position(s.role)
  FROM active_sessions s WHERE :sessions AND s.rowid IN (SELECT rowid FROM fts_sessions WHERE role MATCH :fts)
 UNION ALL SELECT 'answer',a.id,a.session_id,'question',3,ic_position(a.question)
  FROM answers a JOIN active_sessions s ON s.id=a.session_id
  WHERE :answers AND a.rowid IN (SELECT rowid FROM fts_answers WHERE question MATCH :fts)
), matches AS MATERIALIZED (
 SELECT *, (CASE pos WHEN -2 THEN 0 WHEN 0 THEN 1 ELSE 2 END) AS rank
 FROM tagged WHERE pos != -1
), best AS (
 SELECT *,row_number() OVER (PARTITION BY kind,id ORDER BY rank,priority) AS pick FROM matches
), page AS MATERIALIZED (
 SELECT * FROM best WHERE pick=1 ORDER BY rank,priority,id LIMIT :limit
), selected AS (
 SELECT p.kind,p.id,p.session_id,p.field,p.pos,p.rank,p.priority,
  substr(COALESCE(r.name,s.candidate,''),1,180) label,
  CASE p.field WHEN 'role_name' THEN r.name WHEN 'candidate' THEN s.candidate WHEN 'role' THEN s.role
    ELSE a.question END AS matched
 FROM page p LEFT JOIN roles r ON p.kind='role' AND r.id=p.id
 LEFT JOIN active_sessions s ON s.id=p.session_id LEFT JOIN answers a ON p.kind='answer' AND a.id=p.id
)
SELECT kind,id,session_id,label,field,
 CASE WHEN pos > :context THEN '…' ELSE '' END ||
 substr(matched,max(1,pos-:context+1),180) ||
 CASE WHEN length(matched)>max(0,pos-:context)+180 THEN '…' ELSE '' END AS snippet
FROM selected ORDER BY rank,priority,id
"""

FTS_STAGE2_SQL = """
WITH hits AS (
 SELECT a.id,a.session_id,s.candidate,a.answer,ic_position(a.answer) AS pos
 FROM answers a JOIN active_sessions s ON s.id=a.session_id
 WHERE a.rowid IN (SELECT rowid FROM fts_answers WHERE answer MATCH :fts)
), ranked AS (
 SELECT 'answer' AS kind,id,session_id,substr(candidate,1,180) AS label,'answer' AS field,answer,pos,
  (CASE pos WHEN -2 THEN 3 WHEN 0 THEN 4 ELSE 5 END) AS rank
 FROM hits WHERE pos != -1
 ORDER BY rank,id LIMIT :limit
)
SELECT kind,id,session_id,label,field,
 CASE WHEN pos > :context THEN '…' ELSE '' END ||
 substr(answer,max(1,pos-:context+1),180) ||
 CASE WHEN length(answer)>max(0,pos-:context)+180 THEN '…' ELSE '' END AS snippet
FROM ranked ORDER BY rank,id
"""


def _fts_search(db, needle, body, limit, context):
    fts = search_fts.fts_phrase(needle)
    roles = "role" in body.kinds
    sessions = "session" in body.kinds
    answers = "answer" in body.kinds
    rows = [
        dict(row)
        for row in db.execute(
            FTS_STAGE1_SQL,
            {"roles": roles, "sessions": sessions, "answers": answers, "fts": fts, "limit": limit, "context": context},
        )
    ]
    if answers and len(rows) < limit:
        seen = {row["id"] for row in rows if row["kind"] == "answer"}
        rem = limit - len(rows)
        extra = db.execute(
            FTS_STAGE2_SQL,
            {"fts": fts, "limit": rem + len(seen), "context": context},
        )
        for row in extra:
            if row["id"] in seen:
                continue
            rows.append(dict(row))
            if len(rows) >= limit:
                break
    return rows


@router.post("/search")
def search(body: Search):
    if not body.query:
        return {"items": [], "has_more": False}
    needle = body.query.casefold()
    limit = body.limit + 1
    context = min(45, 180 - len(body.query))
    with store.connection() as db:
        db.create_function("ic_position", 1, lambda text: search_position(needle, text), deterministic=True)
        if search_fts.can_use_fts(needle) and search_fts.has_fts(db):
            rows = _fts_search(db, needle, body, limit, context)
        else:
            rows = [
                dict(row)
                for row in db.execute(
                    SEARCH_SQL,
                    {
                        "roles": "role" in body.kinds,
                        "sessions": "session" in body.kinds,
                        "answers": "answer" in body.kinds,
                        "limit": limit,
                        "context": context,
                    },
                )
            ]
    return {"items": rows[: body.limit], "has_more": len(rows) > body.limit}
