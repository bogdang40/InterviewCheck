"""Shared input and archive boundaries for a selected question."""
from typing import Annotated
import unicodedata

from pydantic import BeforeValidator, StringConstraints


def _question(value):
    if not isinstance(value, str) or value != value.strip() or any(
        ch not in "\n\t" and unicodedata.category(ch) in {"Cc", "Cs"} for ch in value
    ):
        raise ValueError("Use trimmed question text without unsupported control characters.")
    return value


SelectedQuestion = Annotated[str, StringConstraints(min_length=1, max_length=4000), BeforeValidator(_question)]
