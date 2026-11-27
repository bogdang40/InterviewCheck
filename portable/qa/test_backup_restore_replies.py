"""Restore requires a verified preview, including after a reply is lost following commit."""
import hashlib
import json
import re
from urllib.parse import urlsplit
from uuid import uuid4

import httpx
from playwright.sync_api import expect
import pytest


PREVIEW = "/api/backups/preview"
RESTORE = "/api/backups/restore"
PREVIEW_QUERY = "include_conflict_reasons=true"
PREVIEW_ROUTE = re.compile(re.escape(PREVIEW + "?" + PREVIEW_QUERY) + "$")
HEADERS = {"X-InterviewCheck": "1", "Content-Type": "application/json"}


@pytest.fixture
def archive(workspace_url, tmp_path, monkeypatch):
    from api import store
    with httpx.Client(base_url=workspace_url, headers=HEADERS) as client:
        sid = client.post("/api/sessions", json={"candidate": "Restore fixture", "role": "Engineer",
            "policy": "Manual allowed.", "consent": True}).raise_for_status().json()["id"]
        raw = client.get("/api/backups/workspace", params={"session_id": sid}).raise_for_status().content
        path = tmp_path / "interview.json"
        path.write_bytes(raw)
        target = tmp_path / "destination.sqlite"
        store.initialize(target)
        monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
        plan = client.post(PREVIEW, content=raw).raise_for_status().json()
        assert plan["sessions"] == {"new": 1, "identical": 0, "conflict": 0}
        assert plan["fingerprint"] == hashlib.sha256(raw).hexdigest()
    return path, sid, plan


def open_file(page, base, path):
    page.goto(base + "/data/")
    picker = page.get_by_label("Workspace backup file")
    expect(picker).to_have_attribute("data-hydrated", "true")
    picker.set_input_files(path)
    return picker


def apply(page):
    return page.get_by_role("button", name="Restore new records", exact=True)


def restore_alert(page):
    heading = page.get_by_role("heading", name="Restore from a backup", exact=True)
    return page.locator("section").filter(has=heading).get_by_role("alert")


def no_apply(page):
    expect(apply(page).and_(page.locator(":enabled"))).to_have_count(0)


def test_invalid_preview_replies_remove_a_previously_valid_plan(workspace_url, browser_page, archive):
    page = browser_page
    path, _, plan = archive
    wrong = "f" * 64 if plan["fingerprint"] != "f" * 64 else "0" * 64
    invalid = [
        ("text/html", "<html>Gateway fixture</html>", {}),
        ("text/plain", json.dumps(plan), {}),
        ("application/json", "null", {}),
        ("application/json", json.dumps({**plan, "sessions": {**plan["sessions"], "conflict": 1}}), {}),
        ("application/json", json.dumps({**plan, "fingerprint": wrong}), {}),
        ("application/json", json.dumps(plan), {"X-Backup-SHA256": wrong}),
    ]
    for group, limit in (("roles", 4000), ("sessions", 5000)):
        impossible = {**plan, group: {**plan[group], "new": limit + 1}}
        invalid.append(("application/json", json.dumps(impossible), {}))
    for field, limit in (("answers", 20000), ("scorecard_items", 25)):
        # This file has exactly one session.
        invalid.append(("application/json", json.dumps({**plan, field: limit + 1}), {}))
    picker = open_file(page, workspace_url, path)
    writes = []
    page.on("request", lambda req: writes.append(req.method) if urlsplit(req.url).path == RESTORE else None)
    preview = page.get_by_role("button", name="Preview restore", exact=True)
    for mime, body, headers in invalid:
        preview.click()
        expect(apply(page)).to_be_enabled()
        page.route(PREVIEW_ROUTE, lambda route: route.fulfill(status=200, content_type=mime, body=body, headers=headers))
        preview.click()
        expect(restore_alert(page)).to_contain_text(re.compile(r"preview|checksum|match|verif|digest", re.I))
        no_apply(page)
        assert picker.evaluate("(el) => el.files[0]?.name") == path.name
        expect(preview).to_be_enabled()
        page.unroute(PREVIEW_ROUTE)
    assert writes == []


def test_only_material_checksum_edits_invalidate_the_plan(workspace_url, browser_page, archive):
    page = browser_page
    path, _, plan = archive
    writes = []
    feed_reads = []
    page.on("request", lambda req: writes.append(req.method) if urlsplit(req.url).path == RESTORE else None)
    page.on("request", lambda req: feed_reads.append(req.method) if urlsplit(req.url).path == "/api/interviews/feed" else None)
    picker = open_file(page, workspace_url, path)
    expect(page.get_by_label("Backup contents")).to_have_attribute("aria-busy", "false")
    initial_reads = len(feed_reads)
    checksum = page.get_by_label("Expected SHA-256 checksum (optional)")
    preview = page.get_by_role("button", name="Preview restore", exact=True)
    valid = plan["fingerprint"]
    checksum.fill(valid)
    preview.click()
    expect(apply(page)).to_be_enabled()
    checksum.fill("  " + valid.upper() + "  ")
    expect(apply(page)).to_be_enabled()
    checksum.fill(("a" if valid[0] != "a" else "b") + valid[1:])
    no_apply(page)
    expect(page.get_by_role("heading", name="Restore preview")).to_have_count(0)
    assert picker.evaluate("(el) => el.files[0]?.name") == path.name
    preview.click()
    expect(restore_alert(page)).to_contain_text("does not match the selected file")
    checksum.fill(valid)
    no_apply(page)
    preview.click()
    expect(apply(page)).to_be_enabled()
    assert writes == [] and len(feed_reads) == initial_reads


def test_capped_conflict_sample_preserves_valid_historical_labels(workspace_url, browser_page, archive):
    page = browser_page
    path, _, _ = archive
    doc = json.loads(path.read_bytes())
    sample, = doc["sessions"]
    doc["sessions"] = []
    with httpx.Client(base_url=workspace_url, headers=HEADERS) as client:
        for i in range(21):
            sid = str(uuid4())
            client.post("/api/sessions", json={"id": sid, "candidate": f"Current fixture {i}",
                "role": "Engineer", "policy": "Manual allowed.", "consent": True}).raise_for_status()
            label = f"Historical fixture {i}"
            if i == 0:
                label += " β" * 260
            elif i == 1:
                label = ""
            doc["sessions"].append({**sample, "id": sid, "candidate": label, "legacy": {"fixture": True}})
        raw = json.dumps(doc).encode()
        plan = client.post(PREVIEW, content=raw).raise_for_status().json()
        assert plan["sessions"]["conflict"] == 21 and len(plan["conflicts"]) == 20
    path.write_bytes(raw)
    open_file(page, workspace_url, path)
    page.get_by_role("button", name="Preview restore", exact=True).click()
    expect(page.get_by_role("heading", name="Restore preview")).to_be_visible()
    notice = restore_alert(page).filter(has_text=re.compile("conflict", re.I))
    expect(notice.get_by_role("listitem")).to_have_count(20)
    expect(notice.get_by_role("listitem").first).to_contain_text("Historical fixture 0")
    expect(page.get_by_role("row", name=re.compile(r"Interviews.*21"))).to_be_visible()
    no_apply(page)


def test_older_server_reply_without_download_header_or_review_counts(workspace_url, browser_page, archive):
    page = browser_page
    path, sid, _ = archive
    doc = json.loads(path.read_bytes())
    doc["version"] = 1
    for record in doc["sessions"]:
        for field in ("assignment", "handoff_notes", "scorecard_items", "rubric_snapshot", "privacy"):
            del record[field]
    path.write_bytes(json.dumps(doc).encode())

    restored_urls = []

    def old_reply(route):
        if urlsplit(route.request.url).path == RESTORE:
            restored_urls.append(route.request.url)
        upstream = route.fetch()
        try:
            assert upstream.status == 200
            result = upstream.json()
            for field in ("assignments", "handoff_notes", "scorecard_items"):
                del result[field]
            route.fulfill(status=200, content_type="application/json; charset=utf-8", body=json.dumps(result))
        finally:
            upstream.dispose()

    open_file(page, workspace_url, path)
    page.route(PREVIEW_ROUTE, old_reply)
    page.route("**" + RESTORE, old_reply)
    page.get_by_role("button", name="Preview restore", exact=True).click()
    expect(apply(page)).to_be_enabled()
    fingerprint = hashlib.sha256(path.read_bytes()).hexdigest()
    expect(page.get_by_test_id("backup-sha256")).to_have_text(fingerprint)
    expect(page.get_by_role("heading", name="Restore preview").locator("..")).to_contain_text(re.compile("not reported", re.I))
    # Another client restores the same archive before this reviewer's Apply. Only the new/identical split changes.
    with httpx.Client(base_url=workspace_url, headers=HEADERS) as client:
        prior = client.post(RESTORE, content=path.read_bytes(), headers={"X-Backup-Preview": fingerprint})
        assert prior.raise_for_status().json()["sessions"]["new"] == 1
    apply(page).click()
    expect(page.get_by_role("status").filter(has_text=re.compile(r"Skipped 1 identical"))).to_be_visible()
    assert len(restored_urls) == 1 and not urlsplit(restored_urls[0]).query
    with httpx.Client(base_url=workspace_url, headers=HEADERS) as client:
        assert client.get(f"/api/sessions/{sid}").raise_for_status().json()["candidate"] == "Restore fixture"


@pytest.mark.parametrize("failure", ["disconnect", "inconsistent acknowledgement", "omitted count"])
def test_lost_or_invalid_reply_after_commit_requires_read_only_repreview(workspace_url, browser_page, archive, failure):
    page = browser_page
    path, sid, plan = archive
    previous = ""
    if failure == "disconnect":
        with httpx.Client(base_url=workspace_url, headers=HEADERS) as client:
            previous = client.post("/api/sessions", json={"candidate": "Previously selected", "role": "Reviewer",
                                   "policy": "Manual", "consent": True}).raise_for_status().json()["id"]
    page.add_init_script("""(() => {
      const normal = window.fetch.bind(window);
      window.fetch = async (input, init) => {
        const response = await normal(input, init);
        if (!response.ok || init?.method !== "POST" || new URL(response.url).pathname !== "/api/backups/restore") return response;
        await response.clone().arrayBuffer();
        await new Promise(resolve => {
          document.addEventListener("end-restore-reply", resolve, { once: true });
          document.documentElement.dataset.restoreCommitted = "true";
        });
        if (window.restoreFailure === "disconnect") throw new TypeError("Synthetic lost restore reply");
        const wrong = await response.json();
        if (window.restoreFailure === "omitted count") delete wrong.assignments;
        else wrong.sessions.new++;
        return new Response(JSON.stringify(wrong), {status:200, headers:{"Content-Type":"application/json"}});
      };
    })()""")
    calls = []
    page.on("request", lambda r: calls.append(r) if urlsplit(r.url).path in (RESTORE, PREVIEW) else None)
    picker = open_file(page, workspace_url, path)
    scope = page.get_by_label("Backup contents")
    expect(scope).to_have_attribute("aria-busy", "false")
    expect(scope.locator(f'option[value="{sid}"]')).to_have_count(0)
    if previous:
        scope.select_option(previous)
    page.evaluate("(failure) => { window.restoreFailure = failure }", failure)
    expected = page.get_by_label("Expected SHA-256 checksum (optional)")
    expected.fill(plan["fingerprint"].upper())
    preview = page.get_by_role("button", name="Preview restore", exact=True)
    preview.click()
    apply(page).click()
    expect(page.locator("html")).to_have_attribute("data-restore-committed", "true")
    with httpx.Client(base_url=workspace_url, headers=HEADERS) as client:
        assert {item["id"] for item in client.get("/api/sessions").raise_for_status().json()} == ({sid, previous} if previous else {sid})
    page.evaluate("document.dispatchEvent(new Event('end-restore-reply'))")
    notice = restore_alert(page)
    expect(notice).to_contain_text(re.compile(r"may have completed|outcome.*unknown", re.I))
    expect(notice).to_contain_text(re.compile("preview", re.I))
    assert picker.evaluate("(el) => el.files[0]?.name") == path.name
    assert expected.input_value().lower() == plan["fingerprint"]
    no_apply(page)
    preview.click()
    expect(page.get_by_text("All records are already present.", exact=True)).to_be_visible()
    no_apply(page)
    expect(scope.locator(f'option[value="{sid}"]')).to_have_count(1)
    expect(scope).to_have_value(previous)
    if previous:
        expect(page.get_by_role("link", name="Download backup for this interview")).to_have_attribute(
            "href", f"/api/backups/workspace?session_id={previous}")
    scope.select_option(sid)
    expect(page.get_by_role("link", name="Download backup for this interview")).to_have_attribute(
        "href", f"/api/backups/workspace?session_id={sid}")
    assert [urlsplit(req.url).path for req in calls] == [PREVIEW, RESTORE, PREVIEW]
    assert [urlsplit(req.url).query for req in calls] == [PREVIEW_QUERY, "", PREVIEW_QUERY]
    assert calls[1].headers["x-backup-preview"] == plan["fingerprint"]
    assert all("x-backup-preview" not in req.headers for req in (calls[0], calls[2]))
    assert all(req.headers["x-backup-sha256"].lower() == plan["fingerprint"] for req in calls)
