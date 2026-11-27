"""Replace one interview's personal content with redaction markers that stay self consistent."""

import json
import sqlite3

from .evidence import compare
from .models import Reference

REDACTED_TEXT = "[Redacted by retention policy]"


def anonymized_candidate_label(session_id):
    return f"Candidate [Anonymized {session_id[:8]}]"


def _has_table(db: sqlite3.Connection, name: str) -> bool:
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def _references(raw: str) -> list[Reference]:
    try:
        items = json.loads(raw) if raw else []
    except (TypeError, ValueError):
        return []
    return [
        Reference.model_construct(label=str(item.get("label", "")), text=str(item.get("text", "")),
                                  permitted=bool(item.get("permitted", False)))
        for item in items if isinstance(item, dict)
    ] if isinstance(items, list) else []


class SessionAnonymizer:
    """Redacts one session inside the caller's write transaction.

    A stored finding must equal what the comparison computes from the stored text,
    or a workspace backup of the session cannot be restored. The finding is therefore
    recomputed from the redaction marker rather than scrubbed in place.
    """

    def __init__(self, db: sqlite3.Connection, sid: str):
        self.db, self.sid = db, sid

    def run(self, *, preserve_scorecard_aggregates: bool, actor_email: str, now_iso: str) -> None:
        self.db.execute("UPDATE sessions SET candidate=?, legacy=NULL WHERE id=?",
                        (anonymized_candidate_label(self.sid), self.sid))
        self._redact_history()
        self._redact_answers()
        self._redact_note_exports()
        for table in ("session_drafts", "transcript_imports", "legacy_privacy_holds", "ats_access_versions"):
            if _has_table(self.db, table):
                self.db.execute(f"DELETE FROM {table} WHERE session_id=?", (self.sid,))
        if not preserve_scorecard_aggregates:
            self._clear_narratives()
        self.db.execute(
            "INSERT INTO session_anonymizations(session_id, anonymized_at, anonymized_by) VALUES (?,?,?)",
            (self.sid, now_iso, actor_email),
        )

    def _redact_answers(self) -> None:
        inherited = _references(self._permitted_sources())
        rows = self.db.execute("SELECT id, question, refs, disposition FROM answers WHERE session_id=?", (self.sid,))
        for row in rows.fetchall():
            refs = [*_references(row["refs"]), *(Reference.model_construct(label=r.label, text=r.text, permitted=True)
                                                 for r in inherited)]
            result = compare(row["question"], REDACTED_TEXT, refs)
            # A disclosure is only valid with the note that records it, which is erased here.
            disposition = "pending" if row["disposition"] == "disclosed" else row["disposition"]
            self.db.execute(
                "UPDATE answers SET answer=?, note='', legacy=NULL, import_origin=NULL, result=?, status=?, "
                "disposition=?, revision=revision+1 WHERE id=?",
                (REDACTED_TEXT, json.dumps(result), result["status"], disposition, row["id"]),
            )

    def _permitted_sources(self) -> str:
        row = self.db.execute("SELECT permitted_sources FROM session_context WHERE session_id=?", (self.sid,)).fetchone()
        return row["permitted_sources"] if row else "[]"

    def _redact_history(self) -> None:
        if _has_table(self.db, "answer_history"):
            self.db.execute("DELETE FROM answer_history WHERE answer_id IN (SELECT id FROM answers WHERE session_id=?)",
                            (self.sid,))

    def _redact_note_exports(self) -> None:
        if _has_table(self.db, "note_exports"):
            self.db.execute("UPDATE note_exports SET recipient=?, draft=? WHERE session_id=?",
                            (REDACTED_TEXT, REDACTED_TEXT, self.sid))

    def _clear_narratives(self) -> None:
        if _has_table(self.db, "session_scorecards"):
            self.db.execute("UPDATE session_scorecards SET rationale='' WHERE session_id=?", (self.sid,))
        if _has_table(self.db, "session_handoff_notes"):
            self.db.execute("UPDATE session_handoff_notes SET body='' WHERE session_id=?", (self.sid,))
