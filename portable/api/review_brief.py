"""Build an opt-in handoff from a single, consistent SQLite snapshot."""

from collections import Counter
import hashlib
import json
from uuid import UUID

from fastapi import APIRouter, HTTPException
from fastapi.responses import Response
from pydantic import Field

from . import retention_visibility, store
from .models import Input, RequestID
from .report import literal

router = APIRouter()
EXCERPT_CHARS = 240
OUTCOMES = {
    "pending": "Pending passage review",
    "unresolved": "Unresolved",
    "explained": "Explained",
    "disclosed": "Assistance disclosed by the candidate",
    "no_pending_match": "No pending match or recorded outcome",
}


class Selection(Input):
    excerpt_ids: list[RequestID] = Field(default_factory=list, max_length=100)
    note_ids: list[RequestID] = Field(default_factory=list, max_length=100)


class Download(Selection):
    preview_sha256: str = Field(pattern=r"^[a-f0-9]{64}$")


def markdown(blocks):
    def format_block(block):
        kind, text = block["kind"], block["text"]
        if kind == "literal":
            return literal(text)
        prefix = {"title": "# ", "heading": "## ", "subheading": "### ", "paragraph": ""}[kind]
        return prefix + text

    return "\n\n".join(format_block(block) for block in blocks) + "\n"


def group_ordinals(numbers):
    """Compact consecutive exchange numbers for a readable long interview brief."""
    ranges = []
    for n in numbers:
        if ranges and n == ranges[-1][1] + 1:
            ranges[-1][1] = n
        else:
            ranges.append([n, n])
    return ", ".join(str(first) if first == last else f"{first} to {last}" for first, last in ranges)


def build(db, sid, selection):
    # No candidate, question, role, source, prior score or raw legacy payload is selected.
    session = db.execute(
        """SELECT s.id,s.consent,c.ended_at FROM active_sessions s
        LEFT JOIN session_context c ON c.session_id=s.id WHERE s.id=?""",
        (sid,),
    ).fetchone()
    if session is None:
        retention_visibility.require_available(db, sid)
        raise HTTPException(404, "Session does not exist.")
    excerpts = {str(value) for value in selection.excerpt_ids}
    notes = {str(value) for value in selection.note_ids}
    rows = db.execute(
        """SELECT id,status,disposition,length(answer)>0 has_answer,length(note)>0 has_note,
        CASE WHEN id IN (SELECT value FROM json_each(?)) THEN substr(answer,1,?) END excerpt,
        CASE WHEN id IN (SELECT value FROM json_each(?)) THEN note END selected_note
        FROM answers WHERE session_id=? ORDER BY rowid""",
        (json.dumps(sorted(excerpts)), EXCERPT_CHARS + 1, json.dumps(sorted(notes)), sid),
    )
    options, included = [], []
    groups = {kind: [] for kind in OUTCOMES}
    evidence = Counter()
    for ordinal, row in enumerate(rows, 1):
        aid = row["id"]
        kind = row["disposition"]
        if kind == "pending" and row["status"] != "match":
            kind = "no_pending_match"
        groups[kind].append(ordinal)
        evidence[row["status"]] += 1
        options.append(
            {
                "id": aid,
                "ordinal": ordinal,
                "has_answer": bool(row["has_answer"]),
                "has_note": bool(row["has_note"]),
            }
        )
        excerpt = row["excerpt"]
        if excerpt and len(excerpt) > EXCERPT_CHARS:
            excerpt = excerpt[:EXCERPT_CHARS] + "…"
        if excerpt or row["selected_note"]:
            included.append((ordinal, excerpt, row["selected_note"]))
    missing = (excerpts | notes) - {option["id"] for option in options}
    if missing:
        raise HTTPException(422, "A selected exchange does not belong to this interview.")
    blocks = []

    def add(kind, text):
        blocks.append({"kind": kind, "text": text})

    add("title", "Interview review brief")
    add("paragraph", f"Session ID: {sid}")
    state = "Finished" if session["ended_at"] else "In progress" if session["consent"] else "Archive only"
    add("paragraph", f"Capture status: {state}. Exchanges recorded: {len(options)}.")
    add("heading", "Passage comparisons")
    if not options:
        add("paragraph", "No exchanges were recorded.")
    elif evidence["insufficient"] == len(options):
        add("paragraph", "All saved exchanges have limited comparison evidence.")
    elif not evidence["match"]:
        add("paragraph", "No eligible shared passage was found in exchanges with enough material to compare.")
    else:
        add(
            "paragraph",
            "A passage match identifies shared wording. Its significance depends on the agreed interview rules.",
        )
    add(
        "paragraph",
        f"Matched: {evidence['match']}. No passage match: {evidence['no_match']}. Limited evidence: {evidence['insufficient']}.",
    )
    add("heading", "Interviewer outcomes")
    for key, label in OUTCOMES.items():
        ordinals = groups[key]
        suffix = (
            f" (exchange {group_ordinals(ordinals)})"
            if len(ordinals) == 1
            else (f" (exchanges {group_ordinals(ordinals)})" if ordinals else "")
        )
        add("paragraph", f"{label}: {len(ordinals)}{suffix}.")
    if included:
        add("heading", "Selected interview details")
        for ordinal, excerpt, note in included:
            add("subheading", f"Exchange {ordinal}")
            if excerpt:
                add("paragraph", "Answer excerpt")
                add("literal", excerpt)
            if note:
                add("paragraph", "Interviewer note")
                add("literal", note)
    body = markdown(blocks)
    return {
        "blocks": blocks,
        "markdown": body,
        "preview_sha256": hashlib.sha256(body.encode()).hexdigest(),
        "outcomes": {key: len(value) for key, value in groups.items()},
        "exchanges": options,
    }


@router.get("/sessions/{sid}/brief")
def default_brief(sid: UUID):
    with store.connection() as db:
        return build(db, str(sid), Selection())


@router.post("/sessions/{sid}/brief")
def preview(sid: UUID, selection: Selection):
    with store.connection() as db:
        return build(db, str(sid), selection)


@router.post("/sessions/{sid}/brief/download")
def download(sid: UUID, selection: Download):
    with store.connection() as db:
        result = build(db, str(sid), selection)
    if result["preview_sha256"] != selection.preview_sha256:
        raise HTTPException(409, "The saved interview changed. Refresh the preview before downloading.")
    return Response(
        result["markdown"],
        media_type="text/markdown; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="review-brief-{sid}.md"'},
    )
