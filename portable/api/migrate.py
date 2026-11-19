"""Import a native database snapshot or exported role into the portable workspace."""
import argparse
from contextlib import closing
from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3
from uuid import uuid5, NAMESPACE_URL

from fastapi import HTTPException

from . import role_files, store

ARCHIVED = {
    "archived": True,
    "status": "insufficient",
    "explanation": "Imported native record. The original assessment is available in the report.",
    "passages": [],
    "follow_up": "Review the original transcript and agreed resources before interpreting this record.",
}


def portable_id(kind, native_id):
    if not isinstance(native_id, str) or not native_id.strip():
        raise ValueError(f"The native {kind} has no identifier.")
    return str(uuid5(NAMESPACE_URL, f"interviewcheck:native:{kind}:{native_id}"))


def role_fields(role, native_id):
    key = portable_id("role", native_id)
    if not isinstance(role, dict):
        raise ValueError("Invalid native role object.")
    title = role.get("name", "")
    company = role.get("company", "")
    questions = role.get("plannedQuestions", [])
    if any(not isinstance(value, str) for value in (title, company, role.get("jobDescription", ""))):
        raise ValueError("Invalid native role title, company or job description.")
    if not isinstance(questions, list) or any(not isinstance(q, dict) or not isinstance(q.get("text"), str) for q in questions):
        raise ValueError("A native role has invalid planned questions.")
    return (key, " at ".join(filter(None, [title, company])) or "Untitled role", role.get("jobDescription", ""),
            json.dumps([q["text"] for q in questions]), json.dumps(role, ensure_ascii=False))


def save_role(target, role, native_id):
    return target.execute(
        "INSERT INTO roles(id,name,description,questions,legacy) VALUES (?,?,?,?,?) ON CONFLICT(id) DO NOTHING",
        role_fields(role, native_id)).rowcount


def exported_profile(document):
    if not isinstance(document, dict) or document.get("format") != "interviewcheck.role" or document.get("version") != 1:
        raise ValueError("Expected an InterviewCheck version 1 role export.")
    role = document.get("role")
    if not isinstance(role, dict):
        raise ValueError("Role export has no role object.")
    return role


def preview_role(target, document):
    if isinstance(document, dict) and document.get("format") == role_files.FORMAT:
        return role_files.preview(target, document)
    role = exported_profile(document)
    key, title, _, questions, _ = role_fields(role, role.get("workspaceID"))
    found = target.execute("SELECT id FROM roles WHERE id=?", (key,)).fetchone()
    return {"id": key, "name": title, "question_count": len(json.loads(questions)), "duplicate": bool(found)}


def import_role(target, document):
    if isinstance(document, dict) and document.get("format") == role_files.FORMAT:
        return role_files.import_file(target, document)
    role = exported_profile(document)
    key = role.get("workspaceID")
    added = save_role(target, role, key)
    return added, store.role_row(target.execute("SELECT * FROM roles WHERE id=?", (portable_id("role", key),)).fetchone())


def native_answer(source, target, session_id, question, tables):
    aid = question["id"]
    # The SELECT statements are fixed native schema queries. Optional tables were
    # introduced after v17 and may be absent from an older snapshot.
    refs = [dict(r) for r in source.execute("SELECT * FROM reference_answers WHERE question_id=? ORDER BY rowid", (aid,))]
    score = source.execute("SELECT * FROM answer_scores WHERE question_id=?", (aid,)).fetchone()
    legacy = {"question": dict(question), "reference_answers": refs, "score": dict(score) if score else None}
    if score:
        for key in ("reasons", "counterpoints", "follow_ups", "metrics"):
            if legacy["score"].get(key):
                legacy["score"][key] = json.loads(legacy["score"][key])
    note = ""
    if "answer_notes" in tables:
        row = source.execute("SELECT * FROM answer_notes WHERE question_id=?", (aid,)).fetchone()
        if row:
            legacy["note"] = dict(row)
            note = row["note"]
    if "answer_labels" in tables:
        row = source.execute("SELECT * FROM answer_labels WHERE question_id=?", (aid,)).fetchone()
        if row:
            legacy["label"] = dict(row)
    usable = [{"text": ref["text"], "label": " / ".join(filter(None, (ref["provider"], ref["model"], ref["prompt_name"]))),
               "permitted": False} for ref in refs if ref["text"] and not ref["error"]]
    target.execute("""INSERT INTO answers
        (id,session_id,question,answer,refs,result,status,note,legacy) VALUES (?,?,?,?,?,?,?,?,?)""",
        (portable_id("answer", aid), session_id, question["text"], question["answer_text"],
         json.dumps(usable, ensure_ascii=False), json.dumps(ARCHIVED), "insufficient", note, json.dumps(legacy, ensure_ascii=False)))


def import_db(source_path, target):
    counts = {"sessions": 0, "answers": 0, "roles": 0}
    uri = source_path.resolve().as_uri() + "?mode=ro"
    with closing(sqlite3.connect(uri, uri=True)) as source:
        source.row_factory = sqlite3.Row
        source.execute("PRAGMA query_only=ON")
        source.execute("PRAGMA trusted_schema=OFF")
        source.execute("BEGIN")
        tables = {r[0] for r in source.execute("SELECT name FROM sqlite_schema WHERE type='table'")}
        required = {"interviews", "interview_questions", "reference_answers", "answer_scores", "role_profiles"}
        if not required <= tables:
            raise ValueError("The file does not contain the InterviewCheck native report tables.")
        for row in source.execute("SELECT workspace_id,profile FROM role_profiles"):
            counts["roles"] += save_role(target, json.loads(row["profile"]), row["workspace_id"])
        for interview in source.execute("SELECT * FROM interviews ORDER BY started_at,rowid"):
            key = portable_id("session", interview["id"])
            created = datetime.fromtimestamp(interview["started_at"] / 1000, timezone.utc).isoformat()
            inserted = target.execute("""INSERT INTO sessions VALUES (?,?,?,?,?,?,?) ON CONFLICT(id) DO NOTHING""",
                (key, interview["candidate_name"], interview["role_title"], "Resource policy unavailable in native report.",
                 interview["consent_confirmed_at"] is not None, created, json.dumps(dict(interview)))).rowcount
            if inserted:
                original = dict(interview)
                native_role = original.get("workspace_id")
                role = target.execute("SELECT id,questions FROM roles WHERE id=?",
                                      (portable_id("role", native_role),)).fetchone() if native_role else None
                end = original.get("ended_at")
                ended_at = datetime.fromtimestamp(end / 1000, timezone.utc).isoformat() if end is not None else None
                target.execute("INSERT INTO session_context(session_id,role_id,questions,ended_at) VALUES (?,?,?,?)",
                               (key, role["id"] if role else None, role["questions"] if role else "[]", ended_at))
                counts["sessions"] += 1
                for q in source.execute("SELECT * FROM interview_questions WHERE interview_id=? ORDER BY ordinal,rowid",
                                        (interview["id"],)):
                    native_answer(source, target, key, q, tables)
                    counts["answers"] += 1
    return counts


def migrate(source, destination):
    source, destination = Path(source).resolve(), Path(destination).resolve()
    if not source.is_file() or source == destination or (destination.exists() and source.samefile(destination)):
        raise ValueError("Supply an existing source and a separate destination.")
    store.initialize(destination)
    with store.connection(destination, write=True) as db:
        if source.suffix.casefold() == ".json":
            if source.stat().st_size > role_files.FILE_LIMIT:
                raise ValueError("Role export exceeds 4 MiB.")
            try:
                added, _ = import_role(db, json.loads(source.read_text(encoding="utf-8-sig")))
            except HTTPException as exc:
                raise ValueError(exc.detail) from exc
            return {"roles": added, "sessions": 0, "answers": 0}
        return import_db(source, db)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--destination", type=Path, default=store.db_path())
    args = parser.parse_args()
    try:
        print(json.dumps(migrate(args.source, args.destination)))
    except (ValueError, OSError, sqlite3.Error, TypeError, OverflowError) as exc:
        parser.exit(1, f"Import failed: {exc}\n")
