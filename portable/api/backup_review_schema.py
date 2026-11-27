"""Archive schemas for review assignments, handoff notes and scorecards."""
from datetime import datetime, timezone
from typing import Annotated

from pydantic import AfterValidator, Field, StringConstraints, field_validator, model_validator

from .backup_types import ID, Record, ReviewActor, ReviewStamp
from .session_assignment import AssignmentPriority, SessionAssignmentInput
from .session_scorecard import HandoffCategory, HandoffNoteInput, ScorecardItemInput


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
