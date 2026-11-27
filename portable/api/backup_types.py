"""Shared archive value types without routes or database dependencies."""
from datetime import datetime
from typing import Annotated

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, StringConstraints, model_validator


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
