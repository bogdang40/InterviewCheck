"""Open the account database for key rotation only when it already holds encrypted secrets."""
from collections.abc import Iterator
from contextlib import closing, contextmanager
import sqlite3

from fastapi import HTTPException

from . import account_db, secret_box


@contextmanager
def open_access_database(*, write: bool) -> Iterator[sqlite3.Connection | None]:
    """Yield a connection inside a transaction, or None when there is nothing to rotate.

    Rotation never creates the account database: remote and local access modes have none.
    The caller commits; leaving the block without a commit rolls back.
    """
    try:
        path = account_db.database()
    except HTTPException as exc:
        raise secret_box.SecretBoxError(str(exc.detail)) from exc
    if not path.is_file():
        yield None
        return
    with closing(sqlite3.connect(path, timeout=10)) as db:
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='user_totp'").fetchone() is None:
            yield None
            return
        db.execute("BEGIN IMMEDIATE" if write else "BEGIN")
        try:
            yield db
        finally:
            if db.in_transaction:
                db.rollback()
