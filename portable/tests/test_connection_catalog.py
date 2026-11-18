from unittest.mock import AsyncMock

import pytest
from fastapi.testclient import TestClient

from api import access, ats, ats_notes, authoring, booking_sources, mailbox, oauth_tokens
from api.main import app

URL = "/api/integrations/catalog"


@pytest.fixture
def client(tmp_path, monkeypatch):
    settings = {
        key
        for keys in (*ats.KEYS.values(), *ats_notes.NOTE_KEYS.values(), *authoring.MODEL_KEYS.values())
        for key in keys
    }
    settings.update(oauth_tokens.TOKEN.values())
    settings.update(
        f"{prefix}_{suffix}"
        for prefix in oauth_tokens.GROUP.values()
        for suffix in ("CLIENT_ID", "REFRESH_TOKEN", "CLIENT_SECRET")
    )
    settings.update(booking_sources.KEYS.values())
    settings.update(mailbox.SETTINGS)
    settings.update(
        [
            "INTERVIEWCHECK_OPERATOR_EMAIL",
            "INTERVIEWCHECK_ACCESS_URL",
            "INTERVIEWCHECK_ACCESS_MODE",
            "INTERVIEWCHECK_PUBLIC_ORIGIN",
            "DEEPGRAM_API_KEY",
            "STRIPE_SECRET_KEY",
            "STRIPE_WEBHOOK_SECRET",
            "STRIPE_PRICE_MONTHLY",
            "STRIPE_PRICE_ANNUAL",
        ]
    )
    for key in settings:
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "catalog.sqlite"))
    with TestClient(app, base_url="http://127.0.0.1") as client:
        yield client


def providers(client):
    response = client.get(URL)
    response.raise_for_status()
    return {provider["id"]: provider["operations"] for provider in response.json()["providers"]}


def test_registry_matches_implemented_operations_and_local_files(client):
    info = providers(client)
    assert set(ats.KEYS) == {
        key
        for key, ops in info.items()
        if key != "files" and any(o["task"] == "Candidate lookup" for o in ops)
    }
    assert set(ats_notes.NOTE_KEYS) == {
        key for key, ops in info.items() if any(o["task"] == "Private notes" for o in ops)
    }
    assert all(op["state"] == "local" and not op["alternatives"] for op in info["files"])
    assert all(op["state"] == "needs_setup" for key, ops in info.items() if key != "files" for op in ops)
    assert {o["task"] for o in info["azure_openai"]} == {"References", "Question planning"}


def test_partial_settings_oauth_and_no_vendor_calls(client, monkeypatch):
    transport = AsyncMock(side_effect=AssertionError("Catalog contacted a remote provider"))
    monkeypatch.setattr("httpx.AsyncClient.send", transport)
    for key in (
        "WORKABLE_API_KEY",
        "WORKABLE_SUBDOMAIN",
        "GOOGLE_CLIENT_ID",
        "GOOGLE_REFRESH_TOKEN",
        "ZOOM_ACCESS_TOKEN",
        "ANTHROPIC_API_KEY",
        "INTERVIEWCHECK_ANTHROPIC_MODEL",
        "IMAP_USERNAME",
        "IMAP_FOLDER",
    ):
        monkeypatch.setenv(key, "SensitiveRuntimeMarker")
    info = providers(client)
    assert [op["state"] for op in info["workable"]] == ["configured", "needs_setup"]
    assert info["google"][0]["state"] == info["meet"][0]["state"] == "configured"
    assert [op["state"] for op in info["zoom"]] == ["configured", "configured", "needs_setup"]
    assert all(op["state"] == "configured" for op in info["anthropic"])
    assert info["imap"][0]["state"] == "needs_setup"
    response = client.get(URL)
    assert "SensitiveRuntimeMarker" not in response.text and "IMAP_USERNAME" in response.text
    monkeypatch.setenv("WORKABLE_MEMBER_ID", "SensitiveRuntimeMarker")
    monkeypatch.setenv("DEEPGRAM_API_KEY", "SensitiveRuntimeMarker")
    assert providers(client)["workable"][1]["state"] == "configured"
    assert providers(client)["zoom"][2]["state"] == "configured"
    transport.assert_not_called()


def test_catalog_auth_and_billing_source_distinction(client, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "https://account-fixture.invalid")
    monkeypatch.setenv("INTERVIEWCHECK_OPERATOR_EMAIL", "sensitive-operator@example.invalid")
    assert client.get(URL).status_code == 401
    # A local, simulated authenticated operator. Do not call the account service.
    monkeypatch.setitem(app.dependency_overrides, access.require_entitlement, lambda: None)
    response = client.get(URL)
    assert "sensitive-operator" not in response.text and "account-fixture.invalid" not in response.text
    assert all(op["state"] == "remote" for op in providers(client)["stripe"])
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_URL")
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    for key in ("STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET", "STRIPE_PRICE_MONTHLY"):
        monkeypatch.setenv(key, "secret-fixture-never-expose")
    info = providers(client)
    assert [op["state"] for op in info["accounts"]] == ["configured", "needs_setup"]
    assert [op["state"] for op in info["stripe"]] == ["configured", "needs_setup", "configured"]
    assert "secret-fixture-never-expose" not in client.get(URL).text
