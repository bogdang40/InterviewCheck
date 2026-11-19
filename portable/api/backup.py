"""Portable recovery of review records, separated from credentials and delivery state."""

import hashlib
import hmac
import json
import re
from uuid import UUID, uuid4

from fastapi import APIRouter, Header, HTTPException, Request, Response
from starlette.concurrency import run_in_threadpool

from . import backup_schema as schema, drafts, store

router = APIRouter(prefix="/backups")
ROLE_FIELDS = set(schema.Role.model_fields)
SESSION_FIELDS = set(schema.Session.model_fields)
ANSWER_FIELDS = set(schema.Answer.model_fields)
_HEX_64_LOWER = re.compile(r"^[a-f0-9]{64}$")
_HEX_64_ANY = re.compile(r"^[a-fA-F0-9]{64}$")


def encode(data):
    return json.dumps(data, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def select(data, fields):
    return {
        key: value
        for key, value in data.items()
        if key in fields and (value is not None or key in {"role_id", "ended_at"})
    }


def role_data(row):
    record = select(store.role_row(row), ROLE_FIELDS)
    record.setdefault("policy", "")
    record.setdefault("permitted_sources", [])
    return record


def session_data(db, key):
    record = select(store.get_session(db, key, include_trashed=True), SESSION_FIELDS)
    deleted = db.execute("SELECT trashed_at FROM session_trash WHERE session_id=?", (key,)).fetchone()
    if deleted:
        record["trashed_at"] = deleted["trashed_at"]
    if record.get("draft"):
        record["draft"] = drafts.get(db, key)
    record.setdefault("permitted_sources", [])
    record["answers"] = [select(a, ANSWER_FIELDS) for a in record["answers"]]
    return record


@router.get("/workspace")
def download(session_id: UUID | None = None):
    doc = {"format": "interviewcheck.workspace", "version": 1, "roles": [], "sessions": []}
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
        if session_id:
            record = session_data(db, str(session_id))
            if record["role_id"]:
                append(
                    "roles",
                    role_data(db.execute("SELECT * FROM roles WHERE id=?", (record["role_id"],)).fetchone()),
                )
            append("sessions", record)
        else:
            for row in db.execute("SELECT * FROM roles ORDER BY id"):
                append("roles", role_data(row))
            for row in db.execute("SELECT id FROM sessions ORDER BY created_at,id"):
                append("sessions", session_data(db, row[0]))
    body = encode(doc).encode("utf-8")
    if len(body) > schema.LIMIT:
        raise HTTPException(413, size_error)
    digest = hashlib.sha256(body).hexdigest()
    name = "interview-" + str(session_id) if session_id else "interviewcheck-workspace"
    return Response(
        body,
        media_type="application/json",
        headers={
            "Content-Disposition": f'attachment; filename="{name}.json"',
            "X-Backup-SHA256": digest,
        },
    )


def classify(db, backup):
    actions = {"roles": [], "sessions": []}
    totals = {kind: {"new": 0, "identical": 0, "conflict": 0} for kind in actions}
    conflicts = []
    for group, records in (("roles", backup.roles), ("sessions", backup.sessions)):
        for record in records:
            key = record.id
            if group == "roles":
                row = db.execute("SELECT * FROM roles WHERE id=?", (key,)).fetchone()
                same = row is not None and schema.Role.model_validate(role_data(row)) == record
                exists = row is not None
            else:
                exists = db.execute("SELECT 1 FROM sessions WHERE id=?", (key,)).fetchone() is not None
                same = exists and schema.Session.model_validate(session_data(db, key)) == record
                if not exists:
                    ids = [a.id for a in record.answers]
                    if record.draft:
                        ids.append(record.draft.id)
                    exists = any(
                        db.execute(
                            "SELECT 1 FROM answers WHERE id=? UNION ALL SELECT 1 FROM session_drafts WHERE id=?",
                            (aid, aid),
                        ).fetchone()
                        for aid in ids
                    )
            state = "identical" if same else "conflict" if exists else "new"
            totals[group][state] += 1
            if state == "new":
                actions[group].append(record)
            elif state == "conflict" and len(conflicts) < 20:
                conflicts.append(
                    {"kind": group, "id": key, "label": record.name if group == "roles" else record.candidate}
                )
    return actions, {
        **totals,
        "answers": sum(len(s.answers) for s in backup.sessions),
        "trashed": sum(s.trashed_at is not None for s in backup.sessions),
        "drafts": sum(s.draft is not None for s in backup.sessions),
        "conflicts": conflicts,
    }


def restore_records(db, actions):
    def legacy(obj):
        return encode(obj.legacy) if obj.legacy is not None else None

    def materials(items):
        return encode([r.model_dump() for r in items])

    for role in actions["roles"]:
        db.execute(
            "INSERT INTO roles(id,name,description,questions,legacy,policy,permitted_sources) VALUES(?,?,?,?,?,?,?)",
            (
                role.id,
                role.name,
                role.description,
                json.dumps(role.questions, ensure_ascii=False),
                legacy(role),
                role.policy,
                json.dumps([m.model_dump() for m in role.permitted_sources], ensure_ascii=False),
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
        if s.trashed_at:
            db.execute(
                "INSERT INTO session_trash(session_id,trashed_at,operation_version) VALUES (?,?,?)",
                (s.id, s.trashed_at, str(uuid4())),
            )
        if s.draft:
            d = s.draft
            db.execute(
                "INSERT INTO session_drafts(session_id,id,question,answer,refs,updated_at,revision,parent_answer_id,planned_slot) VALUES(?,?,?,?,?,?,?,?,?)",
                (
                    s.id,
                    d.id,
                    d.question,
                    d.answer,
                    materials(d.references),
                    d.updated_at,
                    d.revision,
                    d.parent_answer_id,
                    d.planned_slot,
                ),
            )
        for a in s.answers:
            db.execute(
                """INSERT INTO answers(id,session_id,question,answer,refs,result,status,disposition,note,legacy,revision,import_origin,parent_answer_id,planned_slot)
                          VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (
                    a.id,
                    s.id,
                    a.question,
                    a.answer,
                    materials(a.references),
                    encode(a.result.model_dump(exclude_none=True)),
                    a.result.status,
                    a.disposition,
                    a.note,
                    legacy(a),
                    a.revision,
                    encode(a.import_origin.model_dump(exclude_none=True)) if a.import_origin else None,
                    a.parent_answer_id,
                    a.planned_slot,
                ),
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
