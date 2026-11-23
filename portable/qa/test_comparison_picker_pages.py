from datetime import datetime, timedelta, timezone
import re
from urllib.parse import parse_qs, urlsplit
from uuid import uuid4

import httpx
from playwright.sync_api import expect


def seed_archive(client):
    from api import store

    ids = []
    for index in range(53):
        candidate = "Same candidate" if index < 52 else "Different candidate"
        response = client.post("/api/sessions", json={
            "role": "Engineer", "candidate": candidate, "policy": "Manual", "consent": True,
        })
        ids.append(response.raise_for_status().json()["id"])
    start = datetime(2025, 1, 1, 12, tzinfo=timezone.utc)
    with store.connection(write=True) as db:
        db.executemany("UPDATE sessions SET created_at=? WHERE id=?",
                       [((start + timedelta(days=i)).isoformat(), sid) for i, sid in enumerate(ids)])
    return ids


def box(picker, sid):
    return picker.get_by_role("checkbox", name=re.compile(sid[:8]))


def test_picker_keeps_order_labels_and_limits_across_archive_pages(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        ids = seed_archive(client)
    page.goto(f"{workspace_url}/interviews/compare/")
    picker = page.get_by_role("region", name="Select interviews")
    search = picker.get_by_role("searchbox", name="Filter active archive")
    search.fill("Same candidate")
    expect(picker.get_by_role("status")).to_have_text("1 to 50 of 52 interviews")
    expect(box(picker, ids[0])).to_have_count(0)
    picker.get_by_role("button", name="Next interviews").press("Enter")
    expect(picker.get_by_role("status")).to_have_text("51 to 52 of 52 interviews")
    expect(picker.get_by_role("status")).to_be_focused()
    box(picker, ids[0]).check()
    selected = picker.get_by_role("list", name="Selected interviews in comparison order")
    expect(selected.get_by_role("listitem")).to_contain_text(["Same candidate"])
    expect(selected).to_contain_text("Engineer")
    expect(selected).to_contain_text("2025")
    picker.get_by_role("button", name="Previous interviews").click()
    for sid in ids[47:52]:
        box(picker, sid).check()
    expect(box(picker, ids[46])).to_be_disabled()
    expect(box(picker, ids[47])).to_be_enabled()
    selected.get_by_role("button", name=re.compile(ids[47])).press("Enter")
    expect(box(picker, ids[46])).to_be_enabled()
    for sid in ids[48:51]:
        box(picker, sid).uncheck()
    expect(selected.get_by_role("listitem")).to_have_count(2)
    search.fill("Different")
    expect(picker.get_by_role("status")).to_have_text("1 to 1 of 1 interviews")
    expect(selected.get_by_role("button", name=re.compile(ids[0]))).to_be_visible()
    expect(selected.get_by_role("button", name=re.compile(ids[51]))).to_be_visible()
    picker.get_by_role("button", name="Compare selected (2)").click()
    expect(page.get_by_role("heading", name="Candidates (2)")).to_be_visible()
    assert parse_qs(urlsplit(page.url).query)["ids"] == [f"{ids[0]},{ids[51]}"]
    page.get_by_label("Include interviewer notes").check()
    page.get_by_role("button", name="Change interviews").click()
    selected.get_by_role("button", name=re.compile(ids[0])).click()
    picker.get_by_role("button", name="Cancel").click()
    expect(page.get_by_role("button", name="Change interviews")).to_be_focused()
    expect(page.get_by_label("Include interviewer notes")).to_be_checked()
    assert parse_qs(urlsplit(page.url).query)["ids"] == [f"{ids[0]},{ids[51]}"]


def test_picker_suppresses_stale_results_retries_and_clamps(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        ids = seed_archive(client)
        page.add_init_script("""(() => {
          const original = window.fetch.bind(window);
          window.fetch = async (input, init) => {
            const url = new URL(typeof input === "string" ? input : input.url, location.href);
            if (url.pathname.endsWith("/interviews/feed") && url.searchParams.get("page") === "2") {
              if (window.failPickerPage) {
                window.failPickerPage = false;
                return new Response(JSON.stringify({detail: "Fixture page unavailable."}), {status: 503});
              }
              if (window.holdPickerPage) {
                window.holdPickerPage = false;
                const response = await original(input, init);
                const text = await response.text();
                await new Promise(resolve => {
                  window.releasePickerPage = resolve;
                  document.documentElement.dataset.pickerPageHeld = "true";
                });
                return new Response(text, {status: 200, headers: {"Content-Type": "application/json"}});
              }
            }
            return original(input, init);
          };
        })()""")
        missing = str(uuid4())
        page.goto(f"{workspace_url}/interviews/compare/?ids={missing}")
        picker = page.get_by_role("region", name="Select interviews")
        search = picker.get_by_role("searchbox", name="Filter active archive")
        picker.get_by_role("button", name=re.compile(missing)).click()
        expect(search).to_be_focused()
        search.fill("Same")
        expect(picker.get_by_role("status")).to_have_text("1 to 50 of 52 interviews")
        box(picker, ids[51]).check()
        page.evaluate("window.holdPickerPage = true")
        picker.get_by_role("button", name="Next interviews").click()
        expect(page.locator("html")).to_have_attribute("data-picker-page-held", "true")
        expect(picker.get_by_role("checkbox")).to_have_count(0)
        search.fill("Different")
        expect(picker.get_by_role("status")).to_have_text("1 to 1 of 1 interviews")
        page.evaluate("async () => { window.releasePickerPage(); await new Promise(requestAnimationFrame) }")
        expect(picker.get_by_role("checkbox")).to_have_count(1)
        expect(box(picker, ids[52])).to_be_visible()
        search.fill("Same")
        expect(picker.get_by_role("status")).to_have_text("1 to 50 of 52 interviews")
        page.evaluate("window.failPickerPage = true")
        picker.get_by_role("button", name="Next interviews").click()
        expect(picker.get_by_text("Fixture page unavailable.")).to_be_visible()
        expect(picker.get_by_role("checkbox")).to_have_count(0)
        expect(picker.get_by_role("button", name="Previous interviews")).to_be_enabled()
        expect(picker.get_by_role("button", name=re.compile(ids[51]))).to_be_visible()
        for sid in ids[:2]:
            client.post(f"/api/sessions/{sid}/trash").raise_for_status()
        picker.get_by_role("button", name="Retry", exact=True).click()
        expect(picker.get_by_role("status")).to_have_text("1 to 50 of 50 interviews")
        expect(picker.get_by_role("button", name="Previous interviews")).to_have_count(0)
        expect(box(picker, ids[51])).to_be_checked()


def test_reopened_picker_keeps_draft_choices_without_reusing_previous_rows(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        ids = [client.post("/api/sessions", json={
            "candidate": name, "role": "Engineer", "policy": "Manual", "consent": True,
        }).raise_for_status().json()["id"] for name in ("One", "Two", "Previously present")]
        page.add_init_script("""(() => {
          const original = window.fetch.bind(window);
          window.fetch = async (input, init) => {
            const url = new URL(typeof input === "string" ? input : input.url, location.href);
            const response = await original(input, init);
            if (!window.holdReopenedPicker || !url.pathname.endsWith("/interviews/feed")) return response;
            window.holdReopenedPicker = false;
            const body = await response.text();
            await new Promise(resolve => {
              window.releaseReopenedPicker = resolve;
              document.documentElement.dataset.reopenedPickerHeld = "true";
            });
            return new Response(body, {headers: {"Content-Type": "application/json"}});
          };
        })()""")
        page.goto(f"{workspace_url}/interviews/compare/?ids={ids[0]},{ids[1]}")
        open_picker = page.get_by_role("button", name="Change interviews")
        open_picker.click()
        picker = page.get_by_role("region", name="Select interviews")
        box(picker, ids[2]).check()
        page.get_by_role("button", name="Hide selector").click()
        client.post(f"/api/sessions/{ids[2]}/trash").raise_for_status()
        page.evaluate("window.holdReopenedPicker = true")
        open_picker.click()
        expect(page.locator("html")).to_have_attribute("data-reopened-picker-held", "true")
        expect(picker.get_by_role("checkbox")).to_have_count(0)
        chips = picker.get_by_role("list", name="Selected interviews in comparison order")
        expect(chips.get_by_role("listitem")).to_contain_text(["One", "Two", "Previously present"])
        page.evaluate("window.releaseReopenedPicker()")
        expect(picker.get_by_role("checkbox")).to_have_count(2)
        expect(box(picker, ids[2])).to_have_count(0)
        chips.get_by_role("button", name=re.compile(ids[2])).click()
        expect(picker.get_by_role("button", name="Compare selected (2)")).to_be_enabled()
