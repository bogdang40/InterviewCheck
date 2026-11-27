"""Withhold records an earlier writer changed after their confirmed erasure."""
from fastapi import HTTPException

from .evidence import Words, probe
from .retention_anonymizer import REDACTED_TEXT


CANDIDATE = "r.candidate != 'Candidate [Anonymized ' || substr(r.id,1,8) || ']' OR r.legacy IS NOT NULL"
ANSWER = """r.answer!=:marker OR r.note!='' OR r.legacy IS NOT NULL OR r.import_origin IS NOT NULL OR
    CASE WHEN json_valid(r.result) THEN json_type(r.result,'$.passages') IS NOT 'array'
      OR json_type(r.result,'$.follow_up') IS NOT 'text' OR json_type(r.result,'$.explanation') IS NOT 'text'
      OR (instr(json_extract(r.result,'$.follow_up'),'You said')>0
          AND json_extract(r.result,'$.follow_up')!=:safe_probe) OR EXISTS (
        SELECT 1 FROM json_each(r.result,'$.passages') p
        WHERE CASE WHEN p.type='object' THEN coalesce(json_extract(p.value,'$.answer_excerpt'),'')!=:marker ELSE 1 END)
    ELSE 1 END"""
EXPORT = "r.draft!=:marker OR r.recipient!=:marker"
PARAMS = {"marker": REDACTED_TEXT, "safe_probe": probe("", Words(REDACTED_TEXT))}
ACTIVE_CONDITION = """NOT EXISTS (SELECT 1 FROM session_trash t WHERE t.session_id=s.id)
                  AND NOT EXISTS (SELECT 1 FROM retention_read_holds h WHERE h.session_id=s.id)"""


def _conflicts(scope):
    # The alias and scope come only from the fixed queries in this module.
    return f"""SELECT x.session_id FROM session_anonymizations x JOIN sessions s ON s.id=x.session_id
        WHERE {scope} AND ({CANDIDATE.replace('r.', 's.')}
           OR EXISTS (SELECT 1 FROM answers r WHERE r.session_id=s.id AND ({ANSWER}
                      OR EXISTS (SELECT 1 FROM answer_history h WHERE h.answer_id=r.id)))
           OR EXISTS (SELECT 1 FROM session_drafts d WHERE d.session_id=s.id)
           OR EXISTS (SELECT 1 FROM transcript_imports i WHERE i.session_id=s.id)
           OR EXISTS (SELECT 1 FROM note_exports r WHERE r.session_id=s.id AND ({EXPORT})))"""


def _track_changes(db):
    # SQLite does not permit parameters in trigger definitions. Quote only the application's
    # fixed redaction marker. Interview values remain SQL column references.
    def fixed_values(sql):
        for name, value in PARAMS.items():
            sql = sql.replace(":" + name, db.execute("SELECT quote(?)", (value,)).fetchone()[0])
        return sql
    sources = (
        ("sessions", "NEW.id", CANDIDATE),
        ("answers", "NEW.session_id", ANSWER),
        ("answer_history", "(SELECT session_id FROM answers WHERE id=NEW.answer_id)", "1"),
        ("session_drafts", "NEW.session_id", "1"),
        ("transcript_imports", "NEW.session_id", "1"),
        ("note_exports", "NEW.session_id", EXPORT),
    )
    for table, sid, predicate in sources:
        condition = fixed_values(predicate.replace("r.", "NEW."))
        for event in ("INSERT", "UPDATE"):
            db.execute(f"""CREATE TRIGGER IF NOT EXISTS retention_hold_{table}_{event} AFTER {event} ON {table}
                WHEN EXISTS (SELECT 1 FROM session_anonymizations WHERE session_id={sid}) AND ({condition})
                BEGIN INSERT OR IGNORE INTO retention_read_holds(session_id) VALUES({sid}); END""")
    check_receipt = fixed_values(_conflicts("x.session_id=NEW.session_id"))
    db.execute(f"""CREATE TRIGGER IF NOT EXISTS retention_hold_receipt AFTER INSERT ON session_anonymizations
        BEGIN INSERT OR IGNORE INTO retention_read_holds(session_id) {check_receipt}; END""")


def refresh(db):
    # Only membership is rebuilt. The original rows and erasure receipt remain available
    # in a consistent physical backup. Current writers enforce protection in their transaction.
    first = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='retention_read_holds'").fetchone() is None
    db.execute("""CREATE TABLE IF NOT EXISTS retention_read_holds (
                  session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE)""")
    db.execute("DELETE FROM retention_read_holds")
    db.execute(f"INSERT INTO retention_read_holds(session_id) {_conflicts('1')}", PARAMS)
    if first:
        db.execute("DROP VIEW active_sessions")
        db.execute(f"""CREATE VIEW active_sessions AS
            SELECT s.rowid AS rowid,s.* FROM sessions s WHERE {ACTIVE_CONDITION}""")
    _track_changes(db)


def require_available(db, *ids):
    marks = ",".join("?" for _ in ids)
    if db.execute(f"SELECT 1 FROM retention_read_holds WHERE session_id IN ({marks}) LIMIT 1", ids).fetchone():
        raise HTTPException(409, "This interview has records that conflict with its erasure receipt. "
                                 "Inspect a consistent SQLite backup before sharing it.",
                            headers={"X-InterviewCheck-Conflict": "interview-privacy"})


def require_complete_export(db):
    if db.execute("""SELECT 1 FROM retention_read_holds h WHERE NOT EXISTS
                     (SELECT 1 FROM session_trash t WHERE t.session_id=h.session_id) LIMIT 1""").fetchone():
        raise HTTPException(409, "The archive contains an interview that conflicts with its erasure receipt. "
                                 "Export unaffected interviews individually or inspect a consistent SQLite backup.")
