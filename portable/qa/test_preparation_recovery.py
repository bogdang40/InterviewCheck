"""Retain the rules, evidence, and transcript identity through a workstation move."""

import json
from uuid import uuid4

import httpx
from playwright.sync_api import expect


REFERENCE = "Measure the amber receiver against three cold baselines before comparing its packet counts."


def test_permission_snapshot_and_browser_restore(workspace_url, browser_page, monkeypatch, tmp_path):
    from api import store

    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as c:
        role = {
            "name": "Instrument engineer",
            "description": "Test calibration.",
            "questions": ["Which readings?"],
            "policy": "You may read the operator manual.",
            "permitted_sources": [{"label": "Manual", "text": REFERENCE}],
        }
        template = c.post("/api/roles", json=role)
        template.raise_for_status()
        rid = template.json()["id"]
        page.goto(workspace_url + "/interviews/new/")
        page.get_by_label("Saved role template").select_option(rid)
        expect(page.get_by_label("Assistance policy")).to_have_value(role["policy"])
        page.get_by_label("Candidate", exact=True).fill("Oak restore")
        notice = page.get_by_role("checkbox", name="I confirmed", exact=False)
        notice.check()
        page.get_by_label("Assistance policy").fill("Operator manual allowed for this interview.")
        expect(notice).not_to_be_checked()
        notice.check()
        page.get_by_role("button", name="Start interview").click()
        expect(page.get_by_role("heading", name="Oak restore", exact=True)).to_be_visible()
        sid = c.get("/api/sessions").json()[0]["id"]
        route = "/api/sessions/" + sid
        capture = {
            "question": "Which readings?",
            "answer": REFERENCE,
            "references": [{"label": "Generated answer", "text": REFERENCE}],
        }
        assert c.post(route + "/preview", json=capture).json()["status"] == "no_match"
        record = c.post(route + "/answers", json=capture)
        record.raise_for_status()
        assert record.json()["result"]["status"] == "no_match"
        assert c.put(
            "/api/roles/" + rid, json={**role, "policy": "Reference access closed.", "permitted_sources": []}
        ).is_success
        assert c.get(route).json()["permitted_sources"] == role["permitted_sources"]
        corrected = c.put(
            route + "/answers/" + record.json()["id"],
            json={**capture, "answer": "I also checked the meter. " + REFERENCE},
        )
        assert corrected.json()["result"]["status"] == "no_match"
        imported = {
            "request_id": str(uuid4()),
            "transcript_sha256": "7" * 64,
            "candidate_speaker": "Oak",
            "interviewer_speakers": ["Host"],
            "exchanges": [
                {
                    "ordinal": 1,
                    "first_cue": 1,
                    "last_cue": 2,
                    "start_ms": 1000,
                    "end_ms": 3200,
                    "question": "Why?",
                    "answer": "A separate calibration run was cleaner.",
                }
            ],
        }
        captured = c.post(route + "/imports/webvtt", json=imported)
        captured.raise_for_status()
        assert REFERENCE in c.get(route + "/report").text and REFERENCE in c.get(route + "/print").text
        partial = {
            "id": str(uuid4()),
            "expected_revision": 0,
            "question": "Private unfinished draft",
            "answer": "",
            "references": [],
        }
        held = c.put(route + "/draft", json=partial)
        held.raise_for_status()
        original = c.get(route).json()
        page.goto(workspace_url + "/data/")
        page.get_by_label("Backup contents").select_option(sid)
        with page.expect_download() as download:
            page.get_by_role("link", name="Download backup").click()
        file = tmp_path / "fixture.json"
        download.value.save_as(file)
        backup = json.loads(file.read_bytes())
        assert [r["id"] for r in backup["roles"]] == [rid]
        assert [r["id"] for r in backup["sessions"]] == [sid]
        target = tmp_path / "restored.sqlite"
        store.initialize(target)
        monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
        page.reload()
        page.get_by_label("Workspace backup file").set_input_files(file)
        assert c.get("/api/sessions").json() == []
        page.get_by_role("button", name="Preview restore").click()
        expect(page.get_by_role("heading", name="Restore preview")).to_be_visible()
        assert c.get("/api/roles").json() == []
        page.get_by_role("button", name="Restore new records").click()
        expect(page.get_by_role("status").filter(has_text="Restored 1")).to_be_visible()
        assert c.get(route).json() == original
        assert c.get(route + "/draft").json() == held.json()
        assert "Private unfinished draft" not in c.get(route + "/report").text
        rerun = c.post(route + "/imports/webvtt", json={**imported, "request_id": str(uuid4())})
        rerun.raise_for_status()
        assert (rerun.json()["saved"], rerun.json()["answer_ids"]) == (0, captured.json()["answer_ids"])


def test_backup_size_through_real_ingress(workspace_url):
    role = {
        "name": "Reference test",
        "description": "w" * 23000,
        "questions": [],
        "policy": "",
        "permitted_sources": [],
    }
    roles = [{**role, "id": str(uuid4())} for _ in range(95)]
    raw = json.dumps(
        {"format": "interviewcheck.workspace", "version": 1, "roles": roles, "sessions": []}
    ).encode()
    assert 2 * 1024 * 1024 < len(raw) < 20 * 1024 * 1024
    with httpx.Client(
        base_url=workspace_url,
        headers={"X-InterviewCheck": "1", "Content-Type": "application/json"},
        timeout=15,
    ) as c:
        checked = c.post("/api/backups/preview", content=raw)
        checked.raise_for_status()
        assert checked.json()["roles"]["new"] == len(roles)
        assert c.get("/api/roles").json() == []
        too_big = raw.ljust(20 * 1024 * 1024 + 1, b" ")
        assert c.post("/api/backups/preview", content=too_big).status_code == 413

    # The proxy can close the upload connection after an early size rejection.
    roles_after_rejection = httpx.get(f"{workspace_url}/api/roles", timeout=15)
    assert roles_after_rejection.status_code == 200
    assert roles_after_rejection.json() == []
