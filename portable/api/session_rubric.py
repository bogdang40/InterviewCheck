"""Keep the rubric that applied when an interview began, including an intentionally empty rubric."""
from typing import Annotated
import json

from fastapi import HTTPException
from pydantic import Field, StringConstraints, ValidationError, model_validator

from .backup_review_schema import ID, Record


class BackupRubricCriterion(Record):
    id: Annotated[str, StringConstraints(min_length=1, max_length=64)]
    criterion: Annotated[str, StringConstraints(min_length=1, max_length=500)]
    weight: int = Field(default=1, ge=1, le=100)
    expected_signals: list[Annotated[str, StringConstraints(min_length=1, max_length=500)]] = Field(default_factory=list, max_length=20)
    red_flags: list[Annotated[str, StringConstraints(min_length=1, max_length=500)]] = Field(default_factory=list, max_length=20)


class RubricSnapshot(Record):
    role_id: ID | None
    version_number: int | None = Field(ge=1, lt=2**63)
    role_content_sha256: Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")] | None
    criteria: list[BackupRubricCriterion] = Field(max_length=25)

    @model_validator(mode="after")
    def validate_source(self):
        if self.role_id is None:
            if self.version_number is not None or self.role_content_sha256 is not None or self.criteria:
                raise ValueError("An interview without a template cannot have a role rubric.")
        elif self.version_number is None or self.role_content_sha256 is None:
            raise ValueError("A captured role rubric requires its version number and content digest.")
        if len({item.id for item in self.criteria}) != len(self.criteria):
            raise ValueError("Duplicate rubric criterion ID.")
        return self


def capture(selected, role_digest):
    try:
        snapshot = RubricSnapshot(
            role_id=selected["id"] if selected else None,
            version_number=selected["version_number"] if selected else None,
            role_content_sha256=role_digest,
            criteria=json.loads(selected["rubric_json"]) if selected else [],
        )
    except (ValidationError, ValueError) as exc:
        raise HTTPException(409, "The saved role rubric is unreadable. Correct the role before starting an interview.") from exc
    return snapshot.model_dump_json()


class UnreadableRubric(HTTPException):
    pass


def read(db, session_id):
    row = db.execute("SELECT rubric_snapshot FROM session_context WHERE session_id=?", (session_id,)).fetchone()
    if row is None or row[0] is None:
        return None
    try:
        return RubricSnapshot.model_validate_json(row[0])
    except ValidationError as exc:
        raise UnreadableRubric(409, "The stored interview rubric is unreadable. Check the SQLite backup.") from exc
