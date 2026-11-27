"""Portable recovery of review records, separated from credentials and delivery state."""

import hashlib
import hmac
import json
import re
from uuid import UUID, uuid4

from pydantic import ValidationError

from fastapi import APIRouter, Header, HTTPException, Request, Response
from starlette.concurrency import run_in_threadpool

from . import backup_conflicts, backup_schema as schema, bulk_operations, drafts, store
from . import backup_review_data as review_data
from . import session_privacy, session_rubric

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


def session_data(db, key, *, has_assignments, has_notes, has_scorecards, include_v6=True):
    record = select(store.get_session(db, key, include_trashed=True), SESSION_FIELDS)
    snapshot = session_rubric.read(db, key) if include_v6 else None
    record["rubric_snapshot"] = snapshot.model_dump() if snapshot else None
    record["privacy"] = session_privacy.read(db, key).model_dump() if include_v6 else None
    record["assignment"] = review_data.assignment_data(db, key) if has_assignments else None
    record["handoff_notes"] = review_data.handoff_data(db, key) if has_notes else []
    record["scorecard_items"] = review_data.scorecard_data(db, key) if has_scorecards else []
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
    if record["privacy"] and record["privacy"]["state"] == "anonymized":
        try:
            schema.Session.model_validate(record)
        except ValidationError as exc:
            raise review_data.UnrepresentableReviewData(409, "The anonymization receipt conflicts with stored interview data. "
                                                        "Inspect the SQLite backup before exporting this interview.") from exc
    return record


@router.get("/workspace")
def download(session_id: UUID | None = None):
    doc = {"format": "interviewcheck.workspace", "version": 6, "roles": [], "sessions": []}
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
        has_notes = _has_table(db, "session_handoff_notes")
        has_scorecards = _has_table(db, "session_scorecards")
        if session_id:
            record = session_data(
                db, str(session_id), has_assignments=has_assignments, has_notes=has_notes, has_scorecards=has_scorecards,
            )
            if record["role_id"]:
                append("roles", role_data(db.execute("SELECT * FROM roles WHERE id=?", (record["role_id"],)).fetchone(), db))
            append("sessions", record)
        else:
            for row in db.execute("SELECT * FROM roles ORDER BY id"):
                append("roles", role_data(row, db))
            for row in db.execute("SELECT id FROM sessions ORDER BY created_at,id"):
                append(
                    "sessions",
                    session_data(
                        db, row[0], has_assignments=has_assignments, has_notes=has_notes, has_scorecards=has_scorecards,
                    ),
                )
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


def stored_session(db, key, *, has_assignments, has_notes, has_scorecards, include_v6):
    try:
        data = session_data(
            db, key, has_assignments=has_assignments, has_notes=has_notes, has_scorecards=has_scorecards,
            include_v6=include_v6,
        )
    except (review_data.UnrepresentableReviewData, session_rubric.UnreadableRubric, session_privacy.UnreadablePrivacy):
        return None
    return schema.Session.model_validate(data)


def _has_exchange_collision(db, session):
    if not session.answers and session.draft is None:
        return False
    ids = [answer.id for answer in session.answers]
    if session.draft is not None:
        ids.append(session.draft.id)
    # A parked draft and a published exchange share one ID namespace, including in Trash.
    return db.execute(
        """SELECT 1 FROM json_each(?) AS incoming
           WHERE EXISTS (SELECT 1 FROM answers WHERE id=incoming.value)
              OR EXISTS (SELECT 1 FROM session_drafts WHERE id=incoming.value)
           LIMIT 1""", (encode(ids),),
    ).fetchone() is not None


def classify(db, backup, *, include_conflict_reasons=False):
    actions = {"roles": [], "sessions": []}
    totals = {kind: {"new": 0, "identical": 0, "conflict": 0} for kind in actions}
    conflicts = []
    if backup.sessions:
        session_privacy.require_storage(db)
    assignments = sum(s.assignment is not None for s in backup.sessions)
    # Compare only fields included by the writer's version.
    has_assignments = backup.version >= 3 and _has_table(db, "session_assignments")
    notes = sum(len(s.handoff_notes) for s in backup.sessions)
    has_notes = backup.version >= 4 and _has_table(db, "session_handoff_notes")
    scorecards = sum(len(s.scorecard_items) for s in backup.sessions)
    has_scorecards = backup.version >= 5 and _has_table(db, "session_scorecards")
    if assignments and not has_assignments:
        raise HTTPException(409, "Restart InterviewCheck to initialize assignment storage before restoring this backup.")
    if notes and not has_notes:
        raise HTTPException(409, "Restart InterviewCheck to initialize handoff note storage before restoring this backup.")
    if scorecards and not has_scorecards:
        raise HTTPException(409, "Restart InterviewCheck to initialize scorecard storage before restoring this backup.")
    for group, records in (("roles", backup.roles), ("sessions", backup.sessions)):
        for record in records:
            key = record.id
            stored = None
            linked_collision = False
            if group == "roles":
                row = db.execute("SELECT * FROM roles WHERE id=?", (key,)).fetchone()
                exists = row is not None
                if exists:
                    stored = schema.Role.model_validate(role_data(row, db))
                elif record.versions and _has_table(db, "role_versions"):
                    linked_collision = db.execute(
                        """SELECT 1 FROM json_each(?) AS incoming
                           WHERE EXISTS (SELECT 1 FROM role_versions WHERE id=incoming.value) LIMIT 1""",
                        (encode([v.id for v in record.versions]),),
                    ).fetchone() is not None
            else:
                exists = db.execute("SELECT 1 FROM sessions WHERE id=?", (key,)).fetchone() is not None
                if exists:
                    stored = stored_session(db, key, has_assignments=has_assignments, has_notes=has_notes,
                                            has_scorecards=has_scorecards, include_v6=backup.version >= 6)
                else:
                    linked_collision = review_data.has_handoff_collision(db, record.handoff_notes) or _has_exchange_collision(db, record)
            state = "identical" if stored == record else "conflict" if exists or linked_collision else "new"
            totals[group][state] += 1
            if state == "new":
                actions[group].append(record)
            elif state == "conflict" and len(conflicts) < 20:
                sample = {"kind": group, "id": key, "label": record.name if group == "roles" else record.candidate}
                if include_conflict_reasons:
                    if linked_collision:
                        sample["reasons"] = ["linked_id_in_use"]
                    elif stored is None:
                        sample["reasons"] = ["cannot_compare"]
                    else:
                        sample["reasons"] = backup_conflicts.changed_sections(group, stored, record)
                conflicts.append(sample)
    return actions, {
        **totals,
        "answers": sum(len(s.answers) for s in backup.sessions),
        "trashed": sum(s.trashed_at is not None for s in backup.sessions),
        "drafts": sum(s.draft is not None for s in backup.sessions),
        "assignments": assignments,
        "handoff_notes": notes,
        "scorecard_items": scorecards,
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
            """INSERT INTO session_context(session_id,role_id,questions,ended_at,permitted_sources,rubric_snapshot)
               VALUES(?,?,?,?,?,?)""",
            (s.id, s.role_id, encode(s.planned_questions), s.ended_at, materials(s.permitted_sources),
             s.rubric_snapshot.model_dump_json() if s.rubric_snapshot else None),
        )
        # A confirmed receipt seals the original, already validated narrative rows.
        review_data.restore_review_data(db, s)
        session_privacy.restore(db, s)
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


def process(raw, fingerprint=None, expected_sha256=None, *, include_conflict_reasons=False):
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
        actions, summary = classify(db, backup, include_conflict_reasons=include_conflict_reasons and not apply)
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
    include_conflict_reasons: bool = False,
):
    return await run_in_threadpool(process, await request.body(), None, x_backup_sha256,
                                   include_conflict_reasons=include_conflict_reasons)


@router.post("/restore")
async def restore(
    request: Request,
    x_backup_preview: str = Header(min_length=64, max_length=64, pattern=r"^[a-f0-9]{64}$"),
    x_backup_sha256: str | None = Header(default=None, pattern=r"^[a-fA-F0-9]{64}$"),
):
    return await run_in_threadpool(process, await request.body(), x_backup_preview, x_backup_sha256)
