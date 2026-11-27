"""Withhold records that conflict with a confirmed erasure receipt."""
import re

from fastapi import HTTPException

from . import retained_narratives
from .retained_finding import FINDING_PARAMS, UNSAFE_FINDING_SQL
from .retention_anonymizer import REDACTED_TEXT


CANDIDATE = "r.candidate != 'Candidate [Anonymized ' || substr(r.id,1,8) || ']' OR r.legacy IS NOT NULL"
ANSWER = f"""r.answer!=:marker OR r.note!='' OR r.legacy IS NOT NULL OR r.import_origin IS NOT NULL OR
    CASE WHEN json_valid(r.result) THEN ({UNSAFE_FINDING_SQL}) ELSE 1 END"""
EXPORT = "r.draft!=:marker OR r.recipient!=:marker"
PARAMS = {"marker": REDACTED_TEXT, **FINDING_PARAMS}
ACTIVE_CONDITION = """NOT EXISTS (SELECT 1 FROM session_trash t WHERE t.session_id=s.id)
                  AND NOT EXISTS (SELECT 1 FROM retention_read_holds h WHERE h.session_id=s.id)"""
PERMANENT = "ON CONFLICT(session_id) DO UPDATE SET needs_timestamp_check=0"


def _conflicts(scope):
    # The alias and scope come only from the fixed queries in this module.
    return f"""SELECT x.session_id FROM session_anonymizations x JOIN sessions s ON s.id=x.session_id
        WHERE {scope} AND ({CANDIDATE.replace('r.', 's.')}
           OR EXISTS (SELECT 1 FROM answers r WHERE r.session_id=s.id AND ({ANSWER}
                      OR EXISTS (SELECT 1 FROM answer_history h WHERE h.answer_id=r.id)))
           OR EXISTS (SELECT 1 FROM session_drafts d WHERE d.session_id=s.id)
           OR EXISTS (SELECT 1 FROM transcript_imports i WHERE i.session_id=s.id)
           OR EXISTS (SELECT 1 FROM note_exports r WHERE r.session_id=s.id AND ({EXPORT})))"""


def _install(db, kind, name, definition):
    # Inspect the actual definition. A physical restore can retain derived tables and lose
    # or revert an associated view or trigger. Stable definitions need no schema rewrite.
    statement = f"CREATE {kind} {name} {definition}"
    existing = db.execute("SELECT sql FROM sqlite_master WHERE type=? AND name=?", (kind.lower(), name)).fetchone()
    if existing and existing[0] == statement:
        return
    if existing:
        db.execute(f"DROP {kind} {name}")
    db.execute(statement)


def _track_changes(db):
    # SQLite does not permit parameters in trigger definitions. Quote the fixed release
    # vocabulary once. User text appears only as a reference to the stored column.
    literals = {name: db.execute("SELECT quote(?)", (value,)).fetchone()[0] for name, value in PARAMS.items()}

    def fixed_values(sql):
        return re.sub(r":([A-Za-z_]\w*)", lambda match: literals[match[1]], sql)
    sources = (
        ("sessions", "NEW.id", CANDIDATE),
        ("answers", "NEW.session_id", ANSWER),
        ("answer_history", "(SELECT session_id FROM answers WHERE id=NEW.answer_id)", "1"),
        ("session_drafts", "NEW.session_id", "1"),
        ("transcript_imports", "NEW.session_id", "1"),
        ("note_exports", "NEW.session_id", EXPORT),
        ("session_handoff_notes", "NEW.session_id", "NEW.body!=''"),
        ("session_scorecards", "NEW.session_id", "NEW.rationale!=''"),
    )
    for table, sid, predicate in sources:
        condition = fixed_values(predicate.replace("r.", "NEW."))
        for event in ("INSERT", "UPDATE"):
            _install(db, "TRIGGER", f"retention_hold_{table}_{event}", f"""AFTER {event} ON {table}
                WHEN EXISTS (SELECT 1 FROM session_anonymizations WHERE session_id={sid}) AND ({condition})
                BEGIN INSERT INTO retention_read_holds(session_id) VALUES({sid}) {PERMANENT}; END""")
    check_receipt = fixed_values(_conflicts("x.session_id=NEW.session_id"))
    # A prior writer can insert a receipt without running the current timestamp check. All
    # readers withhold it until the current writer or a later startup validates its narratives.
    _install(db, "TRIGGER", "retention_hold_receipt", f"""AFTER INSERT ON session_anonymizations BEGIN
        INSERT INTO retention_read_holds(session_id) {check_receipt} {PERMANENT};
        INSERT INTO retention_read_holds(session_id,needs_timestamp_check) VALUES(NEW.session_id,1)
            ON CONFLICT(session_id) DO NOTHING;
        END""")


def refresh(db):
    # Keep witnessed violations even if the older writer assigned its timestamp before
    # taking the write lock. A restart cannot reconstruct that commit ordering from timestamps.
    db.execute(f"INSERT INTO retention_read_holds(session_id) {_conflicts('1')} {PERMANENT}", PARAMS)
    retained_narratives.refresh(db)
    _install(db, "VIEW", "active_sessions", f"AS SELECT s.rowid AS rowid,s.* FROM sessions s WHERE {ACTIVE_CONDITION}")
    _track_changes(db)


def require_available(db, *ids):
    marks = ",".join("?" for _ in ids)
    state = db.execute(f"SELECT min(needs_timestamp_check) FROM retention_read_holds WHERE session_id IN ({marks})",
                       ids).fetchone()[0]
    if state is None:
        return
    detail = ("An erasure receipt needs validation. Restart the current release to check the retained interview."
              if state else "This interview has records that conflict with its erasure receipt. "
              "Inspect a consistent SQLite backup before sharing it.")
    raise HTTPException(409, detail, headers={"X-InterviewCheck-Conflict": "interview-privacy"})


def require_complete_export(db):
    if db.execute("""SELECT 1 FROM retention_read_holds h WHERE NOT EXISTS
                     (SELECT 1 FROM session_trash t WHERE t.session_id=h.session_id) LIMIT 1""").fetchone():
        raise HTTPException(409, "The archive includes an interview withheld by an erasure check. "
                                 "Export unaffected interviews individually or inspect a consistent SQLite backup.")
