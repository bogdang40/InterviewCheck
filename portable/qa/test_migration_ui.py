"""Open a native role export and inspect its duplicate status through the UI."""
import json
from playwright.sync_api import expect


def test_role_file_preview_and_duplicate(workspace_url, browser_page):
    page = browser_page
    page.goto(workspace_url + "/#roles")
    page.get_by_text("Import a role file", exact=True).click()
    contents = {"format": "interviewcheck.role", "version": 1, "role": {
        "workspaceID": "fixture-role", "name": "Acoustic engineer", "company": "Example",
        "jobDescription": "Measure microphone response.",
        "plannedQuestions": [{"text": "How do you calibrate the microphone?", "strongAnswer": "Use a reference."}],
    }}
    fixture = {"name": "role.json", "mimeType": "application/json",
               "buffer": json.dumps(contents).encode()}
    upload = page.get_by_label("Native or portable role file")
    upload.set_input_files(fixture)
    expect(page.get_by_text("1 planned question.", exact=True)).to_be_visible()
    page.get_by_role("button", name="Import role", exact=True).click()
    expect(page.get_by_text("Role available in the library.")).to_be_visible()
    upload.set_input_files(fixture)
    expect(page.get_by_text("This role is already in the library.")).to_be_visible()
    expect(page.get_by_role("button", name="Import role", exact=True)).to_have_count(0)
