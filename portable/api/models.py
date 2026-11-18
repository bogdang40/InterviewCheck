"""Public input boundaries for the local review service."""
from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, field_validator, model_validator

Name = Annotated[str, StringConstraints(min_length=1, max_length=180)]
Question = Annotated[str, StringConstraints(min_length=1, max_length=4000)]
Body = Annotated[str, StringConstraints(min_length=1, max_length=24000)]
RequestID = Annotated[UUID, Field(strict=False)]
RoleVersion = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
Disposition = Literal["pending", "explained", "unresolved", "disclosed"]
EARLIER_NOTE_PREFIX = "Note from an earlier answer version:\n"
NOTE_LIMIT = 12000


def validate_note_length(note: str) -> str:
    if len(note.removeprefix(EARLIER_NOTE_PREFIX)) > NOTE_LIMIT:
        raise ValueError(f"The interviewer note exceeds {NOTE_LIMIT} characters.")
    return note


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True, strict=True)


class PermittedMaterial(Input):
    label: Name
    text: Annotated[str, StringConstraints(min_length=1, max_length=12000)]


Materials = Annotated[list[PermittedMaterial], Field(max_length=8)]


class SessionInput(Input):
    id: RequestID | None = None
    candidate: Name
    role: Name
    role_id: RequestID | None = None
    role_version: RoleVersion | None = None
    policy: Question | None = None
    permitted_sources: Materials | None = None
    consent: bool

    @model_validator(mode="after")
    def require_versioned_role_id(self):
        if self.role_version is not None and self.role_id is None:
            raise ValueError("A role version requires a selected role ID.")
        return self

    @field_validator("consent")
    @classmethod
    def require_notice(cls, value: bool) -> bool:
        if not value:
            raise ValueError("Confirm candidate notice before starting a session.")
        return value


class Reference(Input):
    label: Name
    text: Body
    permitted: bool = False


class OriginInput(Input):
    parent_answer_id: RequestID | None = None
    planned_slot: int | None = Field(default=None, ge=1, le=2147483647)


class AnswerInput(OriginInput):
    id: RequestID | None = None
    question: Question
    answer: Body
    references: list[Reference] = Field(default_factory=list, max_length=12)


class AnswerEdit(AnswerInput):
    expected_revision: int | None = Field(default=None, ge=1)


class ReviewInput(Input):
    expected_revision: int | None = Field(default=None, ge=1)
    disposition: Disposition
    note: str = Field(max_length=NOTE_LIMIT + len(EARLIER_NOTE_PREFIX))

    @field_validator("note")
    @classmethod
    def check_note_length(cls, value):
        return validate_note_length(value)

    @model_validator(mode="after")
    def require_disclosure_note(self):
        if self.disposition == "disclosed" and not self.note:
            raise ValueError("Record what the candidate disclosed in the interviewer note.")
        return self


class RoleInput(Input):
    version: RoleVersion | None = None
    policy: str = Field(default="", max_length=4000)
    permitted_sources: Materials = Field(default_factory=list)
    id: RequestID | None = None
    name: Name
    description: str = Field(default="", max_length=24000)
    questions: list[Question] = Field(default_factory=list, max_length=100)
