import hashlib
import json
import re
from urllib.parse import urlsplit

import httpx
from playwright.sync_api import expect


BACKUP = "/api/backups/workspace"


def action(page):
    return page.get_by_role("link", name=re.compile(r"^(Download backup|Retry backup download)"))


def session(client, candidate, sid=None):
    payload = {"candidate": candidate, "role": "Review", "policy": "Manual", "consent": True}
    if sid:
        payload["id"] = sid
    return client.post("/api/sessions", json=payload).raise_for_status().json()["id"]


def test_backup_download_handles_trash_purge_and_same_scope_retry(workspace_url, browser_page):
    page = browser_page
    requests, names = [], []
    page.on("request", lambda r: requests.append(urlsplit(r.url).query) if urlsplit(r.url).path == BACKUP else None)
    page.on("download", lambda d: names.append(d.suggested_filename))
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, other = session(client, "One"), session(client, "Two")
        page.goto(workspace_url + "/data/")
        picker = page.get_by_label("Backup contents")
        picker.select_option(sid)
        routed = f"{BACKUP}?session_id={sid}"
        expect(action(page)).to_have_attribute("href", routed)
        entry = client.post(f"/api/sessions/{sid}/trash").raise_for_status().json()
        with page.expect_download() as first:
            action(page).click()
        raw = first.value.path().read_bytes()
        saved, = json.loads(raw)["sessions"]
        assert saved["id"] == sid and saved["trashed_at"] and first.value.suggested_filename == f"interview-{sid}.json"
        expect(page.get_by_role("status").filter(has_text="Download started")).to_be_visible()
        page.get_by_text("Backup checksum", exact=True).click()
        expect(page.get_by_label("Downloaded backup SHA-256")).to_have_value(hashlib.sha256(raw).hexdigest())
        client.post(f"/api/trash/{sid}/purge", json={"operation_version": entry["operation_version"],
                                                     "confirm_session_id": sid}).raise_for_status()
        action(page).click()
        expect(page.get_by_role("alert").filter(has_text="unavailable")).to_be_visible()
        expect(picker).to_have_value(sid)
        retry = page.get_by_role("link", name="Retry backup download for this interview")
        expect(retry).to_have_attribute("href", routed)
        assert names == [f"interview-{sid}.json"]
        session(client, "Recovered fixture", sid)
        with page.expect_download() as repeated:
            retry.click()
        assert [s["id"] for s in json.loads(repeated.value.path().read_bytes())["sessions"]] == [sid]
        picker.select_option("")
        with page.expect_download() as whole:
            action(page).click()
        assert {s["id"] for s in json.loads(whole.value.path().read_bytes())["sessions"]} == {sid, other}
        assert names == [f"interview-{sid}.json", f"interview-{sid}.json", "interviewcheck-workspace.json"]
        assert requests == [f"session_id={sid}"] * 3 + [""]


def test_bad_backup_responses_never_create_a_file(workspace_url, browser_page):
    page = browser_page
    downloads = []
    page.on("download", lambda d: downloads.append(d.suggested_filename))
    page.add_init_script("""(() => {
      const original = window.fetch.bind(window);
      window.backupAttempts = 0;
      window.fetch = (input, init) => {
        const url = new URL(typeof input === "string" ? input : input.url, location.href);
        if (url.pathname !== "/api/backups/workspace" || !window.backupFault) return original(input, init);
        window.backupAttempts++;
        const fault = window.backupFault;
        const headers = {"Content-Type":"application/json", "Content-Disposition":'attachment; filename="interviewcheck-workspace.json"', "X-Backup-SHA256":"0".repeat(64)};
        if (fault === "name") headers["Content-Disposition"] = 'attachment; filename="interview-wrong-scope.json"';
        if (fault === "html") headers["Content-Type"] = "text/html";
        if (fault === "long-error") return Promise.resolve(new Response("Private gateway fixture".repeat(1000), {status: 409, headers}));
        if (fault === "oversize") {
          let parts = 0;
          const block = new Uint8Array(1024 * 1024);
          return Promise.resolve(new Response(new ReadableStream({pull(controller) {
            if (parts++ < 21) controller.enqueue(block); else controller.close();
          }}), {headers: {...headers, "Content-Encoding":"gzip", "Content-Length":"17"}}));
        }
        return Promise.resolve(new Response('{"detail":"Private gateway fixture"}', {headers, status: Number(fault) || 200}));
      };
    })()""")
    page.goto(workspace_url + "/data/")
    download_panel = page.locator("section.data-panel").filter(has=page.get_by_role("heading", name="Download a backup", exact=True))
    cases = [("401", "Sign in"), ("413", "export limits"), ("html", "verifiable backup"), ("name", "verifiable backup"),
             ("checksum", "checksum does not match"), ("oversize", "exceeds 20 MiB"), ("long-error", "cannot preserve")]
    for index, (fault, expected) in enumerate(cases, 1):
        page.evaluate("(fault) => { window.backupFault = fault }", fault)
        action(page).click()
        alert = download_panel.get_by_role("alert")
        expect(alert).to_contain_text(expected)
        expect(alert).not_to_contain_text("Private gateway fixture")
        expect(page.get_by_role("link", name="Retry backup download for the entire workspace")).to_have_attribute("href", BACKUP)
        assert page.evaluate("window.backupAttempts") == index and downloads == []


def install_held_digest(page):
    page.add_init_script("""(() => {
      const fetch = window.fetch.bind(window);
      let expected = null;
      window.fetch = async (input, init) => {
        const response = await fetch(input, init);
        const url = new URL(input instanceof Request ? input.url : input, location.href);
        if (window.holdBackupDigest && url.origin === location.origin && url.pathname === "/api/backups/workspace" && response.ok) {
          expected = response.headers.get("X-Backup-SHA256")?.toLowerCase() ?? null;
        }
        return response;
      };
      const subtle = Object.getPrototypeOf(crypto.subtle);
      const digest = subtle.digest;
      subtle.digest = async function(...args) {
        const result = await digest.apply(this, args);
        // Hydration also computes digests. Only pause the bytes of the requested backup.
        if (window.holdBackupDigest && expected !== null &&
            Array.from(new Uint8Array(result), n => n.toString(16).padStart(2, "0")).join("") === expected) {
          expected = null;
          window.holdBackupDigest = false;
          await new Promise(resolve => {
            window.releaseBackupDigest = resolve;
            document.documentElement.dataset.heldBackupDigest = "true";
          });
        }
        return result;
      };
    })()""")


def test_scope_switch_while_checksum_is_pending_discards_the_old_response(workspace_url, browser_page):
    page = browser_page
    downloads = []
    page.on("download", lambda d: downloads.append(d.suggested_filename))
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        first, second = session(client, "First"), session(client, "Second")
    install_held_digest(page)
    page.goto(workspace_url + "/data/")
    scope = page.get_by_label("Backup contents")
    scope.select_option(first)
    page.evaluate("window.holdBackupDigest = true")
    action(page).click()
    expect(page.locator("html")).to_have_attribute("data-held-backup-digest", "true")
    scope.select_option(second)
    expect(action(page)).to_have_attribute("href", f"{BACKUP}?session_id={second}")
    page.evaluate("async () => { window.releaseBackupDigest(); await new Promise(requestAnimationFrame) }")
    expect(page.get_by_role("status").filter(has_text="Download started")).to_have_count(0)
    assert downloads == []
    with page.expect_download() as accepted:
        action(page).click()
    assert [r["id"] for r in json.loads(accepted.value.path().read_bytes())["sessions"]] == [second]
    assert downloads == [f"interview-{second}.json"]


def test_cancel_then_retry_same_scope_ignores_the_late_first_checksum(workspace_url, browser_page):
    page = browser_page
    requests, downloads = [], []
    page.on("request", lambda r: requests.append(urlsplit(r.url).query) if urlsplit(r.url).path == BACKUP else None)
    page.on("download", lambda d: downloads.append(d.suggested_filename))
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid = session(client, "Case fixture", "aabbccdd-0011-4222-8333-abcdef987654")

    def uppercase_feed(route):
        response = route.fetch()
        data = response.json()
        for row in data["items"]:
            row["id"] = row["id"].upper()
        route.fulfill(status=response.status, json=data)

    page.route(re.compile(r"/api/interviews/feed(?:\?|$)"), uppercase_feed)
    install_held_digest(page)
    page.goto(workspace_url + "/data/")
    page.get_by_label("Backup contents").select_option(sid.upper())
    expect(action(page)).to_have_attribute("href", f"{BACKUP}?session_id={sid}")
    page.evaluate("window.holdBackupDigest = true")
    action(page).click()
    held = page.locator("html")
    expect(held).to_have_attribute("data-held-backup-digest", "true")
    page.get_by_role("button", name="Cancel download").click()
    expect(page.get_by_role("status").filter(has_text="Backup download canceled.")).to_be_visible()
    expect(action(page)).to_be_focused()

    page.evaluate("""() => {
      window.releaseCanceledDigest = window.releaseBackupDigest;
      delete document.documentElement.dataset.heldBackupDigest;
      window.holdBackupDigest = true;
    }""")
    action(page).click()
    expect(held).to_have_attribute("data-held-backup-digest", "true")
    page.evaluate("async () => { window.releaseCanceledDigest(); await new Promise(requestAnimationFrame) }")
    expect(page.get_by_role("button", name="Cancel download")).to_be_visible()
    expect(page.get_by_role("status").filter(has_text="Download started")).to_have_count(0)
    # An aria-disabled link still receives browser events. The late completion
    # must not release the active retry and allow a third transfer.
    action(page).dispatch_event("click")
    assert downloads == []
    with page.expect_download() as accepted:
        page.evaluate("window.releaseBackupDigest()")
    assert accepted.value.suggested_filename == f"interview-{sid}.json"
    assert [s["id"] for s in json.loads(accepted.value.path().read_bytes())["sessions"]] == [sid]
    expect(page.get_by_role("status").filter(has_text="Download started")).to_be_visible()
    assert requests == [f"session_id={sid}"] * 2 and downloads == [f"interview-{sid}.json"]
