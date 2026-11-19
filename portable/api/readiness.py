"""Check local runtime stores without creating files or modifying their schemas."""
from contextlib import closing
import sqlite3

from fastapi import HTTPException

from . import store
from .access import embedded_enabled


def check_local_databases():
    review_path = store.db_path()
    if not review_path.is_file():
        raise HTTPException(503, "A required local database is unavailable.")
    try:
        with store.connection() as db:
            db.execute("SELECT 1 FROM sessions LIMIT 1").fetchone()
        if embedded_enabled():
            from .account_db import database
            account_path = database()
            with closing(sqlite3.connect(account_path.resolve().as_uri() + "?mode=ro", uri=True, timeout=1)) as db:
                for statement in ("SELECT 1 FROM users LIMIT 1", "SELECT stripe_customer_id FROM subscriptions LIMIT 1"):
                    db.execute(statement).fetchone()
    except (sqlite3.Error, OSError) as error:
        raise HTTPException(503, "A required local database is unavailable.") from error
