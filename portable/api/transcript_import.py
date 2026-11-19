"""Atomically import selected WebVTT exchanges after the interviewer confirms attribution."""

import hashlib
import json
from typing import Annotated
from uuid import UUID, uuid5

from fastapi import APIRouter, HTTPException
from pydantic import Field, model_validator

from . import store
from .models import AnswerInput, Body, Input, Name, Question, RequestID

router = APIRouter()
MAX_EXCHANGES = 100
MAX_CHARACTERS = 500_000


class Exchange(Input):
    ordinal: int = Field(ge=1, le=10000)
    question: Question
    answer: Body
    first_cue: int | None = Field(default=None, ge=1, le=10000)
    last_cue: int | None = Field(default=None, ge=1, le=10000)
    start_ms: int = Field(ge=0, le=3599999999)
    end_ms: int = Field(ge=0, le=3599999999)

    @model_validator(mode="after")
    def time_range(self):
        if (self.first_cue is None) != (self.last_cue is None) or (
            self.first_cue is not None and self.last_cue < self.first_cue
        ):
            raise ValueError("Use both cue indexes in file order.")
        if self.end_ms < self.start_ms:
            raise ValueError("The exchange ends before it starts.")
        return self

    def coordinates(self):
        if self.first_cue is not None:
            return {"first_cue": self.first_cue, "last_cue": self.last_cue}
        return {"start_ms": self.start_ms, "end_ms": self.end_ms}


class TranscriptImport(Input):
    request_id: RequestID
    transcript_sha256: Annotated[str, Field(pattern=r"^[a-f0-9]{64}$")]
    candidate_speaker: Name
    interviewer_speakers: list[Name] = Field(min_length=1, max_length=24)
    exchanges: list[Exchange] = Field(min_length=1, max_length=MAX_EXCHANGES)

    @model_validator(mode="after")
    def selection(self):
        interviewers = set(self.interviewer_speakers)
        if self.candidate_speaker in interviewers or len(interviewers) != len(self.interviewer_speakers):
            raise ValueError("Choose distinct candidate and interviewer speakers.")
        if len({row.ordinal for row in self.exchanges}) != len(self.exchanges):
            raise ValueError("Select each exchange once.")
        if len({tuple(row.coordinates().items()) for row in self.exchanges}) != len(self.exchanges):
            raise ValueError(
                "Each exchange needs distinct source coordinates. Include cue indexes if timestamps repeat."
            )
        if sum(len(row.question) + len(row.answer) for row in self.exchanges) > MAX_CHARACTERS:
            raise ValueError("Selected exchanges exceed the 500,000 character limit.")
        return self


def as_json(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def exchange_id(session_uuid: UUID, origin: dict) -> UUID:
    """Stable across selections, edits and restoration into the original session."""
    keys = ("first_cue", "last_cue") if origin.get("first_cue") is not None else ("start_ms", "end_ms")
    identity = {key: origin[key] for key in ("format", "transcript_sha256", "candidate_speaker", *keys)}
    return uuid5(session_uuid, as_json(identity))


@router.post("/sessions/{sid}/imports/webvtt")
def load(sid: UUID, item: TranscriptImport):
    scope = {
        "format": "webvtt",
        "transcript_sha256": item.transcript_sha256,
        "candidate_speaker": item.candidate_speaker,
        "interviewer_speakers": sorted(item.interviewer_speakers),
    }
    ids = []
    saved = 0
    key = str(sid)
    ordered = item.exchanges
    payload = {**scope, "exchanges": [row.model_dump() for row in ordered]}
    digest = hashlib.sha256(as_json(payload).encode()).hexdigest()
    request_id = str(item.request_id)
    with store.connection(write=True) as db:
        summary = store.capture_context(db, key)
        if not summary["consent"]:
            raise HTTPException(409, "This session has no recorded notice for importing an interview.")
        receipt = db.execute("SELECT * FROM transcript_imports WHERE id=?", (request_id,)).fetchone()
        if receipt:
            if receipt["session_id"] != key or receipt["payload_sha256"] != digest:
                raise HTTPException(409, "This import request ID belongs to another selection.")
            ids = json.loads(receipt["answer_ids"])
            return {"saved": 0, "skipped": len(ids), "answer_ids": ids, "replayed": True}
        if summary["ended_at"]:
            raise HTTPException(409, "Reopen the interview before importing exchanges.")
        for row in ordered:
            stamp = hashlib.sha256(
                as_json(row.model_dump(exclude={"ordinal"}, exclude_none=True)).encode()
            ).hexdigest()
            origin = {
                **scope,
                "ordinal": row.ordinal,
                **row.coordinates(),
                "start_ms": row.start_ms,
                "end_ms": row.end_ms,
                "input_sha256": stamp,
            }
            aid = exchange_id(sid, origin)
            previous = db.execute(
                "SELECT import_origin FROM answers WHERE id=? AND session_id=?", (str(aid), key)
            ).fetchone()
            if previous is None:
                store.write_answer(
                    db, key, AnswerInput(id=aid, question=row.question, answer=row.answer), session=summary
                )
                db.execute("UPDATE answers SET import_origin=? WHERE id=?", (as_json(origin), str(aid)))
                saved += 1
            elif not previous[0] or json.loads(previous[0]).get("input_sha256") != stamp:
                raise HTTPException(
                    409,
                    f"Exchange {row.ordinal} was previously imported with different content. "
                    "Deselect it or edit the saved exchange.",
                )
            ids.append(str(aid))
        db.execute(
            "INSERT INTO transcript_imports(id,session_id,payload_sha256,answer_ids) VALUES (?,?,?,?)",
            (request_id, key, digest, as_json(ids)),
        )
    return {"saved": saved, "skipped": len(ids) - saved, "answer_ids": ids, "replayed": False}
