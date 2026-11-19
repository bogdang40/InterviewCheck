from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import store
from api.main import app
from api.migrate import migrate

TEMPLATE = {
    "name": "Ingénieur", "description": "Équipe Ω", "questions": ["Why?\nExplain.", "Why?\nExplain."],
    "policy": "Le manuel est permis.", "permitted_sources": [{"label": "Manual", "text": "Mesure Δ."}],
}
HEADERS = {"X-InterviewCheck": "1"}


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "source.sqlite"))
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers=HEADERS) as web:
        yield web


def test_file_roundtrip_privacy_and_conflict_after_preview(client, tmp_path, monkeypatch):
    source = client.post("/api/roles", json=TEMPLATE).raise_for_status().json()
    rid = source["id"]
    client.post("/api/sessions", json={"candidate": "PRIVATE-CANDIDATE", "role": source["name"],
                "role_id": rid, "consent": True}).raise_for_status()
    with store.connection(write=True) as db:
        db.execute("UPDATE roles SET legacy=? WHERE id=?", ('{"notes":"PRIVATE-NATIVE"}', rid))
    response = client.get(f"/api/roles/{rid}/export").raise_for_status()
    assert response.headers["content-disposition"] == f'attachment; filename="role-{rid}.json"'
    assert response.headers["cache-control"] == "no-store"
    doc = response.json()
    assert doc == {"format": "interviewcheck.role-kit", "version": 1, "role": {"id": rid, **TEMPLATE}}
    assert "PRIVATE-" not in response.text

    target = tmp_path / "destination.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
    import_path = "/api/roles/import"
    preview = import_path + "/preview"
    assert not client.post(preview, json=doc).json()["duplicate"]
    assert client.get("/api/roles").json() == []
    assert client.post(import_path, json=doc).json() == source
    assert client.post(preview, json=doc).json()["duplicate"]
    assert client.post(import_path, json=doc).json() == source
    client.put("/api/roles/" + rid, json={**source, "name": "Changed"}).raise_for_status()
    assert client.post(import_path, json=doc).status_code == 409
    assert client.post(preview, json=doc).json()["conflict"]
    assert [r["name"] for r in client.get("/api/roles").json()] == ["Changed"]
    file = tmp_path / "role.json"
    file.write_bytes(response.content)
    with pytest.raises(ValueError, match="different content"):
        migrate(file, target)


def test_duplicate_latest_role_is_independent_and_retry_safe(client):
    source = client.post("/api/roles", json=TEMPLATE).json()
    route = "/api/roles/" + source["id"]
    session = client.post("/api/sessions", json={"candidate": "Fixture", "role": source["name"],
                          "role_id": source["id"], "consent": True}).json()
    client.put(route, json={**source, "policy": "Updated policy"}).raise_for_status()
    new_id = str(uuid4())
    copied = client.post(route + "/duplicate", json={"id": new_id}).raise_for_status().json()
    assert copied == {**source, "id": new_id, "policy": "Updated policy", "version": copied["version"]}
    assert client.post(route + "/duplicate", json={"id": new_id}).json() == copied
    assert client.post(route + "/duplicate", json={"id": source["id"]}).status_code == 409
    client.put("/api/roles/" + new_id, json={**copied, "questions": []}).raise_for_status()
    assert client.get(route).json()["questions"] == TEMPLATE["questions"]
    assert client.get("/api/sessions/" + session["id"]).json()["policy"] == TEMPLATE["policy"]
    assert len(client.get("/api/roles").json()) == 2


def test_invalid_portable_files_and_unrepresentable_native_roles(client):
    role = {**TEMPLATE, "id": str(uuid4())}
    doc = {"format": "interviewcheck.role-kit", "version": 1, "role": role}
    for invalid in ({**doc, "version": 2}, {**doc, "version": True}, {**doc, "extra": 1},
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
