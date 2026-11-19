"""Exercise the browser media engine with a short PCM recording and no media service."""

import io
import re
import wave
from uuid import uuid4

import httpx
from playwright.sync_api import expect


def synthetic_wav(seconds=4):
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as stream:
        stream.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        stream.writeframes(b"\x00\x00" * (16000 * seconds))
    return buffer.getvalue()


def seed(base):
    with httpx.Client(base_url=base, headers={"X-InterviewCheck": "1"}) as client:
        session = client.post(
            "/api/sessions",
            json={
                "candidate": "Audio fixture",
                "role": "Engineer",
                "policy": "Review the excerpt.",
                "consent": True,
            },
        )
        session.raise_for_status()
        sid = session.json()["id"]
        intervals = [("First prompt", 200, 2100), ("Second prompt", 2400, 2920), ("Long prompt", 3600, 5300)]
        rows = [
            {"ordinal": i + 1, "question": q, "answer": "Fixture answer", "start_ms": start, "end_ms": end}
            for i, (q, start, end) in enumerate(intervals)
        ]
        result = client.post(
            f"/api/sessions/{sid}/imports/webvtt",
            json={
                "request_id": str(uuid4()),
                "transcript_sha256": "d" * 64,
                "candidate_speaker": "Fixture speaker",
                "interviewer_speakers": ["Host"],
                "exchanges": rows,
            },
        )
        result.raise_for_status()
        return sid, result.json()["answer_ids"]


def test_local_media_play_pause_cleanup_and_duration(workspace_url, browser_page):
    page = browser_page
    sid, ids = seed(workspace_url)
    page.goto(f"{workspace_url}/interviews/review/?id={sid}&answer={ids[0]}")
    page.get_by_text("Local recording playback", exact=True).click()
    expect(page.get_by_text("Exchange interval 00:00.200 to 00:02.100")).to_be_visible()
    # Inspect only the object URL lifecycle: browser decoding and seeking stay real.
    page.evaluate("""() => {
        window.releasedTestMedia = [];
        const revoke = URL.revokeObjectURL.bind(URL);
        URL.revokeObjectURL = url => { window.releasedTestMedia.push(url); revoke(url); };
    }""")
    writes = []
    page.on("request", lambda r: writes.append(r.url) if r.method in ("POST", "PUT", "PATCH") else None)
    page.get_by_label("Corresponding local recording").set_input_files(
        {"name": "local-fixture.wav", "mimeType": "audio/wav", "buffer": synthetic_wav()}
    )
    media = page.locator("audio[aria-label='Selected local audio']")
    play = page.get_by_role("button", name="Play excerpt", exact=True)
    expect(play).to_be_enabled()
    url = media.evaluate("m => m.src")
    assert url.startswith("blob:") and media.evaluate(
        "m => m.paused && m.currentTime === 0 && m.duration === 4"
    )
    play.click()
    page.wait_for_function("""() => document.querySelector("audio").currentTime > 0.35""")
    page.get_by_role("button", name="Pause excerpt").click()
    assert media.evaluate("m => m.paused && m.currentTime >= .2 && m.currentTime < 2.1")
    page.get_by_role("button", name="Resume excerpt").click()
    page.get_by_role("navigation", name="Interview questions").get_by_role(
        "button", name=re.compile("Second prompt")
    ).click()
    expect(page.get_by_text("Exchange interval 00:02.400 to 00:02.920")).to_be_visible()
    assert media.evaluate("m => m.paused && m.src") == url
    play.click()
    expect(page.get_by_text("End of exchange", exact=True)).to_be_visible(timeout=5000)
    assert media.evaluate("m => m.paused && Math.abs(m.currentTime - 2.92) < .025")
    page.get_by_role("navigation", name="Interview questions").get_by_role(
        "button", name=re.compile("Long prompt")
    ).click()
    expect(page.get_by_text("The transcript interval extends beyond this recording.")).to_be_visible()
    expect(play).to_be_disabled()
    page.get_by_role("button", name="Remove recording").click()
    expect(media).to_have_count(0)
    assert page.evaluate("url => window.releasedTestMedia.includes(url)", url)
    assert not writes


def test_unreadable_recording_can_be_removed(workspace_url, browser_page):
    page = browser_page
    sid, ids = seed(workspace_url)
    page.goto(f"{workspace_url}/interviews/review/?id={sid}&answer={ids[0]}")
    page.get_by_text("Local recording playback", exact=True).click()
    file = page.get_by_label("Corresponding local recording")
    file.set_input_files({"name": "invalid.wav", "mimeType": "audio/wav", "buffer": b"invalid content"})
    expect(page.get_by_text("This browser could not read the recording.", exact=False)).to_be_visible()
    expect(page.get_by_role("button", name="Play excerpt", exact=True)).to_be_disabled()
    page.get_by_role("button", name="Remove recording").click()
    expect(file).to_be_enabled()
