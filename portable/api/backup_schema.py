"""Validate the versioned, local interview archive before it can enter the store."""

from datetime import datetime
import math
import json
from typing import Annotated, Literal

from fastapi import HTTPException
from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    JsonValue,
    StringConstraints,
    ValidationError,
    field_validator,
    model_validator,
)

from .backup_validation import check_session_chronology, unique, verify_records

LIMIT = 20 * 1024 * 1024
LEGACY_MAX_DEPTH = 16
LEGACY_MAX_NODES = 2000
ID = Annotated[
    str, StringConstraints(pattern=r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
]
Digest = Annotated[str, StringConstraints(pattern=r"^[a-f0-9]{64}$")]
Text = Annotated[str, Field(max_length=24000)]
Label = Annotated[str, Field(max_length=180)]
HistoricalText = Annotated[str, Field(max_length=2_000_000)]
HistoricalQuestions = Annotated[list[HistoricalText], Field(max_length=1000)]
Span = Annotated[list[int], Field(min_length=2, max_length=2)]


def _reject_null_bytes(value: object) -> None:
    if isinstance(value, str):
        if "\x00" in value:
            raise ValueError("Null bytes are not allowed in text fields.")
    elif isinstance(value, list):
        for item in value:
            if isinstance(item, str) and "\x00" in item:
                raise ValueError("Null bytes are not allowed in text fields.")


def _validate_legacy_tree(value: object) -> object:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ValueError("Legacy metadata must be a JSON object.")
    stack: list[tuple[object, int]] = [(value, 1)]
    nodes = 0
    while stack:
        current, depth = stack.pop()
        nodes += 1
        if nodes > LEGACY_MAX_NODES:
            raise ValueError("Legacy metadata exceeds maximum node count.")
        if isinstance(current, dict):
            if depth > LEGACY_MAX_DEPTH:
                raise ValueError("Legacy metadata exceeds maximum nesting depth.")
            for key, item in current.items():
                if not isinstance(key, str):
                    raise ValueError("Legacy metadata keys must be strings.")
                if "\x00" in key:
                    raise ValueError("Null bytes are not allowed in text fields.")
                stack.append((item, depth + 1))
        elif isinstance(current, list):
            if depth > LEGACY_MAX_DEPTH:
                raise ValueError("Legacy metadata exceeds maximum nesting depth.")
            for item in current:
                stack.append((item, depth + 1))
        elif isinstance(current, str) and "\x00" in current:
            raise ValueError("Null bytes are not allowed in text fields.")
    return value


class Record(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    @model_validator(mode="after")
    def reject_null_bytes(self):
        for name, value in self.__dict__.items():
            if name != "legacy":
                _reject_null_bytes(value)
        return self


class Material(Record):
    label: Annotated[str, Field(min_length=1, max_length=180)]
    text: Annotated[str, Field(min_length=1, max_length=12000)]


class Source(Record):
    label: HistoricalText
    text: HistoricalText
    permitted: bool


class Role(Record):
    id: ID
    name: HistoricalText
    description: HistoricalText
    questions: HistoricalQuestions
    policy: Annotated[str, Field(max_length=4000)] = ""
    permitted_sources: list[Material] = Field(default_factory=list, max_length=8)
    legacy: dict[str, JsonValue] | None = None

    @field_validator("legacy", mode="before")
    @classmethod
    def check_legacy(cls, value):
        return _validate_legacy_tree(value)


class Passage(Record):
    label: Label
    words: int = Field(ge=1, le=24000)
    answer_excerpt: Text
    source_excerpt: Text
    source_index: int | None = Field(default=None, ge=0)
    answer_span: Span | None = None
    source_span: Span | None = None

    @field_validator("answer_span", "source_span")
    @classmethod
    def valid_span(cls, span):
        if span is not None and (span[0] < 0 or span[1] <= span[0]):
            raise ValueError("Passage span must satisfy 0 <= start < end.")
        return span


class Finding(Record):
    status: Literal["match", "no_match", "insufficient"]
    explanation: Text
    passages: list[Passage] = Field(max_length=3)
    follow_up: Text
    archived: bool | None = None


class Origin(Record):
    format: Literal["webvtt"]
    transcript_sha256: Digest
    candidate_speaker: Label
    interviewer_speakers: list[Label] = Field(min_length=1, max_length=24)
    ordinal: int = Field(ge=1, le=10000)
    first_cue: int | None = Field(default=None, ge=1, le=10000)
    last_cue: int | None = Field(default=None, ge=1, le=10000)
    start_ms: int = Field(ge=0)
    end_ms: int = Field(ge=0)
    input_sha256: Digest


class Answer(Record):
    parent_answer_id: ID | None = None
    planned_slot: int | None = Field(default=None, ge=1)
    id: ID
    question: HistoricalText
    answer: HistoricalText
    references: list[Source] = Field(max_length=1000)
    result: Finding
    disposition: Literal["pending", "explained", "unresolved", "disclosed"]
    note: HistoricalText
    revision: int = Field(ge=1, lt=2**63)
    import_origin: Origin | None = None
    legacy: dict[str, JsonValue] | None = None

    @field_validator("legacy", mode="before")
    @classmethod
    def check_legacy(cls, value):
        return _validate_legacy_tree(value)


class SavedDraft(Record):
    parent_answer_id: ID | None = None
    planned_slot: int | None = Field(default=None, ge=1)
    id: ID
    question: Annotated[str, Field(max_length=4000)]
    answer: Text
    references: list[Source] = Field(max_length=12)
    revision: int = Field(ge=1, lt=2**63)
    updated_at: str

    @field_validator("updated_at")
    @classmethod
    def valid_time(cls, stamp):
        if datetime.fromisoformat(stamp).utcoffset() is None:
            raise ValueError("Draft timestamp needs a time zone.")
        return stamp


class Session(Record):
    id: ID
    candidate: HistoricalText
    role: HistoricalText
    role_id: ID | None
    planned_questions: HistoricalQuestions
    policy: HistoricalText
    permitted_sources: list[Material] = Field(default_factory=list, max_length=8)
    consent: bool
    created_at: str
    ended_at: str | None
    trashed_at: str | None = None
    draft: SavedDraft | None = None
    answers: list[Answer] = Field(max_length=20000)
    legacy: dict[str, JsonValue] | None = None

    @field_validator("legacy", mode="before")
    @classmethod
    def check_legacy(cls, value):
        return _validate_legacy_tree(value)

    @field_validator("created_at", "ended_at", "trashed_at")
    @classmethod
    def timestamp(cls, stamp):
        if stamp is not None:
            parsed = datetime.fromisoformat(stamp)
            if parsed.utcoffset() is None:
                raise ValueError("Timestamp needs a time zone.")
        return stamp

    @model_validator(mode="after")
    def valid_chronology(self):
        check_session_chronology(self.created_at, self.ended_at, self.trashed_at)
        return self


class Backup(Record):
    format: Literal["interviewcheck.workspace"]
    version: Literal[1]
    roles: list[Role] = Field(max_length=4000)
    sessions: list[Session] = Field(max_length=5000)


def parse(raw: bytes):
    if len(raw) > LIMIT:
        raise HTTPException(413, "Select a workspace backup no larger than 20 MiB.")

    def object_from(pairs):
        unique((key for key, _ in pairs), "JSON field")
        return dict(pairs)

    try:
        document = json.loads(
            raw.decode("utf-8-sig"),
            object_pairs_hook=object_from,
            parse_constant=finite_number,
            parse_float=finite_number,
        )
        if not isinstance(document, dict) or type(document.get("version")) is not int:
            raise ValueError("Invalid workspace backup version.")
        backup = Backup.model_validate(document)
        verify_records(backup)
        return backup
    except (ValidationError, ValueError, TypeError, RecursionError, OverflowError) as exc:
        detail = "The file has invalid records or an unsupported version."
        if type(exc) is ValueError and str(exc) in {
            "A quoted passage cannot be verified against its sources.",
            "A stored finding disagrees with its evidence.",
            "Duplicate exchange ID.",
            "Duplicate JSON field.",
            "An interview refers to a missing role.",
        }:
            detail = str(exc)
        raise HTTPException(422, detail) from exc


def finite_number(text):
    value = float(text)
    if not math.isfinite(value):
        raise ValueError("Nonfinite values are invalid.")
    return value
