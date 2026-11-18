"""Public input boundaries for the local review service."""
from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, field_validator, model_validator

Name = Annotated[str, StringConstraints(min_length=1, max_length=180)]
Question = Annotated[str, StringConstraints(min_length=1, max_length=4000)]
Body = Annotated[str, StringConstraints(min_length=1, max_length=24000)]
RequestID = Annotated[UUID, Field(strict=False)]
Disposition = Literal["pending", "explained", "unresolved", "disclosed"]


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
    policy: Question | None = None
    permitted_sources: Materials | None = None
    consent: bool

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
    note: str = Field(max_length=12000)

    @model_validator(mode="after")
    def require_disclosure_note(self):
        if self.disposition == "disclosed" and not self.note:
            raise ValueError("Record what the candidate disclosed in the interviewer note.")
        return self


class RoleInput(Input):
    policy: str = Field(default="", max_length=4000)
    permitted_sources: Materials = Field(default_factory=list)
    id: RequestID | None = None
    name: Name
    description: str = Field(default="", max_length=24000)
    questions: list[Question] = Field(default_factory=list, max_length=100)
