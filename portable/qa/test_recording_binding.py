"""A file picked for one transcript cannot follow the reviewer into another."""

import io
import wave
from uuid import uuid4

import httpx
from playwright.sync_api import expect


def wav(seconds):
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as media:
        media.setnchannels(1)
        media.setsampwidth(2)
        media.setframerate(8000)
        media.writeframes(bytes(16000 * seconds))
    return buffer.getvalue()


def test_recording_is_local_and_bound_to_transcript(workspace_url, browser_page):
    page = browser_page
    page.set_viewport_size({"width": 390, "height": 844})
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        response = client.post(
            "/api/sessions",
            json={
                "candidate": "Audio fixture",
                "role": "Engineer",
                "policy": "Manual allowed.",
                "consent": True,
            },
        )
        response.raise_for_status()
        key = response.json()["id"]
        ids = []
        for index, source in enumerate(("a" * 64, "b" * 64)):
            imported = client.post(
                f"/api/sessions/{key}/imports/webvtt",
                json={
                    "request_id": str(uuid4()),
                    "transcript_sha256": source,
                    "candidate_speaker": "Guest",
                    "interviewer_speakers": ["Host"],
                    "exchanges": [
                        {
                            "ordinal": 1,
                            "first_cue": 1,
                            "last_cue": 2,
                            "start_ms": 200,
                            "end_ms": 1800,
                            "question": f"Question {index}?",
                            "answer": "The answer.",
                        }
                    ],
                },
            )
            imported.raise_for_status()
            ids.extend(imported.json()["answer_ids"])
        page.goto(workspace_url + f"/interviews/review/?id={key}&answer={ids[0]}")
        panel = page.get_by_text("Local recording playback", exact=True).locator("..")
        panel.locator("summary").click()
        upload = panel.get_by_label("Corresponding local recording")
        # A short valid file and a file with unreadable bytes must both fail closed.
        requests = []
        page.on("request", lambda request: requests.append(request) if request.method != "GET" else None)
        upload.set_input_files({"name": "short.wav", "mimeType": "audio/wav", "buffer": wav(1)})
        expect(panel.get_by_role("alert").filter(has_text="beyond")).to_be_visible()
        expect(panel.get_by_role("button", name="Play excerpt")).to_be_disabled()
        panel.get_by_role("button", name="Remove recording").click()
        upload.set_input_files(
            {"name": "unsupported.wav", "mimeType": "audio/wav", "buffer": b"not a sound file"}
        )
        expect(panel.get_by_role("alert").filter(has_text="codec")).to_be_visible()
        panel.get_by_role("button", name="Remove recording").click()
        upload.set_input_files({"name": "recording.wav", "mimeType": "audio/wav", "buffer": wav(3)})
        play = panel.get_by_role("button", name="Play excerpt")
        expect(play).to_be_enabled()
        assert panel.locator("audio").evaluate("audio => audio.paused && audio.src.startsWith('blob:')")
        play.click()
        expect(panel.get_by_role("button", name="Pause excerpt")).to_be_visible()
        page.get_by_label("Selected question").select_option(ids[1])
        expect(panel.get_by_role("button", name="Remove recording")).to_have_count(0)
        expect(panel.locator("audio")).to_have_count(0)
        page.get_by_label("Selected question").select_option(ids[0])
        expect(panel.locator("audio")).to_have_count(0)
        assert requests == []
