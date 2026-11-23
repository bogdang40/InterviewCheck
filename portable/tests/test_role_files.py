from uuid import uuid4
from unittest.mock import AsyncMock

from fastapi.testclient import TestClient
import pytest

from api import access, store
from api.main import app
from api.migrate import migrate
from api.models import RoleInput

TEMPLATE = {
    "name": "Ingénieur", "description": "Équipe Ω", "questions": ["Why?\nExplain.", "Why?\nExplain."],
    "policy": "Le manuel est permis.", "permitted_sources": [{"label": "Manual", "text": "Mesure Δ."}],
}
RUBRIC = [
    {"id": "testing", "criterion": "Test design", "weight": 2, "expected_signals": ["Reproduces failures"], "red_flags": []},
    {"id": "design", "criterion": "System design", "weight": 3, "expected_signals": ["Explains Δ"], "red_flags": ["No tradeoff"]},
]
HEADERS = {"X-InterviewCheck": "1"}


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "source.sqlite"))
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers=HEADERS) as web:
        yield web


def test_file_roundtrip_privacy_and_conflict_after_preview(client, tmp_path, monkeypatch):
    source = client.post("/api/roles", json={**TEMPLATE, "rubric": RUBRIC}).raise_for_status().json()
    rid = source["id"]
    client.post("/api/sessions", json={"candidate": "PRIVATE-CANDIDATE", "role": source["name"],
                "role_id": rid, "consent": True}).raise_for_status()
    with store.connection(write=True) as db:
        db.execute("UPDATE roles SET legacy=? WHERE id=?", ('{"notes":"PRIVATE-NATIVE"}', rid))
    response = client.get(f"/api/roles/{rid}/export").raise_for_status()
    assert response.headers["content-disposition"] == f'attachment; filename="role-{rid}.json"'
    assert response.headers["cache-control"] == "no-store"
    doc = response.json()
    assert doc == {"format": "interviewcheck.role-kit", "version": 2, "role": {"id": rid, **TEMPLATE, "rubric": RUBRIC}}
    assert "PRIVATE-" not in response.text

    target = tmp_path / "destination.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
    import_path = "/api/roles/import"
    preview = import_path + "/preview"
    plan = client.post(preview, json=doc).raise_for_status().json()
    assert not plan["duplicate"] and plan["rubric_count"] == 2
    assert client.get("/api/roles").json() == []
    monkeypatch.setattr(access, "optional_actor", AsyncMock(return_value=("reviewer", "importer@example.test")))
    assert client.post(import_path, json=doc).json() == source
    assert client.post(preview, json=doc).json()["duplicate"]
    assert client.post(import_path, json=doc).json() == source
    entry, = client.get(f"/api/roles/{rid}/versions").raise_for_status().json()["versions"]
    assert (entry["version_number"], entry["created_by"], entry["rubric"]) == (1, "importer@example.test", RUBRIC)
    client.put("/api/roles/" + rid, json={**source, "rubric": list(reversed(RUBRIC))}).raise_for_status()
    assert client.post(import_path, json=doc).status_code == 409
    assert client.post(preview, json=doc).json()["conflict"]
    assert client.get("/api/roles/" + rid).json()["rubric"] == list(reversed(RUBRIC))
    file = tmp_path / "role.json"
    file.write_bytes(response.content)
    with pytest.raises(ValueError, match="different content"):
        migrate(file, target)


def test_duplicate_latest_role_is_independent_and_retry_safe(client):
    source = client.post("/api/roles", json=TEMPLATE).json()
    route = "/api/roles/" + source["id"]
    session = client.post("/api/sessions", json={"candidate": "Fixture", "role": source["name"],
                          "role_id": source["id"], "consent": True}).json()
    client.put(route, json={**source, "policy": "Updated policy", "rubric": RUBRIC}).raise_for_status()
    new_id = str(uuid4())
    copied = client.post(route + "/duplicate", json={"id": new_id}).raise_for_status().json()
    assert copied == {**source, "id": new_id, "policy": "Updated policy", "rubric": RUBRIC, "version": copied["version"]}
    assert client.post(route + "/duplicate", json={"id": new_id}).json() == copied
    assert client.post(route + "/duplicate", json={"id": source["id"]}).status_code == 409
    entry, = client.get(f"/api/roles/{new_id}/versions").json()["versions"]
    assert entry["version_number"] == 1 and entry["rubric"] == RUBRIC
    client.put("/api/roles/" + new_id, json={**copied, "questions": [], "rubric": []}).raise_for_status()
    assert client.get(route).json()["questions"] == TEMPLATE["questions"]
    assert client.get(route).json()["rubric"] == RUBRIC
    assert client.get("/api/sessions/" + session["id"]).json()["policy"] == TEMPLATE["policy"]
    assert len(client.get("/api/roles").json()) == 2


def test_v1_preserves_rubric_and_explicit_empty_v2_conflicts(client):
    role = {**TEMPLATE, "id": str(uuid4())}
    v1 = {"format": "interviewcheck.role-kit", "version": 1, "role": role}
    path = "/api/roles/import"
    assert "rubric_count" not in client.post(path + "/preview", json=v1).raise_for_status().json()
    imported = client.post(path, json=v1).raise_for_status().json()
    assert imported["rubric"] == []
    v2 = client.get(f"/api/roles/{role['id']}/export").raise_for_status().json()
    assert v2["version"] == 2 and v2["role"]["rubric"] == []
    client.put(f"/api/roles/{role['id']}", json={**imported, "rubric": RUBRIC}).raise_for_status()
    assert client.post(path + "/preview", json=v1).json()["duplicate"]
    assert client.post(path, json=v1).json()["rubric"] == RUBRIC
    assert client.post(path + "/preview", json=v2).json()["conflict"]
    assert client.post(path, json=v2).status_code == 409


def test_oversize_stored_rubric_file_is_rejected_without_truncation(client):
    text = "\x01" * 500
    rubric = [{**RUBRIC[0], "id": str(index), "expected_signals": [text] * 20, "red_flags": [text] * 20} for index in range(25)]
    # A workspace backup can restore valid roles larger than an individual role file.
    payload = RoleInput.model_validate({**TEMPLATE, "questions": ["\x01" * 4000] * 100, "rubric": rubric})
    with store.connection(write=True) as db:
        rid = store.create_role(db, payload)["id"]
    result = client.get(f"/api/roles/{rid}/export")
    assert result.status_code == 413 and "4 MiB" in result.json()["detail"]


def test_invalid_portable_files_and_unrepresentable_native_roles(client):
    role = {**TEMPLATE, "id": str(uuid4())}
    doc = {"format": "interviewcheck.role-kit", "version": 1, "role": role}
    v2 = {**doc, "version": 2, "role": {**role, "rubric": RUBRIC}}
    for invalid in ({**doc, "version": 2}, {**doc, "version": True}, {**doc, "extra": 1}, {**v2, "version": 1},
                    {**v2, "version": 3}, {**v2, "role": {**v2["role"], "version_number": 4}},
                    {**v2, "role": {**role, "rubric": [RUBRIC[0], RUBRIC[0]]}},
                    {**v2, "role": {**role, "rubric": [{"criterion": "Missing fields"}]}},
                    {**doc, "role": {**role, "id": None}}, {**doc, "role": {**role, "legacy": {}}},
                    {**doc, "role": {**role, "questions": ["?"] * 101}}):
        for path in ("/api/roles/import", "/api/roles/import/preview"):
            assert client.post(path, json=invalid).status_code == 422
    assert client.get("/api/roles").json() == []
    native = {"format": "interviewcheck.role", "version": 1, "role": {
        "workspaceID": "native-large", "name": "Large", "plannedQuestions": [{"text": "Q"}] * 101,
    }}
    native_id = client.post("/api/roles/import", json=native).raise_for_status().json()["id"]
    route = "/api/roles/" + native_id
    for result in (client.get(route + "/export"), client.post(route + "/duplicate", json={"id": str(uuid4())})):
        assert result.status_code == 422 and "Edit and save" in result.json()["detail"]
    assert len(client.get(route).json()["questions"]) == 101
