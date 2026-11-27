"""Preserve retention receipts and keep uncertain legacy imports separate from confirmed erasure."""
from typing import Literal

from fastapi import HTTPException
from pydantic import ValidationError, model_validator

from . import retained_narratives
from .backup_types import Record, TZStamp
from .retention_anonymizer import REDACTED_TEXT, anonymized_candidate_label


class PrivacyRecord(Record):
    state: Literal["unmarked", "anonymized", "legacy_unverified"]
    anonymized_at: TZStamp | None

    @model_validator(mode="after")
    def check_timestamp(self):
        if (self.state == "anonymized") != (self.anonymized_at is not None):
            raise ValueError("Only a confirmed anonymization has a recorded timestamp.")
        return self


def _has_table(db, table):
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone() is not None


def migrate(db):
    if _has_table(db, "legacy_privacy_holds"):
        return
    db.execute("""CREATE TABLE legacy_privacy_holds (
                  session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE)""")
    # Workspaces restored by older releases have already lost the retention receipt.
    db.execute("""INSERT INTO legacy_privacy_holds(session_id)
                  SELECT s.id FROM sessions s
                  WHERE s.candidate='Candidate [Anonymized ' || substr(s.id,1,8) || ']' AND s.legacy IS NULL
                    AND NOT EXISTS (SELECT 1 FROM session_anonymizations x WHERE x.session_id=s.id)
                    AND (EXISTS (SELECT 1 FROM answers a WHERE a.session_id=s.id AND a.answer=?
                                 AND a.note='' AND a.legacy IS NULL AND a.import_origin IS NULL)
                         OR (NOT EXISTS (SELECT 1 FROM answers a WHERE a.session_id=s.id)
                             AND NOT EXISTS (SELECT 1 FROM session_drafts d WHERE d.session_id=s.id)))""",
               (REDACTED_TEXT,))


class UnreadablePrivacy(HTTPException):
    pass


def _storage_ready(db):
    return db.execute("""SELECT count(*) FROM sqlite_master WHERE type='table'
                         AND name IN ('session_anonymizations','legacy_privacy_holds')""").fetchone()[0] == 2


def require_storage(db):
    if not _storage_ready(db):
        raise UnreadablePrivacy(409, "Restart InterviewCheck to initialize the interview privacy records.")


def read(db, sid):
    require_storage(db)
    row = db.execute("SELECT anonymized_at FROM session_anonymizations WHERE session_id=?", (sid,)).fetchone()
    if row:
        try:
            return PrivacyRecord(state="anonymized", anonymized_at=row[0])
        except ValidationError as exc:
            raise UnreadablePrivacy(409, "The interview retention receipt is unreadable. Inspect the SQLite backup.") from exc
    if db.execute("SELECT 1 FROM legacy_privacy_holds WHERE session_id=?", (sid,)).fetchone():
        return PrivacyRecord(state="legacy_unverified", anonymized_at=None)
    return PrivacyRecord(state="unmarked", anonymized_at=None)


def require_content_writable(db, sid):
    if read(db, sid).state != "unmarked":
        raise HTTPException(409, "This interview is protected. Reload it to view its retained records.",
                            headers={"X-InterviewCheck-Conflict": "interview-privacy"})


def require_transfer_allowed(db, sid):
    if read(db, sid).state != "unmarked":
        raise HTTPException(409, "Private transfers are unavailable for this protected interview.")


def calibration_filter(db):
    if not _storage_ready(db):
        return "AND 0"
    return """AND NOT EXISTS (SELECT 1 FROM session_anonymizations x WHERE x.session_id=s.id)
              AND NOT EXISTS (SELECT 1 FROM legacy_privacy_holds h WHERE h.session_id=s.id)"""


def legacy_hold(session):
    if session.candidate != anonymized_candidate_label(session.id) or session.legacy is not None:
        return False
    if not session.answers:
        return session.draft is None
    return any(a.answer == REDACTED_TEXT and a.note == "" and a.legacy is None and a.import_origin is None
               for a in session.answers)


def _erased_shape(session):
    return (session.candidate == anonymized_candidate_label(session.id) and session.legacy is None
            and session.draft is None and all(a.answer == REDACTED_TEXT and not a.note and a.legacy is None
                                               and a.import_origin is None for a in session.answers))


def archive_only_erasure(session):
    # Older archives have no receipt. A strict erased shape can preserve a false
    # notice, but may only acquire an unverified hold on restore.
    return (not session.consent and (session.privacy is None or session.privacy.state != "unmarked")
            and _erased_shape(session))


def verify_redaction(session):
    if not _erased_shape(session):
        raise ValueError("The confirmed anonymization contains data that retention should have erased.")
    retained_narratives.verify_archive(session)


def restore(db, session):
    privacy = session.privacy
    if privacy and privacy.state == "anonymized":
        # The archive preserves when protection took effect. It carries no actor identity.
        db.execute("INSERT INTO session_anonymizations(session_id,anonymized_at,anonymized_by) VALUES(?,?,?)",
                   (session.id, privacy.anonymized_at, ""))
    elif (privacy and privacy.state == "legacy_unverified") or (privacy is None and legacy_hold(session)):
        db.execute("INSERT INTO legacy_privacy_holds(session_id) VALUES(?)", (session.id,))
