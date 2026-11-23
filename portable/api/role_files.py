"""Portable files contain only the editable role template and its stable ID."""

import json

from fastapi import HTTPException, Response
from pydantic import ValidationError

from .models import RoleInput
from .role_kits import create_role, role_row

FORMAT = "interviewcheck.role-kit"
V1_FIELDS = {"id", "name", "description", "questions", "policy", "permitted_sources"}
FIELDS = V1_FIELDS | {"rubric"}
FILE_LIMIT = 4 * 1024 * 1024


def saved_fields(db, key, fields=FIELDS):
    row = db.execute(
        "SELECT id,name,description,questions,policy,permitted_sources,rubric_json AS rubric FROM roles WHERE id=?", (key,)
    ).fetchone()
    if row is None:
        return None
    data = {name: row[name] for name in fields}
    for name in ("questions", "permitted_sources", "rubric"):
        if name in data:
            data[name] = json.loads(data[name])
    return data


def validated(data, fields):
    if not isinstance(data, dict) or data.keys() != fields:
        raise ValueError("The template fields do not match the role kit version.")
    if not isinstance(data["id"], str):
        raise ValueError("A portable role kit requires a saved role ID.")
    try:
        role = RoleInput.model_validate(data)
    except ValidationError as exc:
        raise ValueError("The role kit contains an invalid ID or template field.") from exc
    if role.model_dump(mode="json", include=fields) != data:
        raise ValueError("The template contains values that cannot be copied exactly. Edit and save it first.")
    return role


def read_file(document):
    if (not isinstance(document, dict) or document.keys() != {"format", "version", "role"}
            or document["format"] != FORMAT or type(document["version"]) is not int or document["version"] not in (1, 2)):
        raise ValueError("Expected a portable role kit with format version 1 or 2.")
    return validated(document["role"], V1_FIELDS if document["version"] == 1 else FIELDS)


def classify(db, role):
    # Version 1 has no rubric information and cannot clear an existing rubric.
    fields = FIELDS if "rubric" in role.model_fields_set else V1_FIELDS
    data = role.model_dump(mode="json", include=fields)
    try:
        saved = saved_fields(db, data["id"], fields)
    except json.JSONDecodeError:
        return "conflict"
    if saved is None:
        return "new"
    return "identical" if saved == data else "conflict"


def preview(db, document):
    role = read_file(document)
    state = classify(db, role)
    summary = {"id": str(role.id), "name": role.name, "question_count": len(role.questions),
               "duplicate": state == "identical", "conflict": state == "conflict"}
    if "rubric" in role.model_fields_set:
        summary["rubric_count"] = len(role.rubric)
    return summary


def import_file(db, document, *, created_by="local-operator"):
    role = read_file(document)
    state = classify(db, role)
    if state == "conflict":
        raise HTTPException(409, "A saved role with this ID has different content.")
    if state == "identical":
        row = db.execute("SELECT * FROM roles WHERE id=?", (str(role.id),)).fetchone()
        return 0, role_row(row)
    return 1, create_role(db, role.model_copy(update={"change_note": "Imported role"}), created_by=created_by)


def saved_template(db, key):
    try:
        data = saved_fields(db, key)
        if data is None:
            raise HTTPException(404, "Role does not exist.")
        return validated(data, FIELDS)
    except ValueError as exc:
        raise HTTPException(422, "Edit and save this template within the role field limits before copying it.") from exc


def download(db, key):
    role = saved_template(db, key)
    document = {"format": FORMAT, "version": 2, "role": role.model_dump(mode="json", include=FIELDS)}
    body = json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode()
    if len(body) > FILE_LIMIT:
        raise HTTPException(413, "The saved role exceeds the 4 MiB role file limit.")
    return Response(body, media_type="application/json", headers={
        "Content-Disposition": f'attachment; filename="role-{key}.json"'
    })


def duplicate(db, source_id, new_id, *, created_by: str = "local-operator"):
    if source_id == new_id:
        raise HTTPException(409, "Choose a new ID for the duplicate role.")
    source = saved_template(db, str(source_id))
    return create_role(db, source.model_copy(update={"id": new_id}), created_by=created_by)
