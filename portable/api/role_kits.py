"""Role defaults and the permitted material that applied when a session began."""

import hashlib
import json
from uuid import uuid4

from fastapi import HTTPException

from .evidence import compare
from .models import AnswerInput, Reference, RoleInput, SessionInput


def migrate_columns(db):
    roles = {col[1] for col in db.execute("PRAGMA table_info(roles)")}
    context = {col[1] for col in db.execute("PRAGMA table_info(session_context)")}
    if "policy" not in roles:
        db.execute("ALTER TABLE roles ADD COLUMN policy TEXT NOT NULL DEFAULT ''")
    if "permitted_sources" not in roles:
        db.execute("ALTER TABLE roles ADD COLUMN permitted_sources TEXT NOT NULL DEFAULT '[]'")
    if "permitted_sources" not in context:
        db.execute("ALTER TABLE session_context ADD COLUMN permitted_sources TEXT NOT NULL DEFAULT '[]'")


def serialize_materials(materials):
    return json.dumps([entry.model_dump() for entry in materials], ensure_ascii=False)


def role_row(row):
    role = {
        **dict(row),
        "questions": json.loads(row["questions"]),
        "permitted_sources": json.loads(row["permitted_sources"]),
    }
    if role["legacy"]:
        role["legacy"] = json.loads(role["legacy"])
    else:
        del role["legacy"]
    # Bind open forms to the editable content, including templates restored from a backup.
    fields = {key: role[key] for key in ("id", "name", "description", "questions", "policy", "permitted_sources")}
    role["version"] = hashlib.sha256(json.dumps(fields, sort_keys=True).encode()).hexdigest()
    return role


def check_role_version(row, version):
    if version is not None and role_row(row)["version"] != version:
        raise HTTPException(409, "The saved role changed after you opened it.",
                            headers={"X-InterviewCheck-Conflict": "role-version"})


def create_role(db, role: RoleInput):
    key = str(role.id or uuid4())
    fields = (
        role.name,
        role.description,
        json.dumps(role.questions, ensure_ascii=False),
        role.policy,
        serialize_materials(role.permitted_sources),
    )
    existing = db.execute("SELECT * FROM roles WHERE id=?", (key,)).fetchone()
    if existing:
        if (
            tuple(existing[f] for f in ("name", "description", "questions", "policy", "permitted_sources"))
            != fields
        ):
            raise HTTPException(409, "The role ID already belongs to different content.")
        return role_row(existing)
    db.execute(
        "INSERT INTO roles(id,name,description,questions,policy,permitted_sources) VALUES (?,?,?,?,?,?)",
        (key, *fields),
    )
    return role_row(db.execute("SELECT * FROM roles WHERE id=?", (key,)).fetchone())


def update_role(db, key, role: RoleInput):
    existing = db.execute("SELECT * FROM roles WHERE id=?", (key,)).fetchone()
    if existing is None:
        raise HTTPException(404, "Role does not exist.")
    check_role_version(existing, role.version)
    # Clients predating role materials can still edit their supported fields.
    policy = role.policy if "policy" in role.model_fields_set else existing["policy"]
    sources = (
        serialize_materials(role.permitted_sources)
        if "permitted_sources" in role.model_fields_set
        else existing["permitted_sources"]
    )
    db.execute(
        "UPDATE roles SET name=?,description=?,questions=?,policy=?,permitted_sources=? WHERE id=?",
        (role.name, role.description, json.dumps(role.questions, ensure_ascii=False), policy, sources, key),
    )
    return role_row(db.execute("SELECT * FROM roles WHERE id=?", (key,)).fetchone())


def session_defaults(db, item: SessionInput):
    selected = None
    if item.role_id:
        selected = db.execute("SELECT * FROM roles WHERE id=?", (str(item.role_id),)).fetchone()
        if selected is not None:
            check_role_version(selected, item.role_version)
        if selected is None or selected["name"] != item.role:
            raise HTTPException(409, "The selected role has changed. Refresh the role list.")
    elif "role_id" not in item.model_fields_set:
        matches = db.execute("SELECT * FROM roles WHERE name=? LIMIT 2", (item.role,)).fetchall()
        selected = matches[0] if len(matches) == 1 else None
    policy = item.policy or (selected["policy"] if selected else None)
    if not policy:
        raise HTTPException(422, "Enter the assistance policy agreed with the candidate.")
    sources = selected["permitted_sources"] if selected else "[]"
    if item.permitted_sources is not None:
        sources = serialize_materials(item.permitted_sources)
    return selected["id"] if selected else None, selected["questions"] if selected else "[]", policy, sources


def session_materials(db, key):
    row = db.execute("SELECT permitted_sources FROM session_context WHERE session_id=?", (key,)).fetchone()
    return json.loads(row[0]) if row else []


def compare_answer(item: AnswerInput, materials):
    # The editor owns exchange references. Session sources always remain permitted,
    # even if a client also submits their text as an ordinary comparison source.
    inherited = [Reference(label=entry["label"], text=entry["text"], permitted=True) for entry in materials]
    return compare(item.question, item.answer, [*item.references, *inherited])
