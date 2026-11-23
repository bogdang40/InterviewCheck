"""Shared backup record base types and review assignment, handoff note, and scorecard schemas."""

from datetime import datetime, timezone
from typing import Annotated

from pydantic import (
    AfterValidator, BaseModel, ConfigDict, Field, StringConstraints,
    field_validator, model_validator,
)

from .session_assignment import AssignmentPriority, SessionAssignmentInput
from .session_scorecard import HandoffCategory, HandoffNoteInput, ScorecardItemInput

ID = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")]
HistoricalText = Annotated[str, Field(max_length=2_000_000)]


def _require_tz(stamp: str) -> str:
    if datetime.fromisoformat(stamp).utcoffset() is None:
        raise ValueError("Timestamp needs a time zone.")
    return stamp


def _reject_null_bytes(value: object) -> None:
    if isinstance(value, str):
        if "\x00" in value:
            raise ValueError("Null bytes are not allowed in text fields.")
    elif isinstance(value, list):
        for item in value:
            if isinstance(item, str) and "\x00" in item:
                raise ValueError("Null bytes are not allowed in text fields.")


def _nonblank_actor(value: str) -> str:
    if not value.strip():
        raise ValueError("The recorded actor must contain a nonspace character.")
    return value


TZStamp = Annotated[str, AfterValidator(_require_tz)]
ReviewStamp = Annotated[
    str, StringConstraints(max_length=64, pattern=r"^[^\p{Cc}]+$"), AfterValidator(_require_tz),
]
ReviewActor = Annotated[
    HistoricalText, StringConstraints(min_length=1, pattern=r"^[^\p{Cc}]+$"), AfterValidator(_nonblank_actor),
]


class Record(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    @model_validator(mode="after")
    def reject_null_bytes(self):
        for name, value in self.__dict__.items():
            if name != "legacy":
                _reject_null_bytes(value)
        return self


class HandoffNote(Record):
    id: ID
    author_email: ReviewActor
    category: HandoffCategory
    body: Annotated[str, Field(max_length=2000)]
    created_at: ReviewStamp

    @field_validator("body")
    @classmethod
    def valid_stored_body(cls, value: str) -> str:
        # Retention removes the body while preserving the note and its provenance.
        if value and HandoffNoteInput.clean_body(value) != value:
            raise ValueError("Invalid stored handoff note body.")
        return value


class Assignment(Record):
    assignee_email: Annotated[
        str, Field(min_length=3, max_length=254), AfterValidator(SessionAssignmentInput.validate_assignee_email),
    ]
    assigned_by: ReviewActor
    priority: AssignmentPriority
    due_at: ReviewStamp | None
    updated_at: ReviewStamp

    @field_validator("due_at")
    @classmethod
    def utc_due_at(cls, value: str | None) -> str | None:
        if value is None:
            return None
        try:
            return datetime.fromisoformat(value).astimezone(timezone.utc).isoformat()
        except OverflowError as exc:
            raise ValueError("The assignment deadline exceeds the supported UTC range.") from exc


class ScorecardItem(Record):
    criterion_id: Annotated[str, StringConstraints(min_length=1, max_length=256)]
    criterion_label: Annotated[str, StringConstraints(min_length=1, max_length=500)]
    weight: int = Field(ge=1, le=100)
    rating: int = Field(ge=1, le=5)
    rationale: Annotated[str, Field(max_length=2000)]
    updated_by: ReviewActor
    updated_at: ReviewStamp

    @field_validator("criterion_id", "criterion_label")
    @classmethod
    def valid_stored_identifier(cls, value: str) -> str:
        if ScorecardItemInput.clean_identifier(value) != value:
            raise ValueError("Invalid stored scorecard criterion field.")
        return value

    @field_validator("rationale")
    @classmethod
    def valid_stored_rationale(cls, value: str) -> str:
        if ScorecardItemInput.clean_rationale(value) != value:
            raise ValueError("Invalid stored scorecard rationale.")
        return value
