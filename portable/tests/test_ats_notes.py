"""Delivery tests use synthetic records and mocked provider calls only."""
from unittest.mock import AsyncMock
from uuid import uuid4

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest

from api.main import app
from api import ats_notes

NOTE = "Candidate explained recovery behavior."
SESSION = {"candidate": "Sample", "role": "SRE", "policy": "Notes allowed", "consent": True}
TARGET = {"email": "fake@example.test", "provider": "lever", "target_id": str(uuid4())}


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "database"))
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_URL", raising=False)
    monkeypatch.setenv("LEVER_API_KEY", "fixture")
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def prepare(web, monkeypatch):
    lookup = AsyncMock(return_value=[{"candidate": "Sample", "role": "SRE", "target_id": TARGET["target_id"]}])
    monkeypatch.setattr(ats_notes.ats, "lookup", lookup)
    path = "/api/sessions/" + web.post("/api/sessions", json=SESSION).json()["id"] + "/ats"
    rows = web.post(path + "/recipients", json={k: v for k, v in TARGET.items() if k != "target_id"}).json()
    assert rows[0]["target_id"] == TARGET["target_id"]
    draft = web.post(path + "/drafts", json=TARGET)
    draft.raise_for_status()
    assert draft.json()["state"] == "draft" and draft.json()["recipient"] == "Sample"
    return path, draft.json()["id"]


def test_operator_confirm_and_retry_receipt(client, monkeypatch):
    post = AsyncMock()
    monkeypatch.setattr(ats_notes, "send_private", post)
    path, key = prepare(client, monkeypatch)
    post.assert_not_called()
    endpoint = path + "/drafts/" + key + "/send"
    assert client.post(endpoint, json={"confirmed": False, "note": NOTE}).status_code == 422
    post.assert_not_called()
    for _ in range(2):
        saved = client.post(endpoint, json={"confirmed": True, "note": NOTE})
        saved.raise_for_status()
        assert saved.json()["draft"] == NOTE
    post.assert_awaited_once_with("lever", TARGET["target_id"], NOTE)
    assert client.get(path).json()["history"][0]["state"] == "sent"
    assert client.post(endpoint, json={"confirmed": True, "note": "Different"}).status_code == 409


def test_unconfirmed_delivery_cannot_repeat(client, monkeypatch):
    post = AsyncMock(side_effect=HTTPException(504, "Timeout"))
    monkeypatch.setattr(ats_notes, "send_private", post)
    path, key = prepare(client, monkeypatch)
    endpoint = path + "/drafts/" + key + "/send"
    assert client.post(endpoint, json={"confirmed": True, "note": NOTE}).status_code == 504
    assert client.post(endpoint, json={"confirmed": True, "note": NOTE}).status_code == 409
    assert client.get(path).json()["history"][0]["state"] == "attempted"
    post.assert_awaited_once()


@pytest.mark.parametrize(("provider", "flag", "value"), [
    ("ashby", "isPrivate", True), ("lever", "secret", True), ("merge", "visibility", "PRIVATE"),
    ("greenhouse", "visibility", "private")])
def test_provider_requests_set_private_visibility(monkeypatch, provider, flag, value):
    import asyncio

    for key in (*ats_notes.ats.KEYS[provider], "MERGE_REMOTE_USER_ID"):
        monkeypatch.setenv(key, "fixture")
    responses = {
        "greenhouse": [{"access_token": "fake-access"}, {}],
        "merge": [{"request_schema": {"properties": {"model": {"properties": {"visibility": {"enum": ["PRIVATE"]}}}}}},
                  {"model": {"visibility": "PRIVATE"}}],
    }
    calls = AsyncMock(side_effect=responses.get(provider, [{"success": True}]))
    monkeypatch.setattr(ats_notes, "fetch_json", calls)
    asyncio.run(ats_notes.send_private(provider, "456", NOTE))
    last = calls.await_args.kwargs["json"]
    payload = last["model"] if provider == "merge" else last
    assert payload[flag] == value
    assert NOTE in str(payload)
    if provider == "ashby":
        assert last["sendNotifications"] is False
    if provider == "lever":
        assert last["notifyFollowers"] is False


def test_mention_cannot_expand_private_lever_audience(client, monkeypatch):
    post = AsyncMock()
    monkeypatch.setattr(ats_notes, "send_private", post)
    path, key = prepare(client, monkeypatch)
    response = client.post(path + "/drafts/" + key + "/send", json={"confirmed": True, "note": "Ask @someone about this."})
    assert response.status_code == 422
    assert client.get(path).json()["history"][0]["state"] == "draft"
    post.assert_not_called()


def test_merge_without_visibility_support_sends_nothing(monkeypatch):
    import asyncio
    for key in (*ats_notes.ats.KEYS["merge"], "MERGE_REMOTE_USER_ID"):
        monkeypatch.setenv(key, "fixture")
    call = AsyncMock(return_value={"request_schema": {"properties": {"model": {"properties": {}}}}})
    monkeypatch.setattr(ats_notes, "fetch_json", call)
    with pytest.raises(HTTPException):
        asyncio.run(ats_notes.send_private("merge", "123", NOTE))
    assert call.await_count == 1 and call.await_args.args[1] == "GET"


@pytest.mark.parametrize("provider", ["workable", "recruitee"])
def test_tenant_scoped_private_notes(monkeypatch, provider):
    import asyncio
    for name in (*ats_notes.ats.KEYS[provider], "WORKABLE_MEMBER_ID"):
        monkeypatch.setenv(name, "example")
    fetch = AsyncMock(side_effect=[{"admin": {"id": 1}}, {}] if provider == "recruitee" else [{}])
    monkeypatch.setattr(ats_notes, "fetch_json", fetch)
    asyncio.run(ats_notes.send_private(provider, "134", NOTE))
    data = fetch.await_args.kwargs["json"]
    if provider == "workable":
        assert data["comment"]["policy"] == ["admin"]
    else:
        assert data["note"]["visibility"] == {"level": "protected", "admin_ids": [1], "role_ids": []}
