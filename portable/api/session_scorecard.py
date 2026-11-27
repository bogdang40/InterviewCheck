"""Per-session rubric scorecards and structured panel handoff notes."""
from typing import Any, Literal
from uuid import UUID, uuid4
import hashlib
import json
import sqlite3

from fastapi import APIRouter, HTTPException, Query, Request
from pydantic import Field, field_validator
from starlette.concurrency import run_in_threadpool

from . import access, handoff_page, prompt_framing, session_rubric, sql_script, store
from .models import Input
from .scorecard_math import weighted_score_pct

router = APIRouter()

HandoffCategory = Literal["observation", "follow_up", "decision", "concern"]

SCHEMA = """
CREATE TABLE IF NOT EXISTS session_scorecards (
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  criterion_id TEXT NOT NULL,
  criterion_label TEXT NOT NULL,
  weight INTEGER NOT NULL DEFAULT 1,
  rating INTEGER NOT NULL CHECK(rating BETWEEN 1 AND 5),
  rationale TEXT NOT NULL DEFAULT '',
  updated_by TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (session_id, criterion_id)
);
CREATE TABLE IF NOT EXISTS session_handoff_notes (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  author_email TEXT NOT NULL,
  category TEXT NOT NULL CHECK(category IN ('observation','follow_up','decision','concern')),
  body TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_handoff_notes_session
  ON session_handoff_notes(session_id, created_at DESC, id DESC);
"""


def migrate(db: sqlite3.Connection) -> None:
    sql_script.execute(db, SCHEMA)


class ScorecardItemInput(Input):
    criterion_id: str = Field(min_length=1, max_length=256)
    criterion_label: str = Field(min_length=1, max_length=500)
    weight: int = Field(default=1, ge=1, le=100)
    rating: int = Field(ge=1, le=5)
    rationale: str = Field(default="", max_length=2000)

    @field_validator("criterion_id", "criterion_label", mode="after")
    @classmethod
    def clean_identifier(cls, value: str) -> str:
        cleaned = prompt_framing.strip_control_chars(value, allow_newlines=False).strip()
        if not cleaned:
            raise ValueError("Criterion field cannot be empty.")
        return cleaned

    @field_validator("rationale", mode="after")
    @classmethod
    def clean_rationale(cls, value: str) -> str:
        cleaned = prompt_framing.strip_control_chars(value, allow_newlines=True).strip()
        if len(cleaned) > 2000:
            raise ValueError("Rationale exceeds 2000 characters.")
        return cleaned


class ScorecardSaveInput(Input):
    items: list[ScorecardItemInput] = Field(max_length=25)
    expected_version: str | None = Field(default=None, pattern=r"^[0-9a-f]{64}$")

    @field_validator("items")
    @classmethod
    def require_unique_criteria(cls, value: list[ScorecardItemInput]) -> list[ScorecardItemInput]:
        seen: set[str] = set()
        for item in value:
            if item.criterion_id in seen:
                raise ValueError("Duplicate criterion_id values are not permitted.")
            seen.add(item.criterion_id)
        return value


class HandoffNoteInput(Input):
    category: HandoffCategory
    body: str = Field(min_length=1, max_length=2000)

    @field_validator("body", mode="after")
    @classmethod
    def clean_body(cls, value: str) -> str:
        cleaned = prompt_framing.strip_control_chars(value, allow_newlines=True).strip()
        if not cleaned:
            raise ValueError("Handoff note body cannot be empty.")
        if len(cleaned) > 2000:
            raise ValueError("Handoff note body exceeds 2000 characters.")
        return cleaned


def _roles_have_rubric(db: sqlite3.Connection) -> bool:
    return any(col[1] == "rubric_json" for col in db.execute("PRAGMA table_info(roles)"))


def _legacy_role_rubric(db: sqlite3.Connection, session_id: str) -> list[dict[str, Any]]:
    if not _roles_have_rubric(db):
        return []
    row = db.execute(
        "SELECT r.rubric_json FROM session_context c JOIN roles r ON r.id=c.role_id WHERE c.session_id=?",
        (session_id,),
    ).fetchone()
    if row is None or not row["rubric_json"]:
        return []
    try:
        raw = json.loads(row["rubric_json"])
    except (ValueError, TypeError):
        return []
    if not isinstance(raw, list):
        return []
    criteria: list[dict[str, Any]] = []
    for idx, entry in enumerate(raw, 1):
        if not isinstance(entry, dict):
            continue
        label = str(entry.get("criterion") or entry.get("criterion_label") or "").strip()
        if not label:
            continue
        cid = str(entry.get("id") or entry.get("criterion_id") or "").strip() or f"rubric-{idx}"
        try:
            weight = max(1, min(100, int(entry.get("weight", 1))))
        except (TypeError, ValueError):
            weight = 1
        criteria.append({"criterion_id": cid, "criterion_label": label, "weight": weight})
    return criteria


def _interview_rubric(db, session_id):
    snapshot = session_rubric.read(db, session_id)
    if snapshot is None:
        return _legacy_role_rubric(db, session_id), None
    items = [{"criterion_id": row.id, "criterion_label": row.criterion, "weight": row.weight}
             for row in snapshot.criteria]
    return items, snapshot


def _saved_scores(db: sqlite3.Connection, session_id: str) -> list[dict[str, Any]]:
    rows = db.execute(
        """SELECT criterion_id, criterion_label, weight, rating, rationale, updated_by, updated_at
           FROM session_scorecards WHERE session_id=? ORDER BY rowid""",
        (session_id,),
    )
    return [dict(row) for row in rows]


def _scorecard_version(session_id, rubric, saved, snapshot):
    # Bind the revision to the rubric the reviewer opened and the ordered saved scores.
    content = json.dumps([session_id, snapshot.model_dump() if snapshot else rubric, saved], sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(content.encode()).hexdigest()


def _load_scorecard_state(db: sqlite3.Connection, session_id: str, *, include_handoff_notes: bool = True) -> dict[str, Any]:
    store.get_summary(db, session_id)
    rubric, snapshot = _interview_rubric(db, session_id)
    saved_rows = _saved_scores(db, session_id)
    saved_by_id = {row["criterion_id"]: row for row in saved_rows}
    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    for crit in rubric:
        cid = crit["criterion_id"]
        if cid in seen:
            continue
        seen.add(cid)
        saved = saved_by_id.get(cid)
        if saved is not None:
            items.append(saved)
        else:
            items.append({
                "criterion_id": cid,
                "criterion_label": crit["criterion_label"],
                "weight": crit["weight"],
                "rating": None,
                "rationale": "",
                "updated_by": None,
                "updated_at": None,
            })
    for row in saved_rows:
        cid = row["criterion_id"]
        if cid not in seen:
            seen.add(cid)
            items.append(row)
    state = {
        "session_id": session_id,
        "version": _scorecard_version(session_id, rubric, saved_rows, snapshot),
        "rubric_snapshot": snapshot.model_dump() if snapshot else None,
        "items": items,
        "weighted_score_pct": weighted_score_pct(items),
        "handoff_notes": handoff_page.all_notes(db, session_id) if include_handoff_notes else [],
    }
    if not include_handoff_notes:
        state["handoff_notes_paged"] = True
    return state


@router.get("/sessions/{sid}/scorecard")
def get_scorecard(sid: UUID, include_handoff_notes: bool = True):
    with store.connection() as db:
        return _load_scorecard_state(db, str(sid), include_handoff_notes=include_handoff_notes)


@router.put("/sessions/{sid}/scorecard")
async def save_scorecard(sid: UUID, payload: ScorecardSaveInput, request: Request, include_handoff_notes: bool = True):
    _, actor_email = await access.optional_actor(request)
    return await run_in_threadpool(_save_scorecard, str(sid), payload, actor_email, include_handoff_notes)


def _matches_saved_score(row, fields):
    return row is not None and all(row[name] == value for name, value in fields.items())


def _save_scorecard(key: str, payload: ScorecardSaveInput, actor_email: str, include_handoff_notes: bool = True):
    now = store.timestamp()
    with store.connection(write=True) as db:
        store.get_summary(db, key)
        previous = _saved_scores(db, key)
        if payload.expected_version is not None:
            rubric, snapshot = _interview_rubric(db, key)
            current_version = _scorecard_version(key, rubric, previous, snapshot)
            if current_version != payload.expected_version:
                raise HTTPException(409, "The saved scorecard changed. Review the latest scores before saving.",
                                    headers={"X-InterviewCheck-Conflict": "scorecard-version"})
        values = [item.model_dump() for item in payload.items]
        if len(values) == len(previous) and all(_matches_saved_score(row, item) for row, item in zip(previous, values)):
            return _load_scorecard_state(db, key, include_handoff_notes=include_handoff_notes)
        previous_by_id = {row["criterion_id"]: row for row in previous}
        db.execute("DELETE FROM session_scorecards WHERE session_id=?", (key,))
        for item, fields in zip(payload.items, values):
            prior = previous_by_id.get(item.criterion_id)
            unchanged = _matches_saved_score(prior, fields)
            db.execute(
                """INSERT INTO session_scorecards(
                       session_id, criterion_id, criterion_label, weight, rating, rationale, updated_by, updated_at
                   ) VALUES (?,?,?,?,?,?,?,?)""",
                (
                    key,
                    item.criterion_id,
                    item.criterion_label,
                    item.weight,
                    item.rating,
                    item.rationale,
                    prior["updated_by"] if unchanged else actor_email,
                    prior["updated_at"] if unchanged else now,
                ),
            )
        return _load_scorecard_state(db, key, include_handoff_notes=include_handoff_notes)


@router.get("/sessions/{sid}/handoff-notes")
def list_handoff_notes(sid: UUID, category: HandoffCategory | None = None, limit: int = Query(default=20, ge=1, le=50),
                       cursor: str = Query(default="", max_length=handoff_page.MAX_CURSOR)):
    with store.connection() as db:
        return handoff_page.read(db, str(sid), category, limit, cursor)


@router.post("/sessions/{sid}/handoff-notes", status_code=201)
async def create_handoff_note(sid: UUID, payload: HandoffNoteInput, request: Request):
    _, actor_email = await access.optional_actor(request)
    return await run_in_threadpool(_save_handoff_note, str(sid), payload, actor_email)


def _save_handoff_note(key: str, payload: HandoffNoteInput, actor_email: str):
    note_id = str(uuid4())
    created_at = store.timestamp()
    with store.connection(write=True) as db:
        store.get_summary(db, key)
        db.execute(
            """INSERT INTO session_handoff_notes(id, session_id, author_email, category, body, created_at)
               VALUES (?,?,?,?,?,?)""",
            (note_id, key, actor_email, payload.category, payload.body, created_at),
        )
    return {
        "id": note_id,
        "session_id": key,
        "author_email": actor_email,
        "category": payload.category,
        "body": payload.body,
        "created_at": created_at,
    }


@router.delete("/sessions/{sid}/handoff-notes/{nid}")
def delete_handoff_note(sid: UUID, nid: UUID):
    key = str(sid)
    note_id = str(nid)
    with store.connection(write=True) as db:
        store.get_summary(db, key)
        cur = db.execute(
            "DELETE FROM session_handoff_notes WHERE id=? AND session_id=?",
            (note_id, key),
        )
        if cur.rowcount == 0:
            raise HTTPException(404, "Handoff note does not exist in this session.")
    return {"deleted": True, "id": note_id}
