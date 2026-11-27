"""Role defaults and the permitted material that applied when a session began."""

import hashlib
import json
from uuid import uuid4

from fastapi import HTTPException

from . import session_rubric
from .evidence import compare
from .models import AnswerInput, Reference, RoleInput, SessionInput


def migrate_columns(db):
    roles = {col[1] for col in db.execute("PRAGMA table_info(roles)")}
    context = {col[1] for col in db.execute("PRAGMA table_info(session_context)")}
    if "policy" not in roles:
        db.execute("ALTER TABLE roles ADD COLUMN policy TEXT NOT NULL DEFAULT ''")
    if "permitted_sources" not in roles:
        db.execute("ALTER TABLE roles ADD COLUMN permitted_sources TEXT NOT NULL DEFAULT '[]'")
    if "rubric_json" not in roles:
        db.execute("ALTER TABLE roles ADD COLUMN rubric_json TEXT NOT NULL DEFAULT '[]'")
    if "version_number" not in roles:
        db.execute("ALTER TABLE roles ADD COLUMN version_number INTEGER NOT NULL DEFAULT 1")
    if "permitted_sources" not in context:
        db.execute("ALTER TABLE session_context ADD COLUMN permitted_sources TEXT NOT NULL DEFAULT '[]'")


def serialize_materials(materials):
    return json.dumps([entry.model_dump() for entry in materials], ensure_ascii=False)


def serialize_rubric(rubric):
    return json.dumps([entry.model_dump() for entry in rubric], ensure_ascii=False)


def role_row(row):
    keys = set(row.keys())
    role = {
        **dict(row),
        "questions": json.loads(row["questions"]),
        "permitted_sources": json.loads(row["permitted_sources"]),
        "rubric": json.loads(row["rubric_json"]) if "rubric_json" in keys else [],
        "version_number": int(row["version_number"]) if "version_number" in keys else 1,
    }
    role.pop("rubric_json", None)
    if role.get("legacy"):
        role["legacy"] = json.loads(role["legacy"])
    else:
        role.pop("legacy", None)
    role["version"] = content_version(role)
    return role


def content_version(role):
    """Hash the same editable fields for captured, archived and live role versions."""
    fields = {
        key: role[key]
        for key in ("id", "name", "description", "questions", "policy", "permitted_sources", "rubric")
    }
    return hashlib.sha256(json.dumps(fields, sort_keys=True).encode()).hexdigest()


def check_role_version(row, version):
    if version is not None and role_row(row)["version"] != version:
        raise HTTPException(409, "The saved role changed after you opened it.",
                            headers={"X-InterviewCheck-Conflict": "role-version"})


def create_role(db, role: RoleInput, *, created_by: str = "local-operator"):
    from . import role_versions

    key = str(role.id or uuid4())
    fields = (
        role.name,
        role.description,
        json.dumps(role.questions, ensure_ascii=False),
        role.policy,
        serialize_materials(role.permitted_sources),
        serialize_rubric(role.rubric),
    )
    existing = db.execute("SELECT * FROM roles WHERE id=?", (key,)).fetchone()
    if existing:
        if (
            tuple(
                existing[f]
                for f in ("name", "description", "questions", "policy", "permitted_sources", "rubric_json")
            )
            != fields
        ):
            raise HTTPException(409, "The role ID already belongs to different content.")
        return role_row(existing)
    db.execute(
        """INSERT INTO roles(id,name,description,questions,policy,permitted_sources,rubric_json,version_number)
           VALUES (?,?,?,?,?,?,?,1)""",
        (key, *fields),
    )
    created = db.execute("SELECT * FROM roles WHERE id=?", (key,)).fetchone()
    role_versions.record_snapshot_row(
        db, created, change_note=role.change_note or "Initial version", created_by=created_by
    )
    return role_row(created)


def update_role(db, key, role: RoleInput, *, created_by: str = "local-operator"):
    from . import role_versions

    existing = db.execute("SELECT * FROM roles WHERE id=?", (key,)).fetchone()
    if existing is None:
        raise HTTPException(404, "Role does not exist.")
    check_role_version(existing, role.version)
    if role.version_number is not None and int(existing["version_number"]) != role.version_number:
        raise HTTPException(
            409,
            "The saved role changed after you opened it.",
            headers={"X-InterviewCheck-Conflict": "role-version"},
        )
    role_versions.ensure_initial_snapshot(db, key)
    # Clients predating role materials can still edit their supported fields.
    policy = role.policy if "policy" in role.model_fields_set else existing["policy"]
    sources = (
        serialize_materials(role.permitted_sources)
        if "permitted_sources" in role.model_fields_set
        else existing["permitted_sources"]
    )
    rubric_json = (
        serialize_rubric(role.rubric)
        if "rubric" in role.model_fields_set
        else existing["rubric_json"]
    )
    next_version = int(existing["version_number"]) + 1
    db.execute(
        """UPDATE roles
           SET name=?,description=?,questions=?,policy=?,permitted_sources=?,rubric_json=?,version_number=?
           WHERE id=?""",
        (
            role.name,
            role.description,
            json.dumps(role.questions, ensure_ascii=False),
            policy,
            sources,
            rubric_json,
            next_version,
            key,
        ),
    )
    updated = db.execute("SELECT * FROM roles WHERE id=?", (key,)).fetchone()
    role_versions.record_snapshot_row(db, updated, change_note=role.change_note, created_by=created_by)
    return role_row(updated)


def session_defaults(db, item: SessionInput):
    selected = None
    if item.role_id:
        selected = db.execute("SELECT * FROM roles WHERE id=?", (str(item.role_id),)).fetchone()
        if selected is None:
            raise HTTPException(409, "The selected role has changed. Refresh the role list.")
    elif "role_id" not in item.model_fields_set:
        matches = db.execute("SELECT * FROM roles WHERE name=? LIMIT 2", (item.role,)).fetchall()
        selected = matches[0] if len(matches) == 1 else None
    role_digest = role_row(selected)["version"] if selected else None
    if item.role_version is not None and role_digest != item.role_version:
        raise HTTPException(409, "The saved role changed after you opened it.",
                            headers={"X-InterviewCheck-Conflict": "role-version"})
    if selected is not None and selected["name"] != item.role:
        raise HTTPException(409, "The selected role has changed. Refresh the role list.")
    policy = item.policy or (selected["policy"] if selected else None)
    if not policy:
        raise HTTPException(422, "Enter the assistance policy agreed with the candidate.")
    sources = selected["permitted_sources"] if selected else "[]"
    if item.permitted_sources is not None:
        sources = serialize_materials(item.permitted_sources)
    return (selected["id"] if selected else None, selected["questions"] if selected else "[]",
            policy, sources, session_rubric.capture(selected, role_digest))


def session_materials(db, key):
    row = db.execute("SELECT permitted_sources FROM session_context WHERE session_id=?", (key,)).fetchone()
    return json.loads(row[0]) if row else []


def compare_answer(item: AnswerInput, materials):
    # The editor owns exchange references. Session sources always remain permitted,
    # even if a client also submits their text as an ordinary comparison source.
    inherited = [Reference(label=entry["label"], text=entry["text"], permitted=True) for entry in materials]
    return compare(item.question, item.answer, [*item.references, *inherited])
