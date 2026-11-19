"""FTS5 trigram prefiltering index and trigger sync for literal discovery search."""

import sqlite3

TABLES = ("fts_roles", "fts_sessions", "fts_answers")

# All non-ASCII Unicode codepoints whose str.casefold() is pure ASCII.
FOLD_MAP = (
    ("ß", "ss"),
    ("ẞ", "ss"),
    ("\u017f", "s"),
    ("\u212a", "k"),
    ("\ufb00", "ff"),
    ("\ufb01", "fi"),
    ("\ufb02", "fl"),
    ("\ufb03", "ffi"),
    ("\ufb04", "ffl"),
    ("\ufb05", "st"),
    ("\ufb06", "st"),
)


def _fold_sql(expr: str) -> str:
    for source, target in FOLD_MAP:
        expr = f"replace({expr}, '{source}', '{target}')"
    return expr


def _build_statements() -> tuple[str, ...]:
    rn, sc, sr = _fold_sql("new.name"), _fold_sql("new.candidate"), _fold_sql("new.role")
    aq, aa = _fold_sql("new.question"), _fold_sql("new.answer")
    return (
        "CREATE VIRTUAL TABLE IF NOT EXISTS fts_roles USING fts5(name, content='', contentless_delete=1, tokenize='trigram')",
        "CREATE VIRTUAL TABLE IF NOT EXISTS fts_sessions USING fts5(candidate, role, content='', contentless_delete=1, tokenize='trigram')",
        "CREATE VIRTUAL TABLE IF NOT EXISTS fts_answers USING fts5(question, answer, content='', contentless_delete=1, tokenize='trigram')",
        f"CREATE TRIGGER IF NOT EXISTS fts_roles_ai AFTER INSERT ON roles BEGIN INSERT INTO fts_roles(rowid, name) VALUES (new.rowid, {rn}); END",
        "CREATE TRIGGER IF NOT EXISTS fts_roles_ad AFTER DELETE ON roles BEGIN DELETE FROM fts_roles WHERE rowid=old.rowid; END",
        f"CREATE TRIGGER IF NOT EXISTS fts_roles_au AFTER UPDATE OF name ON roles BEGIN DELETE FROM fts_roles WHERE rowid=old.rowid; INSERT INTO fts_roles(rowid, name) VALUES (new.rowid, {rn}); END",
        f"CREATE TRIGGER IF NOT EXISTS fts_sessions_ai AFTER INSERT ON sessions BEGIN INSERT INTO fts_sessions(rowid, candidate, role) VALUES (new.rowid, {sc}, {sr}); END",
        "CREATE TRIGGER IF NOT EXISTS fts_sessions_ad AFTER DELETE ON sessions BEGIN DELETE FROM fts_sessions WHERE rowid=old.rowid; END",
        f"CREATE TRIGGER IF NOT EXISTS fts_sessions_au AFTER UPDATE OF candidate, role ON sessions BEGIN DELETE FROM fts_sessions WHERE rowid=old.rowid; INSERT INTO fts_sessions(rowid, candidate, role) VALUES (new.rowid, {sc}, {sr}); END",
        f"CREATE TRIGGER IF NOT EXISTS fts_answers_ai AFTER INSERT ON answers BEGIN INSERT INTO fts_answers(rowid, question, answer) VALUES (new.rowid, {aq}, {aa}); END",
        "CREATE TRIGGER IF NOT EXISTS fts_answers_ad AFTER DELETE ON answers BEGIN DELETE FROM fts_answers WHERE rowid=old.rowid; END",
        f"CREATE TRIGGER IF NOT EXISTS fts_answers_au AFTER UPDATE OF question, answer ON answers BEGIN DELETE FROM fts_answers WHERE rowid=old.rowid; INSERT INTO fts_answers(rowid, question, answer) VALUES (new.rowid, {aq}, {aa}); END",
    )


STATEMENTS = _build_statements()
SCHEMA = ";\n".join(STATEMENTS) + ";"


def _triggers_current(db: sqlite3.Connection) -> bool:
    row = db.execute(
        "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='fts_roles_ai'"
    ).fetchone()
    return row is not None and "\ufb03" in (row[0] or "")


def migrate(db: sqlite3.Connection) -> None:
    existing = {
        row[0]
        for row in db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('fts_roles','fts_sessions','fts_answers')"
        )
    }
    if existing and not _triggers_current(db):
        for prefix in ("fts_roles", "fts_sessions", "fts_answers"):
            for suffix in ("ai", "ad", "au"):
                db.execute(f"DROP TRIGGER IF EXISTS {prefix}_{suffix}")
            db.execute(f"DROP TABLE IF EXISTS {prefix}")
        existing.clear()
    for statement in STATEMENTS:
        db.execute(statement)
    if "fts_roles" not in existing:
        db.execute(f"INSERT INTO fts_roles(rowid, name) SELECT rowid, {_fold_sql('name')} FROM roles")
    if "fts_sessions" not in existing:
        db.execute(
            f"INSERT INTO fts_sessions(rowid, candidate, role) "
            f"SELECT rowid, {_fold_sql('candidate')}, {_fold_sql('role')} FROM sessions"
        )
    if "fts_answers" not in existing:
        db.execute(
            f"INSERT INTO fts_answers(rowid, question, answer) "
            f"SELECT rowid, {_fold_sql('question')}, {_fold_sql('answer')} FROM answers"
        )


def has_fts(db: sqlite3.Connection) -> bool:
    return (
        db.execute(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('fts_roles','fts_sessions','fts_answers')"
        ).fetchone()[0]
        == len(TABLES)
    )


def can_use_fts(needle: str) -> bool:
    return (
        len(needle) >= 3
        and needle.isascii()
        and "\x00" not in needle
        and needle.isprintable()
        and "ss" not in needle
    )


def fts_phrase(needle: str) -> str:
    return '"' + needle.replace('"', '""') + '"'
