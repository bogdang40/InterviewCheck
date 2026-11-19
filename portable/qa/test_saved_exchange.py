"""Explicit saving keeps unfinished work recoverable without publishing its contents."""

from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from uuid import uuid4

import httpx
from playwright.sync_api import expect


def start(client):
    made = client.post(
        "/api/sessions",
        json={"candidate": "Draft fixture", "role": "Test", "policy": "Notes permitted.", "consent": True},
    )
    made.raise_for_status()
    return "/api/sessions/" + made.json()["id"]


def test_draft_reopen_publish_and_redaction(workspace_url, browser_page):
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as c:
        path = start(c)
        page = browser_page
        page.goto(workspace_url + "/interviews/review/?id=" + path.split("/")[-1])
        page.get_by_role("textbox", name="Question", exact=True).fill("Which gauge should we use?")
        page.get_by_label("Candidate answer").fill("Unfinished explanation about the amber gauge.")
        page.get_by_role("button", name="Save draft", exact=True).click()
        expect(page.get_by_role("button", name="Resume draft")).to_be_visible()
        draft = c.get(path + "/draft").json()
        assert draft["answer"].startswith("Unfinished") and c.get(path).json()["answer_count"] == 0
        assert "amber gauge" not in c.get(path + "/report").text
        assert "amber gauge" not in c.get(path + "/print").text
        assert "amber gauge" not in c.get("/api/exports/interviews.csv").text
        page.reload()
        page.get_by_role("button", name="Resume draft").click()
        expect(page.get_by_label("Candidate answer")).to_have_value(draft["answer"])
        page.get_by_role("button", name="Save and compare").click()
        expect(page.get_by_role("heading", name=draft["question"], exact=True)).to_be_visible()
        assert c.get(path + "/draft").json() is None
        assert [a["id"] for a in c.get(path).json()["answers"]] == [draft["id"]]


def test_finish_and_save_race_has_a_single_winner(workspace_url):
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as c:
        path = start(c)
        client_draft = {
            "id": str(uuid4()),
            "expected_revision": 0,
            "question": "A draft",
            "answer": "",
            "references": [],
        }
        start_now = Barrier(2)

        def write(action):
            start_now.wait(timeout=4)
            if action == "save":
                return c.put(path + "/draft", json=client_draft)
            return c.post(path + "/finish")

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(write, ("save", "finish")))
        assert sorted(r.status_code for r in results) == [200, 409]
        exists = c.get(path + "/draft").json() is not None
        assert exists != bool(c.get(path).json()["ended_at"])
        assert c.get(path).json()["answer_count"] == 0


def test_saved_draft_survives_service_restart(tmp_path):
    """Start two actual FastAPI processes over the same isolated database."""
    from contextlib import contextmanager
    from pathlib import Path
    import os
    import socket
    import subprocess
    import sys
    import time

    env = {key: value for key, value in os.environ.items() if not key.startswith("INTERVIEWCHECK_")}
    env["INTERVIEWCHECK_DB"] = str(tmp_path / "restart.sqlite")

    @contextmanager
    def running():
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        base = f"http://127.0.0.1:{port}"
        process = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "uvicorn",
                "api.main:app",
                "--host",
                "127.0.0.1",
                "--port",
                str(port),
                "--no-access-log",
            ],
            cwd=Path(__file__).resolve().parents[1],
            env=env,
        )
        try:
            with httpx.Client(base_url=base, headers={"X-InterviewCheck": "1"}) as c:
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline and process.poll() is None:
                    try:
                        if c.get("/api/health").is_success:
                            break
                    except httpx.ConnectError:
                        time.sleep(0.05)
                else:
                    raise RuntimeError("Isolated service did not start")
                yield c
        finally:
            process.terminate()
            process.wait(timeout=8)

    with running() as client:
        path = start(client)
        draft = {
            "id": str(uuid4()),
            "expected_revision": 0,
            "question": "Which reading?",
            "answer": "",
            "references": [],
        }
        saved = client.put(path + "/draft", json=draft)
        saved.raise_for_status()
    with running() as client:
        assert client.get(path + "/draft").json() == saved.json()
        assert client.get(path).json()["answer_count"] == 0
        publication = {
            **draft,
            "expected_revision": saved.json()["revision"],
            "answer": "I measured a cold sample.",
        }
        published = client.post(path + "/draft/publish", json=publication)
        published.raise_for_status()
        client.post(path + "/finish").raise_for_status()
        retried = client.post(path + "/draft/publish", json=publication)
        retried.raise_for_status()
        assert retried.json() == published.json()
        assert client.get(path).json()["answer_count"] == 1


def test_conflicting_saved_draft_keeps_both_versions(workspace_url, browser_page):
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as c:
        path = start(c)
        draft = {
            "id": str(uuid4()),
            "expected_revision": 0,
            "question": "Which trace?",
            "answer": "First reading.",
        }
        c.put(path + "/draft", json=draft).raise_for_status()
        page = browser_page
        other = page.context.new_page()
        try:
            for tab in (page, other):
                tab.goto(workspace_url + "/interviews/review/?id=" + path.split("/")[-1])
                tab.get_by_role("button", name="Resume draft").click()
                expect(tab.get_by_label("Candidate answer")).to_have_value("First reading.")
            page.get_by_label("Candidate answer").fill("My alternate reading.")
            other.get_by_label("Candidate answer").fill("Other saved reading.")
            other.get_by_role("button", name="Save draft", exact=True).click()
            expect(other.get_by_role("button", name="Resume draft")).to_be_visible()
            page.get_by_role("button", name="Save draft", exact=True).click()
            page.get_by_role("button", name="Compare saved draft").click()
            expect(page.get_by_label("Candidate answer")).to_have_value("My alternate reading.")
            expect(page.get_by_text("Other saved reading.", exact=True)).to_be_visible()
            assert c.get(path + "/draft").json()["answer"] == "Other saved reading."
            page.get_by_role("button", name="Use saved draft").click()
            expect(page.get_by_label("Candidate answer")).to_have_value("Other saved reading.")
            assert c.get(path).json()["answer_count"] == 0
        finally:
            other.close()
