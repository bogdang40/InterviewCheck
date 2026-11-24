"""Reach repeated records beyond page one without leaking query text or changing backup scope."""
import json
import re
from urllib.parse import urlsplit

import httpx
from playwright.sync_api import expect


QUESTION = "Private checkpoint question for repeated exchanges?"
BODY = "PRIVATE_ANSWER_FIXTURE_ONLY"


def seed(client):
    sessions, answers = [], []
    # Distinct records share the same name, role, UUID prefix and suffix.
    for i in range(41):
        sid = f"12345678-0000-4000-8000-{i:08x}aaaa"
        aid = f"87654321-0000-4000-8000-{i:08x}bbbb"
        client.post("/api/sessions", json={
            "id": sid, "candidate": "Interviews", "role": "Checkpoint engineer",
            "policy": "Manual permitted.", "consent": True,
        }).raise_for_status()
        client.post(f"/api/sessions/{sid}/answers", json={
            "id": aid, "question": QUESTION, "answer": BODY,
        }).raise_for_status()
        sessions.append(sid)
        answers.append(aid)
    return sessions, answers


def test_search_launcher_before_hydration(workspace_url, qa_browser):
    page = qa_browser.new_page(java_script_enabled=False)
    try:
        page.goto(workspace_url + "/roles/")
        trigger = page.get_by_role("button", name="Search workspace", exact=True)
        expect(trigger).to_be_disabled()
        assert trigger.get_attribute("disabled") is not None
        assert trigger.get_attribute("aria-keyshortcuts") is None
        expect(trigger.locator("kbd")).to_have_count(0)
    finally:
        page.close()


def test_keyboard_palette_pages_to_exact_session_and_exchange(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sessions, answers = seed(client)
    searches = []
    page.on("request", lambda req: searches.append(req) if urlsplit(req.url).path == "/api/search" else None)
    page.goto(workspace_url + "/roles/")
    trigger = page.get_by_role("button", name="Search workspace", exact=True)
    expect(trigger).to_be_enabled()
    expect(trigger).to_have_attribute("aria-keyshortcuts", "Meta+k Control+k")
    page.keyboard.press("Control+k")
    dialog = page.get_by_role("dialog", name="Search workspace")
    query = dialog.get_by_role("combobox", name="Search workspace records", exact=True)
    expect(query).to_be_focused()
    query.fill("Interviews")
    expect(dialog.get_by_role("status")).to_contain_text("Page 1. 20 records shown.")
    command = dialog.get_by_role("option", name=re.compile("Go to Interviews"))
    expect(command).to_be_visible()
    history_size = page.evaluate("history.length")
    query.press("PageDown")
    expect(dialog.get_by_role("status")).to_contain_text("Page 2. 20 records shown.")
    expect(command).to_be_visible()
    current = dialog.locator('[role="option"][aria-selected="true"]')
    expect(current).to_have_attribute("href", f"/interviews/review/?id={sessions[20]}")
    expect(current).to_contain_text("Checkpoint engineer")
    expect(current).to_contain_text(sessions[20])
    dialog.get_by_role("button", name="Previous results").click()
    expect(query).to_be_focused()
    expect(current).to_have_attribute("href", f"/interviews/review/?id={sessions[0]}")
    query.press("PageDown")
    expect(dialog.get_by_role("status")).to_contain_text("Page 2. 20 records shown.")
    # The final match is now the 40th live record, though its cursor is still on page three.
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        moved = client.post(f"/api/sessions/{sessions[0]}/trash").raise_for_status().json()
    query.press("PageDown")
    expect(dialog.get_by_role("status")).to_have_text("Page 3. 1 record shown.")
    expect(dialog.get_by_role("button", name="Next results")).to_be_disabled()
    assert page.evaluate("history.length") == history_size
    assert page.url == workspace_url + "/roles/"
    query.press("Enter")
    expect(page).to_have_url(f"{workspace_url}/interviews/review/?id={sessions[-1]}")

    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        client.post(f"/api/trash/{sessions[0]}/restore", json={"operation_version": moved["operation_version"]}).raise_for_status()
    page.keyboard.press("Control+k")
    query.fill(QUESTION)
    for number in (1, 2, 3):
        if number > 1:
            query.press("PageDown")
        expect(dialog.get_by_role("status")).to_contain_text(f"Page {number}.")
    expect(current).to_contain_text(answers[-1])
    query.press("Enter")
    expect(page).to_have_url(f"{workspace_url}/interviews/review/?id={sessions[-1]}&answer={answers[-1]}")
    assert searches and all(req.method == "POST" and not urlsplit(req.url).query for req in searches)
    assert any(req.post_data_json["query"] == QUESTION and req.post_data_json["cursor"] for req in searches)


def test_backup_scope_survives_search_paging_and_list_failures(workspace_url, browser_page, tmp_path):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sessions, _ = seed(client)
    page.add_init_script("""
      const original = window.fetch.bind(window);
      window.backupQueries = [];
      window.fetch = async (input, init) => {
        const url = new URL(input instanceof Request ? input.url : input, location.href);
        if (url.pathname !== "/api/search") return original(input, init);
        const body = JSON.parse(init.body);
        window.backupQueries.push(body);
        if (window.failBackupSearch) {
          window.failBackupSearch = false;
          return new Response(JSON.stringify({detail: "Search fixture unavailable."}), {status: 503});
        }
        if (body.cursor && !window.heldBackupSearch) {
          window.heldBackupSearch = true;
          const response = await original(input, {...init, signal: undefined});
          await response.clone().text();
          await new Promise(resolve => {
            window.releaseBackupSearch = resolve;
            document.documentElement.dataset.heldBackup = "true";
          });
          return response;
        }
        return original(input, init);
      };
    """)
    page.goto(workspace_url + "/data/")
    search = page.get_by_role("searchbox", name="Find an interview")
    contents = page.get_by_role("combobox", name="Backup contents")
    pager = page.get_by_role("navigation", name="Backup interview pages")
    download = page.get_by_role("link", name="Download backup")
    expect(page.get_by_text("Page 1. Interviews 1 to 20.", exact=True)).to_be_visible()
    pager.get_by_role("button", name="Next results").click()
    expect(page.get_by_text("Page 2. Interviews 21 to 40.", exact=True)).to_be_visible()
    expect(contents).to_be_focused()
    search.fill("Interviews")
    expect(page.get_by_text("Page 1. 20 interviews shown.", exact=True)).to_be_visible()
    opt = contents.locator(f'option[value="{sessions[0]}"]')
    expect(opt).to_contain_text(sessions[0])
    contents.select_option(sessions[0])
    scoped_url = f"/api/backups/workspace?session_id={sessions[0]}"
    pager.get_by_role("button", name="Next results").click()
    expect(page.locator("html")).to_have_attribute("data-held-backup", "true")
    expect(contents.get_by_role("option")).to_have_count(2)
    search.fill(QUESTION)
    expect(page.get_by_text("Page 1. 0 interviews shown.", exact=True)).to_be_visible()
    page.evaluate("async () => { window.releaseBackupSearch(); await new Promise(requestAnimationFrame); }")
    expect(contents.get_by_role("option")).to_have_count(2)
    expect(download).to_have_attribute("href", scoped_url)
    expect(contents).to_have_value(sessions[0])
    assert BODY not in page.content()

    search.fill("Interviews")
    expect(page.get_by_text("Page 1. 20 interviews shown.", exact=True)).to_be_visible()
    page.evaluate("window.failBackupSearch = true")
    pager.get_by_role("button", name="Next results").click()
    expect(page.get_by_role("alert").filter(has_text="Search fixture unavailable.")).to_be_visible()
    expect(download).to_have_attribute("href", scoped_url)
    hold_next = "() => { window.heldBackupSearch = false; delete document.documentElement.dataset.heldBackup; }"
    page.evaluate(hold_next)
    retry = page.get_by_role("button", name="Retry interview list")
    retry.press("Enter")
    expect(page.locator("html")).to_have_attribute("data-held-backup", "true")
    expect(retry).to_have_count(0)
    page.evaluate("window.releaseBackupSearch()")
    expect(page.get_by_text("Page 2. 20 interviews shown.", exact=True)).to_be_visible()
    expect(contents).to_be_focused()
    page.evaluate(hold_next)
    pager.get_by_role("button", name="Next results").press("Enter")
    expect(page.locator("html")).to_have_attribute("data-held-backup", "true")
    checksum = page.get_by_role("textbox", name="Expected SHA-256 checksum (optional)")
    checksum.fill("abcd")
    page.evaluate("window.releaseBackupSearch()")
    expect(page.get_by_text("Page 3. 1 interview shown.", exact=True)).to_be_visible()
    expect(checksum).to_be_focused()
    expect(checksum).to_have_value("abcd")
    contents.select_option(sessions[-1])
    search.fill("")
    expect(contents).to_have_value(sessions[-1])
    assert page.url == workspace_url + "/data/"
    assert all(body["kinds"] == ["session"] for body in page.evaluate("window.backupQueries"))
    with page.expect_download() as event:
        download.click()
    backup = tmp_path / "selected-interview.json"
    event.value.save_as(backup)
    assert [item["id"] for item in json.loads(backup.read_bytes())["sessions"]] == [sessions[-1]]

    page.route("**/api/interviews/feed?*", lambda route: route.fulfill(status=503, json={"detail": "Interview list unavailable."}))
    page.reload()
    expect(page.get_by_role("alert").filter(has_text="Interview list unavailable.")).to_be_visible()
    page.get_by_label("Workspace backup file").set_input_files(backup)
    page.get_by_role("button", name="Preview restore").click()
    expect(page.get_by_role("heading", name="Restore preview")).to_be_visible()
