"""Optional preview details explain what differs without displaying the conflicting values."""
import copy
import json
from urllib.parse import parse_qs, urlsplit

import httpx
from playwright.sync_api import expect


def test_conflict_reasons_remain_optional_private_and_read_only(workspace_url, browser_page, tmp_path):
    page = browser_page
    private = ["old-reviewer@example.test", "new-reviewer@example.test", "PRIVATE_EARLIER_RATIONALE",
               "PRIVATE_REPLACEMENT_RATIONALE", "PRIVATE_HANDOFF_TEXT", "PRIVATE_CHANGED_CRITERION"]
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        template = {"name": "Reason fixture role", "questions": ["What did you verify?"],
                    "rubric": [{"id": "checks", "criterion": "Initial criterion", "weight": 1}]}
        role = client.post("/api/roles", json=template).raise_for_status().json()
        sid = client.post("/api/sessions", json={
            "candidate": "Reason fixture candidate", "role": role["name"], "role_id": role["id"],
            "consent": True, "policy": "Notes allowed.",
        }).raise_for_status().json()["id"]
        route = f"/api/sessions/{sid}"
        score = {"criterion_id": "checks", "criterion_label": "Initial criterion", "weight": 1, "rating": 3}
        client.put(route + "/assignment", json={"assignee_email": private[0]}).raise_for_status()
        client.put(route + "/scorecard", json={"items": [{**score, "rationale": private[2]}]}).raise_for_status()
        raw = client.get("/api/backups/workspace", params={"session_id": sid}).raise_for_status().content
        client.put(route + "/assignment", json={"assignee_email": private[1]}).raise_for_status()
        client.put(route + "/scorecard", json={"items": [{**score, "rationale": private[3]}]}).raise_for_status()
        client.post(route + "/handoff-notes", json={"category": "observation", "body": private[4]}).raise_for_status()
        client.put("/api/roles/" + role["id"], json={
            **template, "rubric": [{"id": "checks", "criterion": private[5], "weight": 2}],
        }).raise_for_status()

    source = tmp_path / "changed-interview.json"
    source.write_bytes(raw)
    page.goto(workspace_url + "/data/")
    file_input = page.get_by_label("Workspace backup file")
    expect(file_input).to_have_attribute("data-hydrated", "true")
    file_input.set_input_files(source)
    preview = page.get_by_role("button", name="Preview restore", exact=True)
    writes = []
    page.on("request", lambda req: writes.append(req.url) if urlsplit(req.url).path == "/api/backups/restore" else None)
    with page.expect_response(lambda r: urlsplit(r.url).path == "/api/backups/preview") as result:
        preview.click()
    response = result.value
    assert response.ok and parse_qs(urlsplit(response.url).query) == {"include_conflict_reasons": ["true"]}
    assert "x-backup-preview" not in response.request.headers
    plan = response.json()
    assert all(text not in json.dumps(plan) for text in private)
    conflict = page.get_by_role("alert").filter(has_text="Restore blocked by conflicting records.")
    session_row = conflict.get_by_role("listitem").filter(has_text=sid)
    role_row = conflict.get_by_role("listitem").filter(has_text=role["id"])
    expect(session_row).to_contain_text("Review assignment")
    expect(session_row).to_contain_text("Panel handoff notes")
    expect(session_row).to_contain_text("Saved scorecard")
    expect(role_row).to_contain_text("Rubric criteria")
    assert all(text not in conflict.inner_text() for text in private)
    apply = page.get_by_role("button", name="Restore new records")
    expect(apply).to_have_count(0)

    # A legacy reply and malformed or future reason data preserve the same verified, blocked plan.
    for metadata, known in ((None, False), ({"body": private[4]}, False),
                            (["assignment", private[4], "rubric", "constructor", {"text": private[2]}, "assignment"], True)):
        variant = copy.deepcopy(plan)
        for entry in variant["conflicts"]:
            entry.pop("reasons", None)
            if entry["kind"] == "sessions" and metadata is not None:
                entry["reasons"] = metadata
        pattern = "**/api/backups/preview?include_conflict_reasons=true"
        page.route(pattern, lambda intercepted: intercepted.fulfill(json=variant))
        with page.expect_response(lambda r: urlsplit(r.url).path == "/api/backups/preview"):
            preview.click()
        expect(session_row.get_by_text("Saved scorecard", exact=False)).to_have_count(0)
        if known:
            expect(session_row).to_contain_text("Review assignment")
            assert session_row.inner_text().count("Review assignment") == 1
        else:
            expect(session_row).not_to_contain_text("Review assignment")
        expect(session_row).to_contain_text("Reason fixture candidate")
        expect(role_row).to_contain_text("Reason fixture role")
        expect(session_row).not_to_contain_text("Rubric criteria")
        assert all(text not in conflict.inner_text() for text in private)
        expect(apply).to_have_count(0)
        assert file_input.evaluate("el => el.files[0].name") == source.name
        page.unroute(pattern)
    assert writes == []
