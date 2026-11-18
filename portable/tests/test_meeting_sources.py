from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock

import pytest
from fastapi.testclient import TestClient

from api import booking_sources, meeting_files
from api.main import app


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "workspace.sqlite"))
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_URL", raising=False)
    for key in booking_sources.KEYS.values():
        monkeypatch.setenv(key, "fixture")
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        yield client


@pytest.mark.parametrize(("provider", "responses", "candidate"), [
    ("calcom", [{"data": [{"status": "accepted", "title": "Panel", "start": "2030-01-01", "attendees": [{"name": "Sam"}]}]}], "Sam"),
    ("calendly", [{"resource": {"uri": "https://api.calendly.com/users/fixture"}},
                  {"collection": [{"uri": "https://api.calendly.com/scheduled_events/3caa0f6d-6935-4bf7-8463-fe7afdd676f8",
                                   "name": "Panel", "start_time": "2030-01-01"}]}], ""),
    ("zoom", [{"meetings": [{"topic": "Panel", "start_time": (datetime.now(timezone.utc) + timedelta(days=1)).isoformat()}]}], ""),
    ("webex", [{"items": [{"title": "Panel", "start": "2030-01-01"}]}], ""),
])
def test_booking_sources(client, monkeypatch, provider, responses, candidate):
    monkeypatch.setattr(booking_sources, "fetch_json", AsyncMock(side_effect=responses))
    row, = client.post("/api/integrations/calendar/sync/" + provider).json()["items"]
    assert row["title"] == "Panel" and row["candidate"] == candidate


def test_recording_can_be_selected_only_after_listing(client, monkeypatch):
    files = [{"id": "x", "download_url": "https://test.zoom.us/rec/download/a", "status": "completed", "file_type": kind}
             for kind in ["M4A", "TRANSCRIPT"]]
    fetch = AsyncMock(return_value={"meetings": [{"topic": "Interview", "start_time": "2030-01-01", "recording_files": files}]})
    monkeypatch.setattr(meeting_files, "fetch_json", fetch)
    items = client.post("/api/integrations/recordings/zoom").json()["items"]
    assert "download_url" not in str(items) and "zoom.us" not in str(items)
    prefix = "/api/integrations/recording/"
    assert client.post(prefix + items[0]["id"], json={}).status_code == 400
    monkeypatch.setenv("DEEPGRAM_API_KEY", "fixture")
    download = AsyncMock(return_value=(b"sample", "audio/mp4"))
    transcribe = AsyncMock(return_value={"segments": [{"speaker": "0", "text": "Hello"}]})
    monkeypatch.setattr(meeting_files, "download", download)
    monkeypatch.setattr(meeting_files, "transcribe_bytes", transcribe)
    response = client.post(prefix + items[0]["id"], json={"send_to_deepgram": True})
    assert response.json()["segments"][0]["text"] == "Hello"
    download.return_value = (b"WEBVTT\n", "text/vtt")
    assert client.post(prefix + items[1]["id"], json={}).json()["vtt"] == "WEBVTT\n"
    assert transcribe.await_count == 1
    assert client.post(prefix + "3caa0f6d-6935-4bf7-8463-fe7afdd676f8", json={}).status_code == 410


def test_webex_lists_media_and_transcripts(client, monkeypatch):
    transcript = {"meetingTopic": "Interview", "startTime": "2026-11-19", "id": "transcript"}
    media = {"topic": "Interview", "timeRecorded": "2026-11-19", "id": "recording"}
    fetch = AsyncMock(side_effect=[{"items": [transcript]}, {"items": [media]}])
    monkeypatch.setattr(meeting_files, "fetch_json", fetch)
    items = client.post("/api/integrations/recordings/webex").json()["items"]
    assert {item["kind"] for item in items} == {"transcript", "recording"}


@pytest.mark.parametrize("url", ["https://zoom.us.other.invalid/rec/x", "http://zoom.us/rec/x",
                                 "https://127.0.0.1/rec/x", "https://user@example.zoom.us:1234/rec/x"])
def test_reject_foreign_recording_address(url):
    with pytest.raises(meeting_files.HTTPException):
        meeting_files.vendor_url(url, "zoom")
