"""Panel notes page independently of the current scorecard and composer drafts."""
from urllib.parse import parse_qs, urlsplit

import httpx
from playwright.sync_api import expect
import pytest


def seed(client, count):
    from api import store

    role = client.post("/api/roles", json={
        "name": "Panel fixture", "rubric": [{"id": "signal", "criterion": "Evidence checks", "weight": 2}],
    }).raise_for_status().json()
    sid = client.post("/api/sessions", json={
        "candidate": "Panel candidate", "role": role["name"], "role_id": role["id"], "consent": True, "policy": "Notes allowed.",
    }).raise_for_status().json()["id"]
    path = f"/api/sessions/{sid}/handoff-notes"
    observations = [client.post(path, json={"category": "observation", "body": f"Private observation {n}."}).raise_for_status().json()
                    for n in range(count)]
    concern = client.post(path, json={"category": "concern", "body": "Private concern wording."}).raise_for_status().json()
    # An imported set can have identical timestamps, and retention can remove the body.
    observations.sort(key=lambda record: record["id"], reverse=True)
    with store.connection(write=True) as db:
        db.execute("UPDATE session_handoff_notes SET created_at=? WHERE session_id=?", ("2025-03-10T09:00:00+00:00", sid))
        db.execute("UPDATE session_handoff_notes SET body='' WHERE id=?", (observations[0]["id"],))
    return sid, path, observations, concern


def test_panel_note_pages_preserve_drafts_and_recover_focus(workspace_url, browser_page, tmp_path):
    page = browser_page
    calls = []
    page.on("request", lambda r: calls.append((r.method, urlsplit(r.url))))
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path, observations, _ = seed(client, 41)
        page.goto(f"{workspace_url}/interviews/review/?id={sid}")
        notes = page.get_by_role("region", name="Panel handoff notes")
        selector = notes.get_by_label("Show handoff notes")
        composer = notes.get_by_role("textbox", name="Handoff note")
        rating = page.get_by_role("button", name="Rate Evidence checks 4 of 5")
        rating.click()
        composer.fill("Private draft for the decision.")
        notes.get_by_role("combobox", name="Category", exact=True).select_option("decision")
        selector.select_option("observation")
        expect(notes.get_by_text("Page 1. Showing 20 of 41 notes.")).to_be_visible()
        expect(notes.get_by_role("listitem")).to_have_count(20)
        expect(notes.get_by_text("No note text retained.")).to_be_visible()
        older = notes.get_by_role("button", name="Older notes")
        older.focus()
        page.keyboard.press("Enter")
        expect(notes.get_by_text("Page 2. Showing 20 of 41 notes.")).to_be_focused()
        older.press("Enter")
        expect(notes.get_by_text("Page 3. Showing 1 of 41 notes.")).to_be_focused()
        expect(notes.get_by_role("listitem")).to_contain_text(observations[-1]["body"])
        page.set_viewport_size({"width": 320, "height": 800})
        assert notes.evaluate("(el) => el.scrollWidth <= el.clientWidth")
        notes.screenshot(path=tmp_path / "panel-handoff-notes-phone.png")
        # Another reviewer removes the intervening page before this tab deletes its final row.
        for record in observations[20:40]:
            client.delete(path + "/" + record["id"]).raise_for_status()
        notes.get_by_role("button", name="Delete observation note").click()
        expect(notes.get_by_text("Page 1. Showing 20 of 20 notes.")).to_be_focused()
        expect(rating).to_have_attribute("aria-pressed", "true")
        expect(composer).to_have_value("Private draft for the decision.")
        expect(notes.get_by_label("Category", exact=True)).to_have_value("decision")

        notes.get_by_role("button", name="Add handoff note").click()
        expect(selector).to_have_value("decision")
        expect(notes.get_by_role("listitem")).to_contain_text("Private draft for the decision.")
        expect(composer).to_be_focused()
        assert not [url for method, url in calls if method == "PUT" and url.path.endswith("/scorecard")]
        created, = client.get(path, params={"category": "decision"}).raise_for_status().json()["items"]
        client.delete(path + "/" + created["id"]).raise_for_status()
        composer.fill("Keep this unsaved note.")
        notes.get_by_role("button", name="Delete decision note").click()
        expect(notes.get_by_text("No handoff notes in this category.")).to_be_focused()
        expect(composer).to_have_value("Keep this unsaved note.")
        expect(composer).to_be_enabled()
        assert len([url for method, url in calls if method == "DELETE" and url.path.endswith(created["id"])]) == 1
        page.get_by_role("button", name="Save scorecard").click()
        expect(page.get_by_text("Scorecard saved.", exact=True)).to_be_visible()
        assert all(parse_qs(url.query).get("include_handoff_notes") == ["false"]
                   for method, url in calls if method in {"GET", "PUT"} and url.path.endswith("/scorecard"))
        assert all(set(parse_qs(url.query)) <= {"category", "limit", "cursor"} for method, url in calls if method == "GET" and url.path == path)


@pytest.mark.parametrize("status", [402, 403])
def test_changed_filters_ignore_late_note_replies_and_hide_denied_content(workspace_url, browser_page, status):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path, _, concern = seed(client, 2)
    page.add_init_script("""
      const original = window.fetch.bind(window);
      window.fetch = async (input, init) => {
        const url = new URL(input instanceof Request ? input.url : input, location.href);
        if (!url.pathname.endsWith("/handoff-notes") || url.searchParams.get("category") !== "concern")
          return original(input, init);
        const response = await original(input, {...init, signal: undefined});
        await response.clone().text();
        await new Promise(resolve => {
          document.documentElement.dataset.heldNotePage = "true";
          document.addEventListener("release-note-page", resolve, {once:true});
        });
        return response;
      };
    """)
    page.goto(f"{workspace_url}/interviews/review/?id={sid}")
    notes = page.get_by_role("region", name="Panel handoff notes")
    selector = notes.get_by_label("Show handoff notes")
    composer = notes.get_by_role("textbox", name="Handoff note")
    expect(notes.get_by_text(concern["body"])).to_be_visible()
    composer.fill("Private unsaved panel note.")
    selector.select_option("concern")
    expect(page.locator("html")).to_have_attribute("data-held-note-page", "true")
    expect(notes.get_by_role("listitem")).to_have_count(0)
    selector.select_option("observation")
    expect(notes.get_by_role("listitem")).to_have_count(2)
    page.evaluate("async () => { document.dispatchEvent(new Event('release-note-page')); await new Promise(requestAnimationFrame); }")
    expect(notes.get_by_text(concern["body"])).to_have_count(0)
    page.evaluate("delete document.documentElement.dataset.heldNotePage")
    selector.select_option("concern")
    expect(page.locator("html")).to_have_attribute("data-held-note-page", "true")
    composer.fill("Private unsaved panel note.")
    page.evaluate("document.dispatchEvent(new Event('release-note-page'))")
    expect(notes.get_by_text(concern["body"])).to_be_visible()
    expect(composer).to_be_focused()
    page.route(f"**{path}?*", lambda route: route.fulfill(status=status, json={"detail": "Denied."}))
    selector.select_option("decision")
    expect(notes.get_by_role("alert")).to_contain_text("no longer have access")
    expect(notes.get_by_role("listitem")).to_have_count(0)
    expect(composer).to_have_count(0)
    page.unroute(f"**{path}?*")
    notes.get_by_role("button", name="Reload handoff notes").click()
    expect(notes.get_by_text("No handoff notes in this category.")).to_be_visible()
    expect(composer).to_have_value("Private unsaved panel note.")


def test_old_scorecard_reply_pages_its_included_notes_without_a_new_endpoint(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, path, observations, _ = seed(client, 21)
        full = client.get(f"/api/sessions/{sid}/scorecard").raise_for_status().json()
    assert "handoff_notes_paged" not in full
    historical = next(note for note in full["handoff_notes"] if note["id"] == observations[-1]["id"])
    historical["created_at"] = "0000-private-historical-time"
    page.route(f"**/sessions/{sid}/scorecard?include_handoff_notes=false", lambda route: route.fulfill(json=full))
    reads = []
    page.on("request", lambda r: reads.append(r.url) if r.method == "GET" and urlsplit(r.url).path == path else None)
    page.goto(f"{workspace_url}/interviews/review/?id={sid}")
    notes = page.get_by_role("region", name="Panel handoff notes")
    notes.get_by_label("Show handoff notes").select_option("observation")
    expect(notes.get_by_role("listitem")).to_have_count(20)
    notes.get_by_role("button", name="Older notes").click()
    expect(notes.get_by_role("listitem")).to_contain_text(observations[-1]["body"])
    expect(notes.get_by_text("Time unavailable")).to_be_visible()
    assert historical["created_at"] not in notes.inner_html()
    assert reads == []


def test_handoff_write_does_not_steal_focus_from_score_editor(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, _, _, _ = seed(client, 1)
    page.add_init_script("""
      const send = window.fetch.bind(window);
      window.fetch = async (input, init) => {
        const response = await send(input, init);
        if (init?.method !== "POST" || !new URL(input instanceof Request ? input.url : input, location.href).pathname.endsWith("/handoff-notes"))
          return response;
        await response.clone().text();
        await new Promise(resolve => {
          document.documentElement.dataset.noteWriteHeld = "true";
          document.addEventListener("finish-note-write", resolve, {once:true});
        });
        return response;
      };
    """)
    page.goto(f"{workspace_url}/interviews/review/?id={sid}")
    notes = page.get_by_role("region", name="Panel handoff notes")
    expect(notes.get_by_role("listitem")).to_have_count(2)
    notes.get_by_role("textbox", name="Handoff note").fill("Held note write.")
    notes.get_by_role("button", name="Add handoff note").press("Enter")
    expect(page.locator("html")).to_have_attribute("data-note-write-held", "true")
    criterion = page.get_by_role("textbox", name="Add criterion", exact=True)
    criterion.fill("Unsaved local criterion")
    page.evaluate("document.dispatchEvent(new Event('finish-note-write'))")
    expect(notes.get_by_text("Held note write.", exact=True)).to_be_visible()
    expect(criterion).to_be_focused()
    criterion.press("End")
    page.keyboard.insert_text("!")
    expect(criterion).to_have_value("Unsaved local criterion!")


def test_failed_handoff_write_respects_keyboard_focus(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid, _, _, _ = seed(client, 1)
    page.add_init_script("""
      const send = window.fetch.bind(window);
      let attempts = 0;
      window.fetch = async (input, init) => {
        const path = new URL(input instanceof Request ? input.url : input, location.href).pathname;
        if (!path.endsWith("/handoff-notes") || init?.method !== "POST") return send(input, init);
        await new Promise(resolve => {
          document.documentElement.dataset.failedWriteHeld = String(++attempts);
          document.addEventListener("fail-note-write", resolve, {once:true});
        });
        return new Response(JSON.stringify({detail: "Fixture temporarily unavailable."}), {status: 503});
      };
    """)
    page.goto(f"{workspace_url}/interviews/review/?id={sid}")
    notes = page.get_by_role("region", name="Panel handoff notes")
    composer = notes.get_by_role("textbox", name="Handoff note")
    add = notes.get_by_role("button", name="Add handoff note")
    error = notes.get_by_role("alert", name="Handoff note change failed")
    composer.fill("Keep this note until saved.")
    add.press("Enter")
    expect(page.locator("html")).to_have_attribute("data-failed-write-held", "1")
    page.evaluate("document.dispatchEvent(new Event('fail-note-write'))")
    expect(error).to_be_focused()
    expect(error).to_contain_text("Fixture temporarily unavailable.")
    expect(composer).to_have_value("Keep this note until saved.")

    add.press("Enter")
    expect(page.locator("html")).to_have_attribute("data-failed-write-held", "2")
    criterion = page.get_by_role("textbox", name="Add criterion", exact=True)
    criterion.fill("Keep keyboard here")
    page.evaluate("document.dispatchEvent(new Event('fail-note-write'))")
    expect(error).to_be_visible()
    expect(criterion).to_be_focused()
    expect(composer).to_have_value("Keep this note until saved.")


@pytest.mark.parametrize("protection", ["anonymized", "legacy_unverified"])
def test_protected_handoff_rows_remain_readable_without_delete_controls(workspace_url, browser_page, protection):
    from api import store
    from api.retention_anonymizer import SessionAnonymizer

    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        sid = client.post("/api/sessions", json={"candidate": "Panel fixture", "role": "Engineer",
                          "policy": "Manuals", "consent": True}).raise_for_status().json()["id"]
        path = f"/api/sessions/{sid}/handoff-notes"
        original = client.post(path, json={"category": "decision", "body": "Private panel explanation."}).raise_for_status().json()
        page.goto(workspace_url + "/interviews/review/?id=" + sid)
        notes = page.get_by_role("region", name="Panel handoff notes")
        remove = notes.get_by_role("button", name="Delete decision note")
        expect(remove).to_be_visible()
        with store.connection(write=True) as db:
            SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=False,
                                           actor_email="retention-fixture@example.test", now_iso=store.timestamp())
            if protection == "legacy_unverified":
                db.execute("DELETE FROM session_anonymizations WHERE session_id=?", (sid,))
                db.execute("INSERT INTO legacy_privacy_holds(session_id) VALUES(?)", (sid,))
        page.reload()
        row = notes.get_by_role("listitem")
        expect(row).to_have_count(1)
        expect(row).to_contain_text(original["author_email"])
        expect(row).to_contain_text("No note text retained.")
        expect(row.locator("time")).to_have_attribute("datetime", original["created_at"])
        expect(remove).to_have_count(0)
        expect(notes.get_by_role("button", name="Add handoff note")).to_have_count(0)
        expect(notes).not_to_contain_text("Private panel explanation.")
