"""Record a synthetic microphone and return a scripted transcript over the browser socket."""
import json
import re

import httpx
import pytest
from playwright.sync_api import expect


@pytest.mark.parametrize("audio_source", ["microphone", "call"])
def test_live_audio_transcript_requires_transfer_and_application(workspace_url, browser_page, audio_source):
    form = {"candidate": "Audio fixture", "role": "Engineer", "policy": "Notes allowed.", "consent": True}
    response = httpx.post(workspace_url + "/api/sessions", headers={"X-InterviewCheck": "1"}, json=form)
    response.raise_for_status()
    page = browser_page
    if audio_source == "call":
        # The native OS surface picker cannot be driven in CI. Exercise the
        # selected stream boundary with actual synthetic video and audio tracks.
        page.add_init_script("""
            navigator.mediaDevices.getDisplayMedia = async () => {
                const stream = await navigator.mediaDevices.getUserMedia({video: true, audio: true});
                window.testDisplayTracks = stream.getTracks();
                return stream;
            };
            window.capturedTrackKinds = [];
            window.MediaRecorder = class extends MediaRecorder {
                constructor(stream, ...args) {
                    super(stream, ...args);
                    window.capturedTrackKinds = stream.getTracks().map(track => track.kind);
                }
            };
        """)
    page.route("**/api/integrations/status", lambda route: route.fulfill(json={
        "transcription": True, "reference": False, "access": False, "ats": [], "calendars": [], "meetings": [],
    }))
    packets = []
    tail = "Final words after stop."
    transcript = "This microphone contains only generated audio."

    def mock_stream(socket):
        def packet(value):
            if value == "send-audio-to-deepgram":
                socket.send(json.dumps({"ready": True}))
            elif isinstance(value, bytes):
                if not packets and value:
                    socket.send(json.dumps({"text": transcript}))
                packets.append(len(value))
            elif value == "finish":
                socket.send(json.dumps({"text": tail}))
                socket.close(code=1000)
        socket.on_message(packet)

    page.route_web_socket("**/api/integrations/live", mock_stream)
    page.goto(workspace_url + "/#session/" + response.json()["id"])
    page.get_by_role("textbox", name="Question", exact=True).fill("What was measured?")
    page.get_by_role("textbox", name="Candidate answer").fill("First pass.")
    save = page.get_by_role("button", name="Save and compare")
    page.get_by_text("Capture audio", exact=True).click()
    start = page.get_by_role("button", name="Start transcription")
    expect(start).to_be_disabled()
    page.get_by_role("checkbox", name=re.compile("agreed to send")).check()
    page.get_by_label("Audio source").select_option(audio_source)
    start.click()
    expect(page.get_by_label("Candidate excerpt")).to_have_value(transcript)
    assert packets and all(packets)
    expect(save).to_be_disabled()
    if audio_source == "call":
        assert page.evaluate("window.capturedTrackKinds") == ["audio"]
    if audio_source == "call":
        # The surface can end its video and audio tracks in the same task.
        page.evaluate("""() => {for (const track of window.testDisplayTracks) {
            track.stop(); track.dispatchEvent(new Event("ended"));
        }}""")
    else:
        page.get_by_role("button", name="Stop capture").click()
    expect(page.get_by_label("Candidate excerpt")).to_have_value(transcript + " " + tail)
    expect(save).to_be_disabled()
    page.get_by_role("button", name="Use this excerpt").click()
    expect(save).to_be_enabled()
    expect(page.get_by_role("textbox", name="Candidate answer")).to_have_value("First pass. " + transcript + " " + tail)
