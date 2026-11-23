"""Run multi statement SQL inside the caller's open transaction.

sqlite3's executescript commits any pending transaction before it runs, so a
migration that used it inside BEGIN IMMEDIATE could leave a half upgraded schema
after a crash. These helpers execute each statement on its own instead.
"""
from functools import lru_cache
import sqlite3
from typing import Any


@lru_cache(maxsize=64)
def statements(script: str) -> tuple[str, ...]:
    """Split a script into complete statements, respecting quotes, comments and triggers."""
    found: list[str] = []
    pending = ""
    for chunk in script.split(";"):
        pending += chunk + ";"
        if sqlite3.complete_statement(pending):
            statement = pending.strip()
            if statement != ";":
                found.append(statement)
            pending = ""
    leftover = pending[:-1].strip()
    if leftover:
        raise ValueError("SQL script ends with an incomplete statement.")
    return tuple(found)


def execute(db: Any, script: str) -> None:
    for statement in statements(script):
        db.execute(statement)


class TransactionBoundConnection:
    """Connection view whose executescript keeps the caller's transaction open.

    Migrations owned by other modules receive this view so that none of them can
    commit part of an upgrade early, whichever helper they call.
    """

    __slots__ = ("_db",)

    def __init__(self, db: sqlite3.Connection) -> None:
        object.__setattr__(self, "_db", db)

    def executescript(self, script: str) -> None:
        execute(self._db, script)

    def __getattr__(self, name: str) -> Any:
        return getattr(self._db, name)

    def __setattr__(self, name: str, value: Any) -> None:
        setattr(self._db, name, value)
