"""Import a consented interview through the mounted browser workflow and actual HTTP service."""

from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from uuid import uuid4

import httpx
from playwright.sync_api import expect


def start(client):
    response = client.post(
        "/api/sessions",
        json={
            "candidate": "Import fixture",
            "role": "QA engineer",
            "policy": "Notes allowed.",
            "consent": True,
        },
    )
    response.raise_for_status()
    return response.json()["id"]


def test_concurrent_retry_and_late_conflict_are_atomic(workspace_url):
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as c:
        sid = start(c)
        path = f"/api/sessions/{sid}"
        batch = path + "/imports/webvtt"

        def turn(number):
            return {
                "ordinal": number,
                "start_ms": number * 1000,
                "end_ms": number * 1000 + 500,
                "first_cue": number * 2,
                "last_cue": number * 2 + 1,
                "question": "Which value did you record?",
                "answer": "I kept the original value.",
            }

        payload = {
            "request_id": str(uuid4()),
            "transcript_sha256": "5" * 64,
            "candidate_speaker": "Candidate",
            "interviewer_speakers": ["Host"],
            "exchanges": [turn(2), turn(4)],
        }
        gate = Barrier(2)

        def submit(_):
            gate.wait(timeout=4)
            response = c.post(batch, json=payload)
            response.raise_for_status()
            return response.json()

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(submit, (0, 1)))
        assert sorted((r["saved"], r["skipped"], r["replayed"]) for r in results) == [
            (0, 2, True),
            (2, 0, False),
        ]
        ids = results[0]["answer_ids"]
        assert results[1]["answer_ids"] == ids and len(set(ids)) == 2

        expanded = {
            **payload,
            "request_id": str(uuid4()),
            "interviewer_speakers": ["Host", "Observer"],
            "exchanges": [{**row, "ordinal": index} for index, row in enumerate(payload["exchanges"], 1)],
        }
        repeated = c.post(batch, json=expanded)
        repeated.raise_for_status()
        assert repeated.json()["answer_ids"] == ids
        assert (repeated.json()["saved"], repeated.json()["skipped"]) == (0, 2)

        invalid = {
            **payload,
            "request_id": str(uuid4()),
            "exchanges": [turn(6), {**turn(4), "answer": "Different text."}],
        }
        assert c.post(batch, json=invalid).status_code == 409
        assert [a["id"] for a in c.get(path).json()["answers"]] == ids
        c.post(path + "/finish").raise_for_status()
        replay = c.post(batch, json=payload)
        replay.raise_for_status()
        assert replay.json() == {"saved": 0, "skipped": 2, "answer_ids": ids, "replayed": True}
        assert c.post(batch, json={**payload, "exchanges": [turn(2)]}).status_code == 409
        assert c.post(batch, json={**payload, "request_id": str(uuid4())}).status_code == 409
        assert c.get(path).json()["answer_count"] == 2


def test_preview_multiple_speakers_and_import_only_selected_rows(workspace_url, browser_page):
    page = browser_page
    turns = [
        ("Interviewer", "Which initial measurement would you take?"),
        ("Candidate", "I would take a cold baseline."),
        ("Interviewer", "This prompt has an intervening speaker."),
        ("Observer", "The meeting will continue."),
        ("Candidate", "These words cannot be assigned to the prior prompt."),
        ("Interviewer", "What is the second step?"),
        ("Candidate", "Read the counter."),
    ]
    blocks = [
        f"00:00:{i * 2:02}.000 --> 00:00:{i * 2 + 1:02}.000\n<v {name}>{text}</v>"
        for i, (name, text) in enumerate(turns)
    ]
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as c:
        sid = start(c)
        path = f"/api/sessions/{sid}"
        page.goto(workspace_url + "/interviews/review/?id=" + sid)
        page.get_by_text("Import transcript exchanges", exact=True).click()
        file = page.get_by_label("Conversation WebVTT file")
        file.set_input_files(
            {
                "name": "panel.vtt",
                "mimeType": "text/vtt",
                "buffer": ("WEBVTT\n\n" + "\n\n".join(blocks)).encode(),
            }
        )
        page.get_by_label("Candidate in transcript").select_option("Candidate")
        page.get_by_role("checkbox", name="Interviewer", exact=True).check()
        page.get_by_role("button", name="Preview exchanges").click()
        expect(page.get_by_role("checkbox", name="Include exchange 1")).to_be_visible()
        assert page.get_by_role("checkbox", name="Include exchange", exact=False).count() == 2
        expect(page.get_by_text("This prompt has an intervening speaker.", exact=True)).to_have_count(0)
        assert c.get(path).json()["answer_count"] == 0
        page.get_by_role("button", name="Clear selection").click()
        save = page.get_by_role("button", name="Import selected exchanges")
        expect(save).to_be_disabled()
        page.get_by_role("checkbox", name="Include exchange 2").check()
        save.click()
        expect(page.get_by_role("heading", name="What is the second step?", exact=True)).to_be_visible()
        record = c.get(path).json()
        assert record["answer_count"] == 1
        (added,) = record["answers"]
        assert added["answer"] == "Read the counter."
        assert "answer=" + added["id"] in page.url
