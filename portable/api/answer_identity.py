"""Private identity for conditional actions on one lifetime of a saved answer."""
from fastapi import HTTPException

from . import sql_script


_SCHEMA = """
CREATE TABLE IF NOT EXISTS answer_instances (
 answer_id TEXT PRIMARY KEY REFERENCES answers(id) ON DELETE CASCADE,
 binding_key BLOB NOT NULL CHECK(typeof(binding_key)='blob' AND length(binding_key)=32)
);
CREATE TRIGGER IF NOT EXISTS answer_instances_insert AFTER INSERT ON answers BEGIN
 INSERT INTO answer_instances(answer_id,binding_key) VALUES(new.id,randomblob(32))
 ON CONFLICT(answer_id) DO UPDATE SET binding_key=excluded.binding_key;
END;
"""


def migrate(db):
    sql_script.execute(db, _SCHEMA)
    # JSON restores insert new answers. Full SQLite recovery retains existing bindings.
    db.execute("""INSERT INTO answer_instances(answer_id,binding_key)
                  SELECT a.id,randomblob(32) FROM answers a
                  WHERE NOT EXISTS (SELECT 1 FROM answer_instances i WHERE i.answer_id=a.id)""")


def binding_key(db, answer_id: str) -> bytes:
    row = db.execute("SELECT binding_key FROM answer_instances WHERE answer_id=?", (answer_id,)).fetchone()
    if row is None or not isinstance(row[0], bytes) or len(row[0]) != 32:
        raise HTTPException(409, "The saved exchange identity is unavailable. Reload the workspace.")
    return row[0]
