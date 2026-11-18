from unittest.mock import AsyncMock

import pytest
from fastapi.testclient import TestClient

from api import calendar_sources, meeting_artifacts as cloud, meeting_files, oauth_tokens
from api.main import app

P = "/api/integrations/"
REC = "conferenceRecords/unit"
TRANSCRIPT = REC + "/transcripts/fixture"


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "workspace.sqlite"))
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_URL", raising=False)
    monkeypatch.delenv("GOOGLE_REFRESH_TOKEN", raising=False)
    monkeypatch.delenv("MS_GRAPH_REFRESH_TOKEN", raising=False)
    monkeypatch.setenv("GOOGLE_MEET_ACCESS_TOKEN", "fixture")
    monkeypatch.setenv("TEAMS_ACCESS_TOKEN", "fixture")
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        yield client


def test_google_meet_selected_conference_to_speaker_turns(client, monkeypatch):
    fetch = AsyncMock(side_effect=[
        {"conferenceRecords": [{"name": REC, "startTime": "2026-11-18T15:00:00Z", "endTime": "2026-11-18T16:00:00Z"}]},
        {"transcripts": [{"name": TRANSCRIPT, "state": "FILE_GENERATED"}]},
        {"participants": [{"name": "p1", "signedinUser": {"displayName": "Sam"}}]},
        {"transcriptEntries": [{"participant": "p2", "text": "Answer", "startTime": "2026-11-18T15:02:00Z"}], "nextPageToken": "more"},
        {"transcriptEntries": [{"participant": "p1", "text": "Question?", "startTime": "2026-11-18T15:01:00Z"}]},
    ])
    monkeypatch.setattr(cloud, "fetch_json", fetch)
    meet = client.post(P + "recordings/meet").json()["items"][0]
    file = client.post(P + "recording/" + meet["id"], json={}).json()["items"][0]
    response = client.post(P + "recording/" + file["id"], json={})
    assert response.json()["segments"] == [{"speaker": "Sam (1)", "text": "Question?"}, {"speaker": "Speaker 2", "text": "Answer"}]
    assert fetch.await_args.kwargs["params"]["pageToken"] == "more"


def test_only_selected_teams_occurrence_is_returned(client, monkeypatch):
    fetch = AsyncMock(side_effect=[
        {"value": [{"subject": "Panel", "onlineMeetingProvider": "teamsForBusiness", "onlineMeeting": {"joinUrl": "https://teams.microsoft.com/meeting"},
                    "start": {"dateTime": "2026-11-15T15:00:00"}, "end": {"dateTime": "2026-11-15T16:00:00"}}]},
        {"value": [{"id": "selected"}]},
        {"value": [{"id": "t1", "createdDateTime": "2026-11-15T16:01:00Z"}, {"id": "prior", "createdDateTime": "2026-11-08T16:01:00Z"}]},
        {"value": [{"id": "r1", "createdDateTime": "2026-11-15T16:03:00Z"}]},
    ])
    monkeypatch.setattr(cloud, "fetch_json", fetch)
    meeting = client.post(P + "recordings/teams").json()["items"][0]
    files = client.post(P + "recording/" + meeting["id"], json={}).json()["items"]
    assert [file["kind"] for file in files] == ["transcript", "video"]
    download = AsyncMock(return_value=(b"WEBVTT\n", "text/vtt"))
    monkeypatch.setattr(meeting_files, "download", download)
    assert client.post(P + "recording/" + files[0]["id"], json={}).json() == {"vtt": "WEBVTT\n"}
    assert download.await_args.args[0].location.endswith("/transcripts/t1/content?$format=text/vtt")


@pytest.mark.parametrize(("provider","prefix"), [("google","GOOGLE"), ("microsoft","MS_GRAPH")])
def test_provider_tokens_refresh_and_rotate(client, monkeypatch, provider, prefix):
    monkeypatch.setenv(prefix + "_CLIENT_ID", "fixture-id")
    monkeypatch.setenv(prefix + "_REFRESH_TOKEN", "fixture-original")
    token_fetch = AsyncMock(side_effect=[{"access_token": "access1", "refresh_token": "rotated", "expires_in": 20},
                                         {"access_token": "access2", "expires_in": 3600}])
    monkeypatch.setattr(oauth_tokens, "fetch_json", token_fetch)
    get = AsyncMock(return_value={"items": [], "value": []})
    monkeypatch.setattr(calendar_sources, "fetch_json", get)
    for _ in range(3):
        assert client.post(P + "calendar/sync/" + provider).status_code == 200
    assert token_fetch.await_count == 2
    assert token_fetch.await_args.kwargs["data"]["refresh_token"] == "rotated"
    assert get.await_args.kwargs["headers"]["Authorization"] == "Bearer access2"
