"""A recording excerpt can only be applied to the currently selected voice and turn."""
from unittest.mock import AsyncMock

import httpx
import pytest
from playwright.sync_api import expect

from api import audio, meeting_files


TURNS = [
    {"speaker": "Host", "text": "What did you measure?"},
    {"speaker": "Guest", "text": "I measured the receiver drift."},
    {"speaker": "Host", "text": "Which capture was used?"},
    {"speaker": "Guest", "text": "I repeated the cold capture."},
]


@pytest.mark.parametrize("origin", ["upload", "synced"])
def test_recording_voice_turn_and_edits_remain_bound(workspace_url, browser_page, monkeypatch, origin):
    if origin == "upload":
        monkeypatch.setenv("DEEPGRAM_API_KEY", "synthetic")
        monkeypatch.setattr(audio, "transcribe_bytes", AsyncMock(return_value={"segments": TURNS}))
    else:
        monkeypatch.setenv("ZOOM_ACCESS_TOKEN", "synthetic")
        listing = {"meetings": [{"topic": "Synthetic interview", "start_time": "2026-07-01T00:00:00Z",
            "recording_files": [{"recording_type": "audio_transcript", "file_type": "TRANSCRIPT",
                                 "download_url": "https://example.zoom.us/files/fake", "status": "completed"}]}]}
        vtt = "WEBVTT\n\n" + "\n\n".join(
            f"00:00:0{i}.000 --> 00:00:0{i+1}.000\n<v {row['speaker']}>{row['text']}" for i, row in enumerate(TURNS))
        monkeypatch.setattr(meeting_files, "fetch_json", AsyncMock(return_value=listing))
        monkeypatch.setattr(meeting_files, "download", AsyncMock(return_value=(vtt.encode(), "text/vtt")))

    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as api:
        session = api.post("/api/sessions", json={"candidate": "Fixture", "role": "Engineer",
                           "policy": "Public notes.", "consent": True}).json()
        page = browser_page
        page.goto(workspace_url + "/interviews/review/?id=" + session["id"])
        page.get_by_role("textbox", name="Question", exact=True).fill("Which capture was used?")
        page.get_by_text("Capture audio", exact=True).click()
        if origin == "upload":
            page.get_by_label("Participants agreed to send this audio to Deepgram.").check()
            page.get_by_label("Recorded audio or video").set_input_files({
                "name": "mock.wav", "mimeType": "audio/wav", "buffer": b"synthetic"})
            page.get_by_role("button", name="Send recording to Deepgram").click()
        else:
            page.get_by_role("button", name="List Zoom files").click()
            page.get_by_label("Recent recordings and transcripts").select_option(index=1)
            page.get_by_role("button", name="Import saved transcript").click()

        voice = page.get_by_role("combobox", name="Candidate voice")
        turn = page.get_by_role("combobox", name="Answer excerpt")
        text = page.get_by_role("textbox", name="Candidate excerpt")
        apply = page.get_by_role("button", name="Use this excerpt")
        voice.select_option("Host")
        turn.select_option("0")
        expect(text).to_have_value(TURNS[0]["text"])
        voice.select_option("Guest")
        expect(turn).to_have_value("")
        expect(text).to_have_value("")
        expect(apply).to_be_disabled()

        turn.select_option("0")
        turn.select_option("")
        expect(text).to_have_value("")
        expect(apply).to_be_disabled()
        turn.select_option("0")
        text.fill("Edited guest response.")
        page.once("dialog", lambda dialog: dialog.dismiss())
        voice.select_option("Host")
        expect(voice).to_have_value("Guest")
        expect(turn).to_have_value("0")
        expect(text).to_have_value("Edited guest response.")
        page.once("dialog", lambda dialog: dialog.accept())
        voice.select_option("")
        expect(voice).to_have_value("")
        expect(text).to_be_disabled()
        expect(apply).to_be_disabled()

        voice.select_option("Guest")
        turn.select_option("1")
        text.fill("I checked the cold capture twice.")
        apply.click()
        page.get_by_role("button", name="Save and compare").click()
        expect(page.get_by_role("button", name="Edit exchange")).to_be_visible()
        stored = api.get("/api/sessions/" + session["id"]).json()["answers"]
        assert [item["answer"] for item in stored] == ["I checked the cold capture twice."]
