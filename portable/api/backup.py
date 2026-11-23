"""Portable recovery of review records, separated from credentials and delivery state."""

import hashlib
import hmac
import json
import re
from uuid import UUID, uuid4

from fastapi import APIRouter, Header, HTTPException, Request, Response
from pydantic import ValidationError
from starlette.concurrency import run_in_threadpool

from . import backup_schema as schema, bulk_operations, drafts, store

router = APIRouter(prefix="/backups")
ROLE_FIELDS = set(schema.Role.model_fields)
SESSION_FIELDS = set(schema.Session.model_fields)
ANSWER_FIELDS = set(schema.Answer.model_fields)
_HEX_64_LOWER = re.compile(r"^[a-f0-9]{64}$")
_HEX_64_ANY = re.compile(r"^[a-fA-F0-9]{64}$")


def encode(data):
    return json.dumps(data, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def _has_table(db, name):
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def select(data, fields):
    return {
        key: value
        for key, value in data.items()
        if key in fields and (value is not None or key in {"role_id", "ended_at"})
    }


def role_version_records(db, role_id):
    if db is None or not _has_table(db, "role_versions"):
        return []
    rows = db.execute("SELECT * FROM role_versions WHERE role_id=? ORDER BY version_number ASC", (role_id,)).fetchall()
    return [
        {
            "id": r["id"], "version_number": int(r["version_number"]),
            "content_sha256": r["content_sha256"], "name": r["name"], "description": r["description"],
            "questions": json.loads(r["questions"]), "policy": r["policy"],
            "permitted_sources": json.loads(r["permitted_sources"]), "rubric": json.loads(r["rubric_json"]),
            "change_note": r["change_note"], "created_by": r["created_by"], "created_at": r["created_at"],
        }
        for r in rows
    ]


def role_data(row, db=None):
    record = select(store.role_row(row), ROLE_FIELDS)
    record.setdefault("policy", "")
    record.setdefault("permitted_sources", [])
    record.setdefault("rubric", [])
    record.setdefault("version_number", 1)
    record["versions"] = role_version_records(db, record["id"])
    return record


class InvalidStoredAssignment(HTTPException):
    def __init__(self, session_id):
        super().__init__(409, f"Interview {session_id} contains an assignment that this file cannot preserve. "
                              "Use a SQLite backup or reassign the interview before exporting it.")


def assignment_data(db, key):
    row = db.execute(
        """SELECT assignee_email,assigned_by,priority,due_at,updated_at
           FROM session_assignments WHERE session_id=?""", (key,),
    ).fetchone()
    if row is None:
        return None
    try:
        return schema.Assignment.model_validate(dict(row)).model_dump()
    except ValidationError as exc:
        raise InvalidStoredAssignment(key) from exc


def session_data(db, key, *, has_assignments):
    record = select(store.get_session(db, key, include_trashed=True), SESSION_FIELDS)
    record["assignment"] = assignment_data(db, key) if has_assignments else None
    deleted = db.execute("SELECT trashed_at FROM session_trash WHERE session_id=?", (key,)).fetchone()
    if deleted:
        record["trashed_at"] = deleted["trashed_at"]
    if record.get("draft"):
        record["draft"] = drafts.get(db, key)
    record.setdefault("permitted_sources", [])
    record["answers"] = [select(a, ANSWER_FIELDS) for a in record["answers"]]
    record["tags"] = bulk_operations.tags_for_sessions(db, [key]).get(key, [])
    if _has_table(db, "answer_review_events"):
        events = db.execute(
            """SELECT answer_id,role_id,reviewer_id,reviewer_email,previous_disposition,disposition,created_at
               FROM answer_review_events WHERE session_id=? ORDER BY id ASC""",
            (key,),
        ).fetchall()
        record["review_events"] = [dict(ev) for ev in events]
    else:
        record["review_events"] = []
    return record


@router.get("/workspace")
def download(session_id: UUID | None = None):
    doc = {"format": "interviewcheck.workspace", "version": 3, "roles": [], "sessions": []}
    size = 0
    size_error = (
        "This interview exceeds the JSON backup limit. Use a consistent SQLite database backup."
        if session_id
        else "This workspace exceeds the JSON backup limit. Export individual interviews or use a SQLite backup."
    )

    def append(group, record):
        nonlocal size
        size += len(encode(record).encode("utf-8")) + 1
        if size > schema.LIMIT or len(doc[group]) >= (4000 if group == "roles" else 5000):
            raise HTTPException(413, size_error)
        doc[group].append(record)

    with store.connection() as db:
        has_assignments = _has_table(db, "session_assignments")
        if session_id:
            record = session_data(db, str(session_id), has_assignments=has_assignments)
            if record["role_id"]:
                append("roles", role_data(db.execute("SELECT * FROM roles WHERE id=?", (record["role_id"],)).fetchone(), db))
            append("sessions", record)
        else:
            for row in db.execute("SELECT * FROM roles ORDER BY id"):
                append("roles", role_data(row, db))
            for row in db.execute("SELECT id FROM sessions ORDER BY created_at,id"):
                append("sessions", session_data(db, row[0], has_assignments=has_assignments))
    body = encode(doc).encode("utf-8")
    if len(body) > schema.LIMIT:
        raise HTTPException(413, size_error)
    digest = hashlib.sha256(body).hexdigest()
    name = "interview-" + str(session_id) if session_id else "interviewcheck-workspace"
    return Response(
        body,
        media_type="application/json",
        headers={"Content-Disposition": f'attachment; filename="{name}.json"', "X-Backup-SHA256": digest},
    )


def same_session(db, record, *, has_assignments):
    try:
        data = session_data(db, record.id, has_assignments=has_assignments)
    except InvalidStoredAssignment:
        return False
    return schema.Session.model_validate(data) == record


def classify(db, backup):
    actions = {"roles": [], "sessions": []}
    totals = {kind: {"new": 0, "identical": 0, "conflict": 0} for kind in actions}
    conflicts = []
    assignments = sum(s.assignment is not None for s in backup.sessions)
    # Older files did not record assignments. Compare only the fields those files knew.
    has_assignments = backup.version == 3 and _has_table(db, "session_assignments")
    if assignments and not has_assignments:
        raise HTTPException(409, "Restart InterviewCheck to initialize assignment storage before restoring this backup.")
    for group, records in (("roles", backup.roles), ("sessions", backup.sessions)):
        for record in records:
            key = record.id
            if group == "roles":
                row = db.execute("SELECT * FROM roles WHERE id=?", (key,)).fetchone()
                same = row is not None and schema.Role.model_validate(role_data(row, db)) == record
                exists = row is not None
                if not exists and record.versions and _has_table(db, "role_versions"):
                    exists = any(db.execute("SELECT 1 FROM role_versions WHERE id=?", (v.id,)).fetchone() for v in record.versions)
            else:
                exists = db.execute("SELECT 1 FROM sessions WHERE id=?", (key,)).fetchone() is not None
                same = exists and same_session(db, record, has_assignments=has_assignments)
                if not exists:
                    ids = [a.id for a in record.answers] + ([record.draft.id] if record.draft else [])
                    exists = any(
                        db.execute("SELECT 1 FROM answers WHERE id=? UNION ALL SELECT 1 FROM session_drafts WHERE id=?", (aid, aid)).fetchone()
                        for aid in ids
                    )
            state = "identical" if same else "conflict" if exists else "new"
            totals[group][state] += 1
            if state == "new":
                actions[group].append(record)
            elif state == "conflict" and len(conflicts) < 20:
                conflicts.append({"kind": group, "id": key, "label": record.name if group == "roles" else record.candidate})
    return actions, {
        **totals,
        "answers": sum(len(s.answers) for s in backup.sessions),
        "trashed": sum(s.trashed_at is not None for s in backup.sessions),
        "drafts": sum(s.draft is not None for s in backup.sessions),
        "assignments": assignments,
        "conflicts": conflicts,
    }


def restore_records(db, actions):
    def legacy(obj):
        return encode(obj.legacy) if obj.legacy is not None else None

    def materials(items):
        return encode([r.model_dump() for r in items])

    has_rv = _has_table(db, "role_versions")
    for role in actions["roles"]:
        db.execute(
            """INSERT INTO roles(id,name,description,questions,legacy,policy,permitted_sources,rubric_json,version_number)
               VALUES(?,?,?,?,?,?,?,?,?)""",
            (
                role.id, role.name, role.description, json.dumps(role.questions, ensure_ascii=False),
                legacy(role), role.policy, json.dumps([m.model_dump() for m in role.permitted_sources], ensure_ascii=False),
                materials(role.rubric), role.version_number,
            ),
        )
        if role.versions and has_rv:
            for v in role.versions:
                db.execute(
                    """INSERT INTO role_versions(id,role_id,version_number,content_sha256,name,description,questions,
                       policy,permitted_sources,rubric_json,change_note,created_by,created_at)
                       VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (
                        v.id, role.id, v.version_number, v.content_sha256, v.name, v.description,
                        json.dumps(v.questions, ensure_ascii=False), v.policy, materials(v.permitted_sources),
                        materials(v.rubric), v.change_note, v.created_by, v.created_at,
                    ),
                )
    for s in actions["sessions"]:
        db.execute(
            "INSERT INTO sessions(id,candidate,role,policy,consent,created_at,legacy) VALUES(?,?,?,?,?,?,?)",
            (s.id, s.candidate, s.role, s.policy, s.consent, s.created_at, legacy(s)),
        )
        db.execute(
            "INSERT INTO session_context(session_id,role_id,questions,ended_at,permitted_sources) VALUES(?,?,?,?,?)",
            (s.id, s.role_id, encode(s.planned_questions), s.ended_at, materials(s.permitted_sources)),
        )
        if s.assignment is not None:
            a = s.assignment
            db.execute(
                """INSERT INTO session_assignments(session_id,assignee_email,assigned_by,priority,due_at,updated_at)
                   VALUES(?,?,?,?,?,?)""",
                (s.id, a.assignee_email, a.assigned_by, a.priority, a.due_at, a.updated_at),
            )
        if s.trashed_at:
            db.execute("INSERT INTO session_trash(session_id,trashed_at,operation_version) VALUES (?,?,?)", (s.id, s.trashed_at, str(uuid4())))
        if s.draft:
            d = s.draft
            db.execute(
                "INSERT INTO session_drafts(session_id,id,question,answer,refs,updated_at,revision,parent_answer_id,planned_slot) VALUES(?,?,?,?,?,?,?,?,?)",
                (s.id, d.id, d.question, d.answer, materials(d.references), d.updated_at, d.revision, d.parent_answer_id, d.planned_slot),
            )
        for a in s.answers:
            db.execute(
                """INSERT INTO answers(id,session_id,question,answer,refs,result,status,disposition,note,legacy,revision,import_origin,parent_answer_id,planned_slot)
                          VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (
                    a.id, s.id, a.question, a.answer, materials(a.references),
                    encode(a.result.model_dump(exclude_none=True)), a.result.status, a.disposition, a.note,
                    legacy(a), a.revision, encode(a.import_origin.model_dump(exclude_none=True)) if a.import_origin else None,
                    a.parent_answer_id, a.planned_slot,
                ),
            )
        if s.tags:
            bulk_operations.ensure_table(db)
            for tag in s.tags:
                db.execute("INSERT INTO session_tags(session_id,tag,created_at) VALUES(?,?,?)", (s.id, tag, s.created_at))
        if s.review_events and _has_table(db, "answer_review_events"):
            for ev in s.review_events:
                db.execute(
                    """INSERT INTO answer_review_events(session_id,answer_id,role_id,reviewer_id,reviewer_email,
                       previous_disposition,disposition,created_at) VALUES(?,?,?,?,?,?,?,?)""",
                    (s.id, ev.answer_id, ev.role_id, ev.reviewer_id, ev.reviewer_email, ev.previous_disposition, ev.disposition, ev.created_at),
                )


def process(raw, fingerprint=None, expected_sha256=None):
    digest = hashlib.sha256(raw).hexdigest()
    if expected_sha256 is not None:
        if not _HEX_64_ANY.fullmatch(expected_sha256):
            raise HTTPException(422, "Invalid X-Backup-SHA256 header.")
        if not hmac.compare_digest(expected_sha256.lower(), digest):
            raise HTTPException(409, "Backup SHA-256 checksum does not match the uploaded file.")
    if fingerprint is not None:
        if not _HEX_64_LOWER.fullmatch(fingerprint):
            raise HTTPException(422, "Invalid X-Backup-Preview header.")
        if not hmac.compare_digest(fingerprint, digest):
            raise HTTPException(409, "The file differs from the preview. Preview it again.")
    backup = schema.parse(raw)
    apply = fingerprint is not None
    with store.connection(write=apply) as db:
        actions, summary = classify(db, backup)
        if apply:
            if summary["conflicts"]:
                raise HTTPException(409, "Existing records conflict with the file. Preview the backup again.")
            restore_records(db, actions)
            if db.execute("PRAGMA foreign_key_check").fetchall():
                raise HTTPException(422, "Backup restore failed referential integrity check.")
    return {**summary, "fingerprint": digest}


@router.post("/preview")
async def preview(
    request: Request,
    x_backup_sha256: str | None = Header(default=None, pattern=r"^[a-fA-F0-9]{64}$"),
):
    return await run_in_threadpool(process, await request.body(), None, x_backup_sha256)


@router.post("/restore")
async def restore(
    request: Request,
    x_backup_preview: str = Header(min_length=64, max_length=64, pattern=r"^[a-f0-9]{64}$"),
    x_backup_sha256: str | None = Header(default=None, pattern=r"^[a-fA-F0-9]{64}$"),
):
    return await run_in_threadpool(process, await request.body(), x_backup_preview, x_backup_sha256)
