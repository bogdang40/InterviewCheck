"""Bounded interview summaries and literal search for the local operator."""

from typing import Annotated, Literal

from fastapi import APIRouter
from pydantic import Field, StringConstraints

from . import search_cursor, search_page, store
from .models import Input

router = APIRouter()
Kind = Literal["role", "session", "answer"]


class Search(Input):
    query: str = Field(max_length=160)
    kinds: list[Kind] = Field(
        default_factory=lambda: ["role", "session", "answer"], min_length=1, max_length=3
    )
    limit: int = Field(default=20, ge=1, le=50)
    cursor: Annotated[str, StringConstraints(strip_whitespace=False, max_length=128)] = ""


def search_position(pattern, value):
    """Return a source character offset. -2 is exact, -1 is absent."""
    if not value:
        return -1
    folded = value.casefold()
    if folded == pattern:
        return -2
    pos = folded.find(pattern)
    if pos <= 0 or len(value) == len(folded):
        return pos
    # A Unicode case fold can expand. Convert the hit back to a source offset
    # only in that uncommon case; SQLite substr uses source character offsets.
    width = 0
    for offset, char in enumerate(value):
        width += len(char.casefold())
        if width > pos:
            return offset
    return -1


@router.post("/search")
def search(body: Search):
    paged = "cursor" in body.model_fields_set
    needle = body.query.casefold()
    kinds = set(body.kinds)
    after = search_cursor.decode(body.cursor, needle, kinds) if body.cursor else None
    rows = []
    if needle:
        with store.connection() as db:
            db.create_function("ic_position", 1, lambda text: search_position(needle, text), deterministic=True)
            rows = search_page.read(db, needle, kinds, limit=body.limit + 1, context=min(45, 180 - len(body.query)),
                                    after=after, metadata=paged)

    items = rows[:body.limit]
    result = {"items": items, "has_more": len(rows) > body.limit}
    if paged:
        result["next_cursor"] = None
        if result["has_more"]:
            last = items[-1]
            boundary = search_cursor.Position(last["rank"], last["priority"], last["id"])
            result["next_cursor"] = search_cursor.encode(needle, kinds, boundary)
    for item in items:
        del item["rank"], item["priority"]
        if paged and item["kind"] == "role":
            del item["role"], item["created_at"]
    return result
