"""Verify the actual downloaded role guide on a disconnected browser."""
from pathlib import Path
import os
import re
import shutil
import subprocess

from playwright.sync_api import expect


def test_offline_guide_uses_the_displayed_revision_and_selected_fields(workspace_url, browser_page, qa_browser, tmp_path):
    page = browser_page
    headers = {"X-InterviewCheck": "1"}
    role = {"name": "Infrastructure panel", "description": "Private description marker",
            "questions": ["What happens on failover?", "What happens on failover?", "Explain <sample> & Δ."],
            "policy": "Use the local handbook.", "permitted_sources": [{"label": "Private source", "text": "Handbook marker"}],
            "rubric": [{"id": "test", "criterion": "Private criterion", "weight": 3,
                        "expected_signals": ["Tested the recovery"], "red_flags": ["No restore point"]}],
            "change_note": "Private history marker"}
    role["questions"].extend(f"Review case {i}. Which observation would change your incident response? Explain your reasoning."
                             for i in range(1, 41))
    role["permitted_sources"][0]["text"] += "\nFinal material marker"
    created = page.request.post(workspace_url + "/api/roles", data=role, headers=headers)
    assert created.status == 201
    saved = created.json()
    endpoint = workspace_url + "/api/roles/" + saved["id"]
    updated = page.request.put(endpoint, data={**role, "version": saved["version"], "questions": ["Current revision question"],
                               "policy": "Later policy", "rubric": [], "permitted_sources": []}, headers=headers)
    assert updated.ok and updated.json()["version_number"] == 2

    page.set_viewport_size({"width": 320, "height": 780})
    page.goto(workspace_url + "/roles/")
    page.get_by_role("button", name="Version history for Infrastructure panel").click()
    opener = page.get_by_role("button", name="Preview interviewer guide for revision 1")
    opener.click()
    dialog = page.get_by_role("dialog", name="Offline interviewer guide")
    preview = dialog.get_by_role("region", name="Guide preview")
    expect(preview.locator("ol li")).to_have_text(role["questions"])
    expect(preview).not_to_contain_text("Private criterion")
    screenshot_dir = Path(os.getenv("INTERVIEWCHECK_E2E_SCREENSHOT_DIR", tmp_path))
    screenshot_dir.mkdir(exist_ok=True, parents=True)
    page.screenshot(path=screenshot_dir / "role-guide-preview.png")
    assert dialog.evaluate("e => e.scrollWidth <= e.clientWidth + 1")

    def export_to(stem):
        with page.expect_download() as event:
            dialog.get_by_role("button", name="Download guide").click()
        assert event.value.suggested_filename == "interviewer-guide-v1.html"
        path = tmp_path / (stem + ".html")
        event.value.save_as(path)
        return path

    default = export_to("questions")
    html = default.read_text(encoding="utf-8")
    for excluded in ("Private source", "Handbook marker", "Private criterion", "Private description marker",
                     "Private history marker", "Current revision question", saved["id"]):
        assert excluded not in html
    assert "&lt;sample&gt; &amp; Δ" in html
    assert 'charset="utf-8"' in html
    dialog.get_by_label("Grading rubric", exact=False).check()
    expect(preview).to_contain_text("Private criterion")
    expect(preview).not_to_contain_text("Handbook marker")
    rubric_only = export_to("rubric").read_text(encoding="utf-8")
    assert "Tested the recovery" in rubric_only and "No restore point" in rubric_only and "Private source" not in rubric_only
    dialog.get_by_label("Permitted materials", exact=False).check()
    expect(preview).to_contain_text("Handbook marker")
    rich = export_to("full")
    dialog.get_by_label("Permitted materials", exact=False).uncheck()
    expect(preview).not_to_contain_text("Handbook marker")
    page.keyboard.press("Escape")
    expect(dialog).to_have_count(0)
    expect(opener).to_be_focused()
    opener.click()
    expect(dialog.get_by_label("Grading rubric", exact=False)).not_to_be_checked()
    dialog.get_by_role("button", name="Close guide").click()

    page.get_by_text("Role file and copy", exact=True).click()
    page.get_by_role("button", name="Preview interviewer guide", exact=True).click()
    expect(preview).to_contain_text("Revision 2")
    expect(preview).to_contain_text("Current revision question")
    expect(preview).to_contain_text("Later policy")
    expect(dialog.get_by_label("Grading rubric", exact=False)).to_be_disabled()
    page.goto(workspace_url + "/roles/?role=" + saved["id"])
    historical = page.get_by_role("button", name="Preview interviewer guide for revision 1")
    historical.click()
    expect(preview).to_contain_text("Use the local handbook.")
    assert export_to("direct").read_bytes() == default.read_bytes()
    page.keyboard.press("Escape")
    expect(historical).to_be_focused()
    assert page.request.get(workspace_url + "/api/sessions").json() == []

    with qa_browser.new_context(java_script_enabled=False, offline=True, viewport={"width": 320, "height": 780}) as context:
        offline = context.new_page()
        network = []
        offline.on("request", lambda request: network.append(request.url) if request.url.startswith(("http:", "https:")) else None)
        offline.goto(rich.as_uri())
        expect(offline.get_by_role("heading", level=1)).to_have_text(role["name"])
        expect(offline.get_by_role("heading", level=2)).to_have_text(["Resource policy", "Planned questions", "Grading rubric", "Permitted materials"])
        expect(offline.get_by_role("list").first.locator("li")).to_have_text(role["questions"])
        expect(offline.get_by_text("Final material marker", exact=False)).to_be_visible()
        assert offline.locator("script, link, iframe, form, img, object, embed").count() == 0
        assert offline.evaluate("document.documentElement.scrollWidth <= innerWidth")
        offline.screenshot(path=screenshot_dir / "offline-guide-phone.png")
        offline.emulate_media(media="print")
        for file in (rich, default):
            offline.goto(file.as_uri())
            output = screenshot_dir / (file.stem + "-role-guide.pdf")
            pdf = offline.pdf(path=output, format="A4", margin={"top": "15mm", "bottom": "15mm", "left": "15mm", "right": "15mm"})
            assert len(re.findall(rb"/Type\s*/Page\b", pdf)) >= 2
            if shutil.which("pdftotext"):
                printed = subprocess.check_output(["pdftotext", "-layout", str(output), "-"]).decode("utf-8")
                assert "What happens on failover?" in printed and "Review case 40" in printed
                for marker in ("Final material marker", "Private criterion"):
                    assert (marker in printed) == (file == rich)
        assert not network



def test_history_request_failure_cannot_show_a_different_role(workspace_url, browser_page):
    page = browser_page
    for name in ("Engineer North", "Engineer South"):
        response = page.request.post(workspace_url + "/api/roles", headers={"X-InterviewCheck": "1"},
                                     data={"name": name, "questions": [name + " private question"]})
        assert response.ok
        if name == "Engineer South":
            south_id = response.json()["id"]
    page.goto(workspace_url + "/roles/")
    page.get_by_role("button", name="Version history for Engineer North").click()
    expect(page.get_by_role("button", name="Preview interviewer guide for revision 1")).to_be_visible()
    page.route("**/roles/" + south_id + "/versions", lambda route: route.fulfill(status=503, json={"detail": "History unavailable"}))
    page.get_by_role("button", name="Version history for Engineer South").click()
    south = page.get_by_role("region", name="Version history for Engineer South")
    expect(south.get_by_role("alert")).to_contain_text("History unavailable")
    expect(south.get_by_role("button", name="Preview interviewer guide for revision 1")).to_have_count(0)
    expect(south.get_by_role("button", name="Restore version")).to_have_count(0)



def test_late_revision_reply_stays_with_its_role(workspace_url, browser_page):
    page = browser_page
    roles = []
    for name in ("First role", "Second role"):
        saved = page.request.post(workspace_url + "/api/roles", headers={"X-InterviewCheck": "1"},
                                  data={"name": name, "questions": [name + " question"]})
        assert saved.ok
        roles.append(saved.json())
    first = roles[0]["id"]
    page.add_init_script("""
      const fetchActual = window.fetch.bind(window);
      window.fetch = async (...args) => {
        const response = await fetchActual(...args);
        if (new URL(response.url).pathname === '/api/roles/' + '%s' + '/versions')
          await new Promise(done => {
            window.releaseFirstHistory = done;
            document.documentElement.dataset.firstHistoryPending = "true";
          });
        return response;
      };
    """ % first)
    page.goto(workspace_url + "/roles/")
    page.get_by_role("button", name="Version history for First role").click()
    expect(page.locator("html")).to_have_attribute("data-first-history-pending", "true")
    page.get_by_role("button", name="Version history for Second role").click()
    second = page.get_by_role("region", name="Version history for Second role")
    opener = second.get_by_role("button", name="Preview interviewer guide for revision 1")
    expect(opener).to_be_visible()
    page.evaluate("window.releaseFirstHistory()")
    opener.click()
    preview = page.get_by_role("region", name="Guide preview")
    expect(preview).to_contain_text("Second role question")
    expect(preview).not_to_contain_text("First role question")
