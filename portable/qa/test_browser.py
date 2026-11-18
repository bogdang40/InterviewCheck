"""Use the public browser controls for a consented transcript review."""
import csv
import re
import os
import sqlite3
from contextlib import closing
from uuid import uuid4

from playwright.sync_api import expect


def test_notice_import_review_and_download(workspace_url, browser_page, tmp_path):
    page = browser_page
    page.goto(workspace_url)
    expect(page.get_by_role("heading", name="Interview workspace")).to_be_visible()
    page.get_by_role("button", name="New interview", exact=True).first.click()
    page.get_by_label("Candidate", exact=True).fill("Browser fixture")
    page.get_by_label("Role", exact=True).fill("Storage engineer")
    page.get_by_label("Assistance policy").fill("The operator manual is permitted.")
    page.get_by_role("button", name="Start interview").click()
    expect(page.get_by_role("heading", name="New interview")).to_be_visible()
    page.get_by_role("checkbox", name=re.compile("candidate knows")).check()
    page.get_by_role("button", name="Start interview").click()
    expect(page.get_by_role("heading", name="Browser fixture")).to_be_visible()

    question = "Which measurement would you take first?"
    answer = "Measure the amber receiver against three cold baselines before comparing the packet counts."
    vtt = (
        f"WEBVTT\n\n00:00:01.000 --> 00:00:05.000\n<v Interviewer>{question}</v>\n\n"
        f"00:00:06.000 --> 00:00:12.000\n<v Candidate>{answer}</v>\n"
    )
    page.get_by_text("Import a meeting transcript", exact=True).click()
    page.locator('input[type="file"][accept*="vtt"]').set_input_files({
        "name": "synthetic.vtt", "mimeType": "text/vtt", "buffer": vtt.encode(),
    })
    page.get_by_label("Candidate speaker").select_option("Candidate")
    page.get_by_role("button", name="Use this exchange").click()
    expect(page.get_by_role("textbox", name="Question", exact=True)).to_have_value(question)
    expect(page.get_by_label("Candidate answer")).to_have_value(answer)
    page.get_by_role("button", name="Add source").click()
    page.get_by_label("Source name").fill("Reference fixture")
    page.get_by_label("Source passage").fill(answer)
    page.get_by_role("button", name="Save and compare").click()
    expect(page.get_by_text("Passage match", exact=True)).to_be_visible()
    page.get_by_label("Review outcome").select_option("explained")
    page.get_by_label("Interviewer note").fill("Candidate demonstrated the measurement.")
    page.get_by_role("button", name="Save review").click()
    expect(page.get_by_text(re.compile("Review saved"))).to_be_visible()
    with page.expect_download() as download:
        page.get_by_role("link", name="Export report").click()
    output = tmp_path / "report.md"
    download.value.save_as(output)
    report = output.read_text(encoding="utf-8")
    assert "Candidate demonstrated the measurement." in report
    assert "Reference fixture" in report
    assert answer in report

    with page.expect_popup() as popup:
        page.get_by_role("link", name="Print or save PDF").click()
    printable = popup.value
    expect(printable.get_by_text("Candidate demonstrated the measurement.", exact=True)).to_be_visible()
    assert printable.pdf(path=tmp_path / "report.pdf").startswith(b"%PDF-")
    printable.close()

    page.goto(workspace_url + "/#interviews")
    with page.expect_download() as archive:
        page.get_by_role("link", name="Export archive CSV").click()
    archive.value.save_as(tmp_path / "archive.csv")
    with (tmp_path / "archive.csv").open(encoding="utf-8-sig", newline="") as stream:
        row, = list(csv.DictReader(stream))
    assert row["Candidate"] == "Browser fixture"
    assert row["Interviewer note"] == "Candidate demonstrated the measurement."

    page.goto(workspace_url)
    page.get_by_role("button", name=re.compile("Browser fixture")).click()
    expect(page.get_by_label("Interviewer note")).to_have_value("Candidate demonstrated the measurement.")
    expect(page.get_by_label("Review outcome")).to_have_value("explained")
    page.get_by_role("button", name="Edit exchange").click()
    page.get_by_label("Permitted material").check()
    page.get_by_role("button", name="Save and compare").click()
    expect(page.get_by_text("Limited evidence", exact=True)).to_be_visible()
    expect(page.get_by_label("Review outcome")).to_have_value("pending")
    page.get_by_label("Review outcome").select_option("disclosed")
    page.get_by_label("Interviewer note").fill("")
    page.get_by_role("button", name="Save review").click()
    assert not page.get_by_label("Interviewer note").evaluate("(field) => field.validity.valid")
    page.get_by_label("Interviewer note").fill("Candidate reported using a reference during the call.")
    page.get_by_role("button", name="Save review").click()
    expect(page.get_by_text(re.compile("Review saved"))).to_be_visible()
    page.reload()
    expect(page.get_by_label("Review outcome")).to_have_value("disclosed")


def test_csv_prepares_session_without_recording_notice(workspace_url, browser_page):
    page = browser_page
    page.goto(workspace_url)
    page.get_by_role("link", name="Connections", exact=True).click()
    page.get_by_label("Import candidates from CSV").set_input_files({
        "name": "test.csv", "mimeType": "text/csv",
        "buffer": b'candidate,role\r\n"Lee, Example",Database Engineer\r\n',
    })
    page.get_by_role("button", name="Select", exact=True).click()
    page.get_by_role("button", name="Prepare interview", exact=True).click()
    expect(page.get_by_label("Candidate", exact=True)).to_have_value("Lee, Example")
    expect(page.get_by_label("Role", exact=True)).to_have_value("Database Engineer")
    expect(page.get_by_role("checkbox", name=re.compile("candidate knows"))).not_to_be_checked()


def test_archive_without_notice_has_no_capture_controls(workspace_url, browser_page):
    # This shape can only arise from a native migration. Use the suite's temporary DB.
    key = str(uuid4())
    with closing(sqlite3.connect(os.environ["INTERVIEWCHECK_DB"])) as db, db:
        db.execute("""INSERT INTO sessions (id,candidate,role,policy,consent,created_at,legacy)
                      VALUES (?,?,?,?,?,?,?)""",
                   (key, "Archived candidate", "Operator", "Unknown", 0, "2026-01-03T12:00:00Z", "{}"))
    page = browser_page
    page.goto(workspace_url + "/#session/" + key)
    expect(page.get_by_role("heading", name="Archived candidate")).to_be_visible()
    expect(page.get_by_text(re.compile("no recorded notice"))).to_be_visible()
    expect(page.get_by_text("Capture audio", exact=True)).to_have_count(0)
    expect(page.get_by_role("button", name="Add exchange")).to_have_count(0)
    expect(page.get_by_role("textbox", name="Candidate answer")).to_have_count(0)
