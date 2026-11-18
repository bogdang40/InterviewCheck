import asyncio
import json
from unittest.mock import AsyncMock

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from api import access, ats, audio, calendar_sources, integrations
from api.main import app

P = "/api/integrations/"
EMAIL = "operator@example.invalid"
ICS = """BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//IC test//EN
BEGIN:VEVENT
UID:sample
DTSTART:20261119T163000Z
SUMMARY:Panel
X-INTERVIEWCHECK-CANDIDATE:Sam
X-INTERVIEWCHECK-ROLE:Engineer
END:VEVENT
END:VCALENDAR
"""


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "workspace.sqlite"))
    for key in ["INTERVIEWCHECK_ACCESS_URL", "DEEPGRAM_API_KEY", "OPENAI_API_KEY", "INTERVIEWCHECK_REFERENCE_MODEL",
                "INTERVIEWCHECK_OPERATOR_EMAIL", *[key for keys in ats.KEYS.values() for key in keys]]:
        monkeypatch.delenv(key, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        yield client


def test_local_file_sources(client):
    assert client.get(P + "status").json()["access"] is False
    response = client.post(P + "calendar/file", json={"text": ICS})
    assert response.json()["items"] == [{"title": "Panel", "start": "2026-11-19T16:30:00+00:00",
                                          "candidate": "Sam", "role": "Engineer"}]
    changed = ICS.replace("END:VCALENDAR", "BEGIN:VEVENT\nUID:sample\nSEQUENCE:1\nSTATUS:CANCELLED\nEND:VEVENT\nEND:VCALENDAR")
    assert client.post(P + "calendar/file", json={"text": changed}).json()["items"] == []
    with_series = ICS.replace("SUMMARY:", "RRULE:FREQ=WEEKLY\nSUMMARY:")
    assert "Recurring" in client.post(P + "calendar/file", json={"text": with_series}).json()["note"]
    assert client.post(P + "calendar/file", json={"text": "invalid"}).status_code == 422
    csv_result = client.post(P + "ats/file", json={"text": 'candidate,role\n"Sam, J.",Manager\n'})
    assert csv_result.json()["items"] == [{"candidate": "Sam, J.", "role": "Manager"}]
    assert client.post(P + "ats/file", json={"text": "a,b\n1,2"}).status_code == 422


def test_unconfigured_provider_does_not_upload(client, monkeypatch):
    fetch = AsyncMock()
    monkeypatch.setattr(audio, "fetch_json", fetch)
    assert client.post(P + "transcribe", content=b"audio", headers={"Content-Type": "audio/wav"}).status_code == 400
    headers = {"Content-Type": "audio/wav", "X-Send-Audio": "deepgram"}
    assert client.post(P + "transcribe", content=b"audio", headers=headers).status_code == 503
    fetch.assert_not_called()


def test_recording_diarization(client, monkeypatch):
    monkeypatch.setenv("DEEPGRAM_API_KEY", "fixture")
    response = {"results": {"utterances": [{"speaker": 0, "transcript": "Question?"}, {"speaker": 1, "transcript": "Answer."}]}}
    fetch = AsyncMock(return_value=response)
    monkeypatch.setattr(audio, "fetch_json", fetch)
    headers = {"Content-Type": "audio/wav", "X-Send-Audio": "deepgram"}
    result = client.post(P + "transcribe", content=b"fixture-bytes", headers=headers)
    assert result.json()["segments"] == [{"speaker": "0", "text": "Question?"}, {"speaker": "1", "text": "Answer."}]
    assert fetch.await_args.kwargs["content"] == b"fixture-bytes"
    fetch.return_value = {"results": {"channels": [{"alternatives": [{"transcript": ""}]}]}}
    assert client.post(P + "transcribe", content=b"x", headers=headers).status_code == 422


def test_reference_uses_only_the_question_and_role(client, monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "fixture")
    monkeypatch.setenv("INTERVIEWCHECK_REFERENCE_MODEL", "fixture-model")
    response = {"status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": "Reference."}]}]}
    fetch = AsyncMock(return_value=response)
    monkeypatch.setattr(integrations, "fetch_json", fetch)
    data = client.post(P + "reference", json={"role": "Engineer", "question": "Why?", "candidate": "Private Name"})
    assert data.json() == {"label": "OpenAI fixture-model", "text": "Reference."}
    payload = fetch.await_args.kwargs["json"]
    assert payload["store"] is False and "Why?" in payload["input"] and "Private" not in str(payload)


@pytest.mark.parametrize("provider", ["google", "microsoft"])
def test_calendar_accounts(client, monkeypatch, provider):
    monkeypatch.setenv("GOOGLE_CALENDAR_ACCESS_TOKEN", "fixture")
    monkeypatch.setenv("MS_GRAPH_ACCESS_TOKEN", "fixture")
    data = {"items": [{"summary": "Panel", "start": {"date": "2026-11-20"}}, {"status": "cancelled"}],
            "nextPageToken": "more"} if provider == "google" else {
            "value": [{"subject": "Panel", "start": {"dateTime": "2026-11-20T12:00:00"}}, {"isCancelled": True}],
            "@odata.nextLink": "more"}
    monkeypatch.setattr(calendar_sources, "fetch_json", AsyncMock(return_value=data))
    result = client.post(P + "calendar/sync/" + provider)
    assert len(result.json()["items"]) == 1 and result.json()["note"]


@pytest.mark.parametrize(("provider", "rows"), [
    ("ashby", [{"success": True, "results": [{"name": "Sam", "applicationIds": ["1"]}]},
               {"success": True, "results": {"job": {"title": "Engineer"}}}]),
    ("lever", [{"data": [{"name": "Sam", "emails": [EMAIL], "applications": [{"posting": "1"}]}]},
               {"data": {"text": "Engineer"}}]),
    ("merge", [{"results": [{"id": "1", "first_name": "Sam", "email_addresses": [{"value": EMAIL}]}]},
               {"results": [{"job": {"name": "Engineer"}}]}]),
    ("greenhouse", [{"access_token": "fixture"}, [{"id": "1", "first_name": "Sam"}],
                    [{"job_id": "job"}], [{"name": "Engineer"}]]),
])
def test_candidate_lookup(client, monkeypatch, provider, rows):
    for key in ats.KEYS[provider]:
        monkeypatch.setenv(key, "fixture")
    monkeypatch.setattr(ats, "fetch_json", AsyncMock(side_effect=rows))
    response = client.post(P + f"ats/{provider}/lookup", json={"email": EMAIL})
    assert response.json()["items"] == [{"candidate": "Sam", "role": "Engineer"}]


def test_account_entitlement_and_checkout(client, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "http://127.0.0.1:8787")
    monkeypatch.setenv("INTERVIEWCHECK_OPERATOR_EMAIL", EMAIL)
    active = {"user": {"email": EMAIL}, "entitlement": {"active": True}}
    fetch = AsyncMock(return_value={**active, "token": "fixture-session"})
    monkeypatch.setattr(access, "fetch_json", fetch)
    assert client.get("/api/sessions").status_code == 401
    assert client.post(P + "ats/file", json={"text": "candidate,role"}).status_code == 401
    login = client.post(P + "access/login", json={"email": EMAIL, "password": "fixture-pass"})
    assert login.status_code == 200 and "fixture-session" not in login.text
    assert "HttpOnly" in login.headers["set-cookie"]
    assert client.get("/api/sessions").status_code == 200
    fetch.return_value = {"user": {"email": EMAIL}, "entitlement": {"active": False}}
    assert client.get("/api/sessions").status_code == 402
    fetch.side_effect = [active, {"url": "https://checkout.stripe.com/c/pay/fixture"}]
    assert client.post(P + "billing/checkout", json={"plan": "annual"}).json()["url"].startswith("https://checkout.stripe.com/")
    fetch.side_effect = None
    fetch.return_value = {"user": {"email": "other@example.invalid"}, "entitlement": {"active": True}}
    assert client.get("/api/sessions").status_code == 403
    fetch.return_value = {}
    assert client.post(P + "logout").status_code == 200
    assert client.get("/api/sessions").status_code == 401


def test_wrong_browser_origin_blocks_socket(client):
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect("ws://127.0.0.1/api/integrations/live", headers={"Origin": "http://unrelated.invalid"}):
            pass


def test_live_audio_relay_flushes_final_words(client, monkeypatch):
    monkeypatch.setenv("DEEPGRAM_API_KEY", "fixture")
    sent = []

    class Provider:
        async def __aenter__(self):
            self.queue = asyncio.Queue()
            return self

        async def __aexit__(self, *args):
            pass

        async def send(self, data):
            sent.append(data)
            if data == '{"type":"CloseStream"}':
                await self.queue.put(json.dumps({"type": "Results", "is_final": True, "channel": {"alternatives": [{"transcript": "Final answer."}]}}))
                await self.queue.put(None)

        async def __aiter__(self):
            while (message := await self.queue.get()) is not None:
                yield message

    monkeypatch.setattr(audio, "connect", lambda *args, **kwargs: Provider())
    with client.websocket_connect("ws://127.0.0.1/api/integrations/live", headers={"Origin": "http://127.0.0.1"}) as ws:
        ws.send_text("send-audio-to-deepgram")
        assert ws.receive_json()["ready"] is True
        ws.send_bytes(b"sample audio")
        ws.send_text("finish")
        assert ws.receive_json() == {"text": "Final answer."}
    assert sent == [b"sample audio", '{"type":"CloseStream"}']
