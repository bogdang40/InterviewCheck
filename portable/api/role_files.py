"""Portable files contain only the editable role template and its stable ID."""

import json

from fastapi import HTTPException, Response
from pydantic import ValidationError

from .models import RoleInput
from .role_kits import create_role, role_row

FORMAT = "interviewcheck.role-kit"
FIELDS = {"id", "name", "description", "questions", "policy", "permitted_sources"}
# All permitted text fits even when JSON uses six bytes for a control character.
FILE_LIMIT = 4 * 1024 * 1024


def saved_fields(db, key):
    row = db.execute(
        "SELECT id,name,description,questions,policy,permitted_sources FROM roles WHERE id=?", (key,)
    ).fetchone()
    if row is None:
        return None
    return {**dict(row), "questions": json.loads(row["questions"]),
            "permitted_sources": json.loads(row["permitted_sources"])}


def validated(data):
    if not isinstance(data, dict) or data.keys() != FIELDS:
        raise ValueError("A portable role kit must contain exactly the six template fields.")
    if not isinstance(data["id"], str):
        raise ValueError("A portable role kit requires a saved role ID.")
    try:
        role = RoleInput.model_validate(data)
    except ValidationError as exc:
        raise ValueError("The role kit contains an invalid ID or template field.") from exc
    if role.model_dump(mode="json", include=FIELDS) != data:
        raise ValueError("The template contains values that cannot be copied exactly. Edit and save it first.")
    return role


def read_file(document):
    if (document.keys() != {"format", "version", "role"} or document["format"] != FORMAT
            or type(document["version"]) is not int or document["version"] != 1):
        raise ValueError("Expected a portable role kit with format version 1.")
    return validated(document["role"])


def classify(db, role):
    data = role.model_dump(mode="json", include=FIELDS)
    saved = saved_fields(db, data["id"])
    if saved is None:
        return "new"
    return "identical" if saved == data else "conflict"


def preview(db, document):
    role = read_file(document)
    state = classify(db, role)
    return {"id": str(role.id), "name": role.name, "question_count": len(role.questions),
            "duplicate": state == "identical", "conflict": state == "conflict"}


def import_file(db, document):
    role = read_file(document)
    state = classify(db, role)
    if state == "conflict":
        raise HTTPException(409, "A saved role with this ID has different content.")
    if state == "identical":
        row = db.execute("SELECT * FROM roles WHERE id=?", (str(role.id),)).fetchone()
        return 0, role_row(row)
    return 1, create_role(db, role)


def saved_template(db, key):
    data = saved_fields(db, key)
    if data is None:
        raise HTTPException(404, "Role does not exist.")
    try:
        return validated(data)
    except ValueError as exc:
        raise HTTPException(422, "Edit and save this template within the role field limits before copying it.") from exc


def download(db, key):
    role = saved_template(db, key)
    document = {"format": FORMAT, "version": 1, "role": role.model_dump(mode="json", include=FIELDS)}
    body = json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode()
    if len(body) > FILE_LIMIT:
        raise HTTPException(413, "The saved role exceeds the 4 MiB role file limit.")
    return Response(body, media_type="application/json", headers={
        "Content-Disposition": f'attachment; filename="role-{key}.json"'
    })


def duplicate(db, source_id, new_id):
    if source_id == new_id:
        raise HTTPException(409, "Choose a new ID for the duplicate role.")
    source = saved_template(db, str(source_id))
    return create_role(db, source.model_copy(update={"id": new_id}))
