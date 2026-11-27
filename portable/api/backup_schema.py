"""Validate the versioned, local interview archive before it can enter the store."""

import json
import math
from typing import Annotated, Literal

from fastapi import HTTPException
from pydantic import (
    AfterValidator, BeforeValidator, Field, JsonValue, StringConstraints,
    ValidationError, field_validator, model_validator,
)

from .backup_review_schema import (
    Assignment,
    HandoffNote,
    HistoricalText,
    ID,
    Record,
    ReviewActor,
    ReviewStamp,
    ScorecardItem,
    TZStamp,
    _require_tz,
)
from .session_privacy import PrivacyRecord, verify_redaction
from .session_rubric import BackupRubricCriterion, RubricSnapshot
from .backup_validation import check_session_chronology, unique, verify_records

LIMIT = 20 * 1024 * 1024
LEGACY_MAX_DEPTH = 16
LEGACY_MAX_NODES = 2000
Digest = Annotated[str, StringConstraints(pattern=r"^[a-f0-9]{64}$")]
Text = Annotated[str, Field(max_length=24000)]
Label = Annotated[str, Field(max_length=180)]


def _strip_tag(value: object) -> object:
    return value.strip() if isinstance(value, str) else value


TagStr = Annotated[
    str,
    BeforeValidator(_strip_tag),
    StringConstraints(min_length=1, max_length=32, pattern=r"^[^\x00-\x1f\x7f,]+$"),
]
HistoricalQuestions = Annotated[list[HistoricalText], Field(max_length=1000)]


def _valid_span(span: list[int]) -> list[int]:
    if span[0] < 0 or span[1] <= span[0]:
        raise ValueError("Passage span must satisfy 0 <= start < end.")
    return span


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


Span = Annotated[list[int], Field(min_length=2, max_length=2), AfterValidator(_valid_span)]
LegacyDict = Annotated[dict[str, JsonValue] | None, BeforeValidator(_validate_legacy_tree)]


class Material(Record):
    label: Annotated[str, Field(min_length=1, max_length=180)]
    text: Annotated[str, Field(min_length=1, max_length=12000)]


class Source(Record):
    label: HistoricalText
    text: HistoricalText
    permitted: bool


class RoleVersion(Record):
    id: ID
    version_number: int = Field(ge=1, lt=2**63)
    content_sha256: Digest
    name: HistoricalText
    description: HistoricalText
    questions: HistoricalQuestions
    policy: Annotated[str, Field(max_length=4000)] = ""
    permitted_sources: list[Material] = Field(default_factory=list, max_length=8)
    rubric: list[BackupRubricCriterion] = Field(default_factory=list, max_length=25)
    change_note: Annotated[str, Field(max_length=300)] = ""
    created_by: Annotated[str, Field(max_length=180)] = "local-operator"
    created_at: TZStamp

    @field_validator("rubric")
    @classmethod
    def unique_rubric_ids(cls, value: list[BackupRubricCriterion]) -> list[BackupRubricCriterion]:
        unique((item.id for item in value), "rubric criterion ID")
        return value


class Role(Record):
    id: ID
    name: HistoricalText
    description: HistoricalText
    questions: HistoricalQuestions
    policy: Annotated[str, Field(max_length=4000)] = ""
    permitted_sources: list[Material] = Field(default_factory=list, max_length=8)
    rubric: list[BackupRubricCriterion] = Field(default_factory=list, max_length=25)
    version_number: int = Field(default=1, ge=1, lt=2**63)
    versions: list[RoleVersion] = Field(default_factory=list, max_length=1000)
    legacy: LegacyDict = None

    @field_validator("rubric")
    @classmethod
    def unique_rubric_ids(cls, value: list[BackupRubricCriterion]) -> list[BackupRubricCriterion]:
        unique((item.id for item in value), "rubric criterion ID")
        return value

    def model_dump(self, *args, exclude=None, **kwargs):
        if exclude == {"legacy"}:
            exclude = {"legacy", "versions"}
        return super().model_dump(*args, exclude=exclude, **kwargs)


class Passage(Record):
    label: Label
    words: int = Field(ge=1, le=24000)
    answer_excerpt: Text
    source_excerpt: Text
    source_index: int | None = Field(default=None, ge=0)
    answer_span: Span | None = None
    source_span: Span | None = None


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
    legacy: LegacyDict = None


class ReviewEvent(Record):
    answer_id: ID
    role_id: ID | None = None
    reviewer_id: Annotated[str, StringConstraints(min_length=1, max_length=180)]
    reviewer_email: Annotated[str, StringConstraints(min_length=1, max_length=320)]
    previous_disposition: Literal["pending", "explained", "unresolved", "disclosed"]
    disposition: Literal["pending", "explained", "unresolved", "disclosed"]
    created_at: TZStamp


class SavedDraft(Record):
    parent_answer_id: ID | None = None
    planned_slot: int | None = Field(default=None, ge=1)
    id: ID
    question: Annotated[str, Field(max_length=4000)]
    answer: Text
    references: list[Source] = Field(max_length=12)
    revision: int = Field(ge=1, lt=2**63)
    updated_at: TZStamp


class Session(Record):
    id: ID
    candidate: HistoricalText
    role: HistoricalText
    role_id: ID | None
    planned_questions: HistoricalQuestions
    rubric_snapshot: RubricSnapshot | None = None
    privacy: PrivacyRecord | None = None
    policy: HistoricalText
    permitted_sources: list[Material] = Field(default_factory=list, max_length=8)
    consent: bool
    created_at: TZStamp
    ended_at: TZStamp | None
    trashed_at: TZStamp | None = None
    draft: SavedDraft | None = None
    assignment: Assignment | None = None
    handoff_notes: list[HandoffNote] = Field(default_factory=list)
    scorecard_items: list[ScorecardItem] = Field(default_factory=list, max_length=25)
    answers: list[Answer] = Field(max_length=20000)
    tags: list[TagStr] = Field(default_factory=list, max_length=10)
    review_events: list[ReviewEvent] = Field(default_factory=list, max_length=20000)
    legacy: LegacyDict = None

    @model_validator(mode="after")
    def valid_chronology(self):
        check_session_chronology(self.created_at, self.ended_at, self.trashed_at)
        if self.privacy and self.privacy.state == "anonymized":
            verify_redaction(self)
        self.tags = sorted(unique(self.tags, "session tag"))
        self.handoff_notes.sort(key=lambda note: (note.created_at, note.id), reverse=True)
        unique((item.criterion_id for item in self.scorecard_items), "scorecard criterion ID")
        return self


class Backup(Record):
    format: Literal["interviewcheck.workspace"]
    version: Literal[1, 2, 3, 4, 5, 6]
    roles: list[Role] = Field(max_length=4000)
    sessions: list[Session] = Field(max_length=5000)

    @model_validator(mode="after")
    def check_extensions(self):
        role_ids = {r.id for r in self.roles}
        unique((n.id for s in self.sessions for n in s.handoff_notes), "handoff note ID")
        unique((v.id for r in self.roles for v in r.versions), "role version ID")
        for r in self.roles:
            unique((v.version_number for v in r.versions), "role version number")
        for s in self.sessions:
            if ("assignment" in s.model_fields_set) != (self.version >= 3):
                raise ValueError("Versions 3 and later require an assignment field on every interview.")
            if ("handoff_notes" in s.model_fields_set) != (self.version >= 4):
                raise ValueError("Versions 4 and later require a handoff notes field on every interview.")
            if ("scorecard_items" in s.model_fields_set) != (self.version >= 5):
                raise ValueError("Version 5 requires a scorecard items field on every interview.")
            if ("rubric_snapshot" in s.model_fields_set) != (self.version >= 6):
                raise ValueError("Version 6 requires a rubric snapshot field on every interview.")
            if (self.version >= 6 and s.privacy is None) or (self.version < 6 and "privacy" in s.model_fields_set):
                raise ValueError("Version 6 requires an interview privacy record.")
            if s.rubric_snapshot and s.role_id and s.rubric_snapshot.role_id != s.role_id:
                raise ValueError("The rubric snapshot belongs to another role.")
            aids = {a.id for a in s.answers}
            for ev in s.review_events:
                if ev.answer_id not in aids:
                    raise ValueError("A review event refers to a missing exchange.")
                if ev.role_id is not None and ev.role_id not in role_ids:
                    raise ValueError("A review event refers to a missing role.")
        return self


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
