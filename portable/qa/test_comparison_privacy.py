"""Private comparison fields require a fresh opt-in when the candidate selection changes."""
import httpx
from playwright.sync_api import expect


def test_comparison_privacy_after_selection_changes(workspace_url, browser_page):
    page = browser_page
    ids = []
    with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
        for name in ("Ada", "Bea", "Cleo"):
            session = client.post("/api/sessions", json={
                "candidate": name, "role": "Engineer", "policy": "Notes permitted.", "consent": True,
            }).raise_for_status().json()
            ids.append(session["id"])
            route = f"/api/sessions/{session['id']}/answers"
            answer = client.post(route, json={"question": "Explain the approach.", "answer": f"Private excerpt for {name}."}).raise_for_status().json()
            client.patch(f"{route}/{answer['id']}", json={"disposition": "explained", "note": f"Private note for {name}."}).raise_for_status()

    # Delay one genuine opted-in response across navigation, even after React aborts it.
    page.add_init_script("""
        const fetchOriginal = window.fetch.bind(window);
        window.comparisonReads = [];
        window.fetch = async (input, init) => {
          if (new URL(input instanceof Request ? input.url : input, location.href).pathname !== "/api/interviews/compare")
            return fetchOriginal(input, init);
          const query = JSON.parse(init.body);
          window.comparisonReads.push(query);
          if (window.failNextComparison) {
            window.failNextComparison = false;
            return new Response(JSON.stringify({detail: "Fixture comparison unavailable."}), {status: 503});
          }
          if (query.include_excerpts && query.include_notes && !window.releaseComparison) {
            const response = await fetchOriginal(input, {...init, signal: undefined});
            await response.clone().text();
            await new Promise(resolve => {
              window.releaseComparison = resolve;
              document.documentElement.dataset.comparisonHeld = "true";
            });
            return response;
          }
          return fetchOriginal(input, init);
        };
    """)
    url = workspace_url + "/interviews/compare/?ids="
    page.goto(url + ",".join(ids[:2]))
    notes = page.get_by_label("Include interviewer notes")
    excerpts = page.get_by_label("Include answer excerpts")
    print_link = page.get_by_role("link", name="Print or save PDF")
    notes.check()
    expect(page.get_by_text("Private note for Ada.", exact=False)).to_be_visible()
    excerpts.check()
    expect(page.locator("html")).to_have_attribute("data-comparison-held", "true")

    page.get_by_role("button", name="Change interviews").click()
    page.get_by_role("checkbox", name="Ada", exact=False).uncheck()
    page.get_by_role("checkbox", name="Cleo", exact=False).check()
    page.evaluate("window.failNextComparison = true")
    page.get_by_role("button", name="Compare selected (2)").click()
    expect(page.get_by_text("Fixture comparison unavailable.", exact=True)).to_be_visible()
    first_read = page.evaluate("window.comparisonReads.at(-1)")
    assert first_read == {"session_ids": ids[1:], "include_notes": False, "include_excerpts": False}
    page.evaluate("async () => { window.releaseComparison(); await new Promise(requestAnimationFrame); }")
    expect(page.get_by_text("Fixture comparison unavailable.", exact=True)).to_be_visible()
    expect(page.get_by_text("Private note for", exact=False)).to_have_count(0)
    expect(page.get_by_role("button", name="Download Markdown dossier")).to_be_disabled()
    expect(print_link).to_have_attribute("href", "/api/interviews/compare/print?ids=" + ",".join(ids[1:]))
    page.get_by_role("button", name="Retry comparison").click()
    expect(page.get_by_role("heading", name="Candidates (2)")).to_be_visible()
    expect(notes).not_to_be_checked()
    expect(excerpts).not_to_be_checked()
    with page.expect_download() as download:
        page.get_by_role("button", name="Download Markdown dossier").click()
    report = download.value.path().read_text(encoding="utf-8")
    assert "Private note for" not in report and "Private excerpt for" not in report
    notes.check()
    expect(page.get_by_text("Private note for Cleo.", exact=False)).to_be_visible()

    page.evaluate("(url) => history.pushState(null, '', url)", url + ",".join(ids[1:][::-1]))
    expect(notes).not_to_be_checked()
    expect(page.get_by_role("heading", name="Candidates (2)")).to_be_visible()
    assert page.evaluate("window.comparisonReads.at(-1)") == {
        "session_ids": ids[1:][::-1], "include_notes": False, "include_excerpts": False,
    }
    excerpts.check()
    expect(page.get_by_text("Private excerpt for Cleo.", exact=True)).to_be_visible()
    page.go_back()
    expect(page).to_have_url(url + ",".join(ids[1:]))
    expect(excerpts).not_to_be_checked()
    expect(notes).not_to_be_checked()
    expect(page.get_by_role("heading", name="Candidates (2)")).to_be_visible()
    expect(page.get_by_text("Private excerpt for", exact=False)).to_have_count(0)
