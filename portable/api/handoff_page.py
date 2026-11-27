"""Read bounded panel notes after a position in one interview and category."""
import base64
from datetime import datetime
import hashlib
import hmac
import unicodedata
from uuid import UUID

from fastapi import HTTPException

from . import retention_visibility


MAX_CURSOR = 256
FIELDS = "id, session_id, author_email, category, body, created_at"
ORDER = "created_at DESC, id DESC"


def _boundary(stamp, note_id):
    if (not isinstance(stamp, str) or len(stamp) > 64 or any(unicodedata.category(char) == "Cc" for char in stamp)
            or datetime.fromisoformat(stamp).utcoffset() is None
            or not isinstance(note_id, str) or len(note_id) != 36 or str(UUID(note_id)) != note_id.lower()):
        raise ValueError("Invalid saved note position.")
    return b"\x01" + stamp.encode("utf-8") + b"\0" + note_id.encode("ascii")


def _token(sid, category, boundary):
    scope = sid.encode("ascii") + b"\0" + (category or "").encode("ascii")
    binding = hashlib.sha256(boundary + b"\0handoff\0" + scope).digest()[:16]
    return base64.urlsafe_b64encode(boundary + binding).decode("ascii").rstrip("=")


def _encode(sid, category, item):
    try:
        token = _token(sid, category, _boundary(item["created_at"], item["id"]))
        if len(token) > MAX_CURSOR:
            raise ValueError
        return token
    except (ValueError, UnicodeError, OverflowError) as exc:
        raise HTTPException(409, "A saved handoff note cannot provide a continuation for this page.") from exc


def _decode(sid, category, cursor):
    try:
        if len(cursor) > MAX_CURSOR:
            raise ValueError
        raw = base64.b64decode(cursor + "=" * (-len(cursor) % 4), altchars=b"-_", validate=True)
        stamp, note_id = raw[1:-16].split(b"\0")
        stamp, note_id = stamp.decode("utf-8"), note_id.decode("ascii")
        expected = _token(sid, category, _boundary(stamp, note_id))
        if not hmac.compare_digest(cursor, expected):
            raise ValueError
        return stamp, note_id
    except (ValueError, UnicodeError, OverflowError) as exc:
        raise HTTPException(422, "This handoff note cursor is invalid. Start from the first page.") from exc


def _has_notes_table(db):
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_handoff_notes'").fetchone() is not None


def all_notes(db, sid):
    if not _has_notes_table(db):
        return []
    return [dict(row) for row in db.execute(f"SELECT {FIELDS} FROM session_handoff_notes WHERE session_id=? ORDER BY {ORDER}", (sid,))]


def read(db, sid, category, limit, cursor):
    active = db.execute("SELECT 1 FROM active_sessions WHERE id=?", (sid,)).fetchone()
    if active is None:
        retention_visibility.require_available(db, sid)
        raise HTTPException(404, "Session does not exist.")
    after = _decode(sid, category, cursor) if cursor else None
    if not _has_notes_table(db):
        return {"items": [], "total": 0, "next_cursor": None}

    scope = "session_id=?" if category is None else "session_id=? AND category=?"
    params = (sid,) if category is None else (sid, category)
    total = db.execute(f"SELECT count(*) FROM session_handoff_notes WHERE {scope}", params).fetchone()[0]
    seek = " AND (created_at,id) < (?,?)" if after else ""
    # Determine the page, including its lookahead, using only index keys.
    # Fetch author identities and note content for visible rows in this transaction.
    keys = [r[0] for r in db.execute(
        f"SELECT rowid FROM session_handoff_notes WHERE {scope}{seek} ORDER BY {ORDER} LIMIT ?",
        (*params, *(after or ()), limit + 1),
    )]
    items = []
    if keys:
        visible = keys[:limit]
        marks = ",".join("?" for _ in visible)
        items = [dict(row) for row in db.execute(
            f"SELECT {FIELDS} FROM session_handoff_notes WHERE rowid IN ({marks}) ORDER BY {ORDER}", visible,
        )]
    return {"items": items, "total": total, "next_cursor": _encode(sid, category, items[-1]) if len(keys) > limit else None}
