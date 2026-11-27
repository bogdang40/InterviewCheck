"""Select bounded snippets after choosing the highest ranked field for each record."""
from . import search_fts
from .search_cursor import Position


# Only these fixed identifiers can enter the query text. Literal values and the
# continuation position are always bound parameters.
TITLE_FIELDS = (
    ("role", "role_name", "name", 0),
    ("session", "candidate", "candidate", 1),
    ("session", "role", "role", 2),
    ("answer", "question", "question", 3),
)
BODY_FIELD = ("answer", "answer", "answer", 4)
SOURCES = {
    "role": ("roles r", "r", "NULL", "fts_roles"),
    "session": ("active_sessions s", "s", "s.id", "fts_sessions"),
    "answer": ("answers a JOIN active_sessions s ON s.id=a.session_id", "a", "a.session_id", "fts_answers"),
}


def _candidates(field, fts, body_filter):
    kind, name, column, priority = field
    source, alias, session_id, index = SOURCES[kind]
    conditions = []
    if fts:
        conditions.append(f"{alias}.rowid IN (SELECT rowid FROM {index} WHERE {column} MATCH :fts)")
    if name == "answer" and body_filter:
        conditions.append(body_filter)
    where = " WHERE " + " AND ".join(conditions) if conditions else ""
    return (f"SELECT '{kind}' kind, {alias}.id id, {session_id} session_id, '{name}' field, "
            f"{priority} priority, ic_position({alias}.{column}) pos FROM {source}{where}")


def _selected(kind, body_stage, metadata):
    if kind == "role":
        join, label, matched = "JOIN roles r ON r.id=p.id", "r.name", "r.name"
        extra = ", NULL role, NULL created_at" if metadata else ""
    else:
        join, label = "JOIN sessions s ON s.id=p.session_id", "s.candidate"
        extra = ",substr(s.role,1,180) role,substr(s.created_at,1,64) created_at" if metadata else ""
        if kind == "session":
            matched = "CASE p.priority WHEN 1 THEN s.candidate ELSE s.role END"
        else:
            join += " JOIN answers a ON a.id=p.id"
            matched = "a.answer" if body_stage else "a.question"
    return f"SELECT p.*,substr({label},1,180) label,{matched} matched{extra} FROM page p {join} WHERE p.kind='{kind}'"


def _stage(db, fields, params, *, fts, metadata, body_filter=""):
    kinds = tuple(dict.fromkeys(field[0] for field in fields))
    body_stage = fields == [BODY_FIELD]
    sources = " UNION ALL ".join(_candidates(field, fts, body_filter) for field in fields)
    # Only session titles have two possible winning fields within one stage.
    pick = "row_number() OVER (PARTITION BY kind,id ORDER BY rank,priority)" if "session" in kinds else "1"
    selected = " UNION ALL ".join(_selected(kind, body_stage, metadata) for kind in kinds)
    extra = ",role,created_at" if metadata else ""
    query = f"""
      WITH candidates AS MATERIALIZED ({sources}), ranked AS (
        SELECT *, {3 if body_stage else 0} + CASE pos WHEN -2 THEN 0 WHEN 0 THEN 1 ELSE 2 END rank
        FROM candidates WHERE pos != -1
      ), winners AS (
        SELECT *,{pick} pick FROM ranked
      ), page AS MATERIALIZED (
        SELECT * FROM winners WHERE pick=1 AND (rank,priority,id) > (:rank,:priority,:id)
        ORDER BY rank,priority,id LIMIT :limit
      ), selected AS ({selected})
      SELECT kind,id,session_id,label,field,
        CASE WHEN pos > :context THEN '…' ELSE '' END ||
        substr(matched,max(1,pos-:context+1),180) ||
        CASE WHEN length(matched)>max(0,pos-:context)+180 THEN '…' ELSE '' END snippet,
        rank,priority{extra} FROM selected ORDER BY rank,priority,id
    """
    return [dict(row) for row in db.execute(query, params)]


def read(db, needle, kinds, *, limit, context, after, metadata):
    fts = search_fts.can_use_fts(needle) and search_fts.has_fts(db)
    start = after or Position(-1, -1, "")
    params = {"rank": start.rank, "priority": start.priority, "id": start.id, "limit": limit,
              "context": context, "fts": search_fts.fts_phrase(needle) if fts else ""}
    rows = []
    if start.rank < 3:
        fields = [field for field in TITLE_FIELDS if field[0] in kinds]
        rows = _stage(db, fields, params, fts=fts, metadata=metadata)
    if "answer" in kinds and len(rows) < limit:
        params["limit"] = limit - len(rows)
        if after is None:
            # This short first stage contains EVERY title hit. Exclude its
            # answer IDs before taking the body lookahead, without reading questions again.
            seen = {f"seen{i}": row["id"] for i, row in enumerate(rows) if row["kind"] == "answer"}
            params.update(seen)
            keys = ",".join(":" + name for name in seen)
            body_filter = f"a.id NOT IN ({keys})" if seen else ""
        else:
            # Prior pages may own a question hit for this answer. A body hit
            # is eligible only if the question does not match anywhere.
            body_filter = "ic_position(a.question) = -1"
        rows.extend(_stage(db, [BODY_FIELD], params, fts=fts, metadata=metadata, body_filter=body_filter))
    return rows
