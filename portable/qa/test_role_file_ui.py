import json

from playwright.sync_api import expect


def test_download_import_and_duplicate_role_kit(workspace_url, browser_page, tmp_path, monkeypatch):
    from api import store

    page = browser_page
    page.set_viewport_size({"width": 320, "height": 780})
    template = {"name": "Rôle réseau", "description": "Fictional role", "policy": "Manual permitted",
                "questions": ["First?\nExplain.", "First?\nExplain."], "permitted_sources": [{"label": "Guide", "text": "ΔT"}]}
    source = page.request.post(workspace_url + "/api/roles", data=template, headers={"X-InterviewCheck": "1"}).json()
    page.goto(workspace_url + "/roles/")
    page.get_by_text("Role file and copy", exact=True).click()
    with page.expect_download() as pending:
        page.get_by_role("button", name="Export role file").click()
    download = pending.value
    assert download.suggested_filename == "role-" + source["id"] + ".json"
    file = tmp_path / download.suggested_filename
    download.save_as(file)
    assert json.loads(file.read_bytes())["role"] == {**template, "id": source["id"]}
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    page.screenshot(path=tmp_path / "role-file-actions-phone.png", full_page=True)

    destination = tmp_path / "fresh.sqlite"
    store.initialize(destination)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(destination))
    page.reload()
    expect(page.get_by_text("No roles saved")).to_be_visible()
    page.get_by_text("Import a role file", exact=True).click()
    upload = page.get_by_label("Native or portable role file")
    upload.set_input_files(file)
    page.get_by_role("button", name="Import role", exact=True).click()
    expect(page.get_by_text("Role available in the library.")).to_be_visible()
    upload.set_input_files(file)
    expect(page.get_by_text("This role is already in the library.")).to_be_visible()
    page.get_by_text("Role file and copy", exact=True).click()
    page.get_by_role("button", name="Duplicate latest saved role").click()
    page.get_by_role("button", name="Edit copy").click()
    page.get_by_role("textbox", name="Role name", exact=True).fill("Copied template")
    page.get_by_role("button", name="Save role").click()
    expect(page.get_by_text("Copied template", exact=True)).to_be_visible()
    rows = page.request.get(workspace_url + "/api/roles").json()
    copy, = [row for row in rows if row["id"] != source["id"]]
    assert copy["policy"] == template["policy"] and copy["permitted_sources"] == template["permitted_sources"]
    assert copy["questions"] == template["questions"]
    assert [row for row in rows if row["id"] == source["id"]] == [source]
