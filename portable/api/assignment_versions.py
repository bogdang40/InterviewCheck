"""State tokens shared by the assignment editor and the paged review queue."""
import hashlib
import json
import sqlite3
from typing import Annotated

from fastapi import HTTPException
from pydantic import StringConstraints


AssignmentVersion = Annotated[str, StringConstraints(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")]
AssignmentVersions = dict[Annotated[str, StringConstraints(strip_whitespace=False)], AssignmentVersion]
FIELDS = ("assignee_email", "assigned_by", "priority", "due_at", "updated_at")


def version_for(session_id: str, assignment) -> str:
    # Empty queue rows and GET's null assignment represent the same state.
    values = None if assignment is None or assignment["assignee_email"] is None else [assignment[k] for k in FIELDS]
    content = json.dumps([session_id, values], separators=(",", ":"))
    return hashlib.sha256(content.encode()).hexdigest()


def require_versions(db: sqlite3.Connection, expected: dict[str, str]) -> None:
    """Compare the selected rows while the caller holds its assignment write transaction."""
    rows = {}
    if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_assignments'").fetchone():
        marks = ",".join("?" for _ in expected)
        result = db.execute(
            f"SELECT session_id, assignee_email, assigned_by, priority, due_at, updated_at "
            f"FROM session_assignments WHERE session_id IN ({marks})", tuple(expected),
        )
        rows = {row["session_id"]: row for row in result}
    changed = [sid for sid, version in expected.items() if version_for(sid, rows.get(sid)) != version]
    if changed:
        raise HTTPException(409, {"message": "Assignment details changed. Review the current assignments before saving.",
                                  "session_ids": changed}, headers={"X-InterviewCheck-Conflict": "assignment-version"})
