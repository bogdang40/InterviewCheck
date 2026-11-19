"""Check local runtime stores without creating files or modifying their schemas."""
from contextlib import closing
import sqlite3

from fastapi import HTTPException

from . import store
from .access import embedded_enabled


def check_local_databases():
    targets = [(store.db_path(), ("SELECT 1 FROM sessions LIMIT 1",))]
    if embedded_enabled():
        from .account_db import database
        targets.append((database(), ("SELECT 1 FROM users LIMIT 1",
                                     "SELECT stripe_customer_id FROM subscriptions LIMIT 1")))
    try:
        for path, statements in targets:
            with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=1)) as db:
                for statement in statements:
                    db.execute(statement).fetchone()
    except (sqlite3.Error, OSError) as error:
        raise HTTPException(503, "A required local database is unavailable.") from error
