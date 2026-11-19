"""Tier 4 scenarios: Consented Live Capture, Transcript Batch Import, Lineage & Brief Privacy."""
import csv
import io
import json
import re

import pytest
from playwright.sync_api import expect

from e2e_suite.harness import (
    ConsoleErrorCollector,
    DESKTOP_VIEWPORT,
    assert_no_horizontal_overflow,
    install_audio_mock,
    signup_user,
)

ADMIN_EMAIL = "admin-t4-life@example.test"
BOOTSTRAP_SECRET = "t4-life-bootstrap-1234"
ADMIN_PASS = "Synthetic-T4-Life-Pass"


def _open_capture_context(browser):
    ctx = browser.new_context(
        viewport=DESKTOP_VIEWPORT,
        reduced_motion="reduce",
        accept_downloads=True,
    )
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    page.set_default_navigation_timeout(30_000)
    install_audio_mock(page)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    return ctx, page, collector


def _sign_in_account(page, base_url: str) -> None:
    page.goto(base_url + "/account/", wait_until="domcontentloaded")
    page.get_by_label("Operator email").fill(ADMIN_EMAIL)
    page.get_by_label("Password", exact=True).fill(ADMIN_PASS)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(ADMIN_EMAIL)).to_be_visible()


@pytest.mark.tier4
def test_scenario_b_consented_live_interview_mocked_audio_review_and_export(e2e_workspace, e2e_browser, tmp_path):
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as admin:
        signup_user(admin, email=ADMIN_EMAIL, password=ADMIN_PASS, admin_secret=BOOTSTRAP_SECRET)
        dg = admin.post(
            "/api/admin/models",
            json={
                "slug": "t4-live-deepgram",
                "display_name": "T4 Live Deepgram",
                "provider": "deepgram",
                "capability": "transcription",
                "model_id": "nova-2",
                "apiKey": "sk-t4-live-deepgram-1234",
                "enabled": True,
                "is_default": True,
            },
        )
        assert dg.status_code == 201

    ctx, page, collector = _open_capture_context(e2e_browser)
    ws_chunks: list[int] = []
    part1 = "Idempotent retries pair a client key"
    part2 = "with server deduplication records."

    def handle_live_ws(ws):
        def on_message(msg):
            if msg == "send-audio-to-deepgram":
                ws.send(json.dumps({"ready": True}))
            elif isinstance(msg, bytes):
                ws_chunks.append(len(msg))
                if len(ws_chunks) == 1:
                    ws.send(json.dumps({"text": part1}))
            elif msg == "finish":
                ws.send(json.dumps({"text": part2}))
                ws.close(code=1000)

        ws.on_message(on_message)

    page.route_web_socket("**/api/integrations/live", handle_live_ws)
    try:
        _sign_in_account(page, e2e_workspace.base_url)

        # Create role with planned questions.
        page.goto(e2e_workspace.base_url + "/roles/", wait_until="domcontentloaded")
        page.get_by_role("button", name="Add role").click()
        page.get_by_label("Role name").fill("Distributed Systems Architect")
        page.get_by_label("Description").fill("Fault-tolerant backend systems.")
        page.get_by_label("Planned questions, one per line").fill("How do you design idempotent retries?")
        page.get_by_role("button", name="Save role").click()
        expect(page.locator(".role-row").get_by_text("Distributed Systems Architect", exact=True)).to_be_visible()

        # Prepare and start consented interview.
        page.locator(".role-row").filter(has_text="Distributed Systems Architect").get_by_role("button", name="Prepare").click()
        expect(page).to_have_url(re.compile(r"/interviews/new/?$"))
        page.get_by_label("Candidate", exact=True).fill("Samira Chen")
        page.get_by_label("Assistance policy").fill("Closed-book live technical discussion.")
        page.get_by_label(re.compile(r"confirmed that the candidate knows")).check()
        page.get_by_role("button", name="Start interview").click()
        expect(page).to_have_url(re.compile(r"/interviews/review/\?id=[0-9a-f-]+"))
        review_url = page.url

        # Select planned question slot and run mocked live microphone capture.
        page.get_by_role("combobox", name="Planned question", exact=True).select_option("1")
        expect(page.get_by_role("textbox", name="Question", exact=True)).to_have_value(
            "How do you design idempotent retries?"
        )
        page.get_by_text("Capture audio", exact=True).click()
        page.get_by_role("checkbox", name=re.compile("agreed to send")).check()
        page.get_by_label("Audio source").select_option("microphone")
        page.get_by_role("button", name="Start transcription").click()

        expect(page.get_by_label("Candidate excerpt")).to_have_value(part1, timeout=10_000)
        assert ws_chunks and all(size > 0 for size in ws_chunks)
        page.get_by_role("button", name="Stop capture").click()
        expect(page.get_by_label("Candidate excerpt")).to_have_value(f"{part1} {part2}")
        page.get_by_role("button", name="Use this excerpt").click()
        expect(page.get_by_label("Candidate answer")).to_have_value(f"{part1} {part2}")

        # Add comparison reference source and save exchange.
        page.get_by_role("button", name="Add source").click()
        page.get_by_label("Source name").fill("Idempotency Spec")
        page.get_by_label("Source passage").fill(
            "Idempotent retries pair a client key with server deduplication records."
        )
        page.get_by_role("button", name="Save and compare").click()

        expect(page.get_by_role("heading", name="How do you design idempotent retries?")).to_be_visible()
        expect(page.get_by_role("heading", name="Comparison result")).to_be_visible()

        # Record review disposition and interviewer note.
        page.get_by_role("combobox", name=re.compile(r"^Review outcome")).select_option("explained")
        note_text = "Candidate articulated idempotency key lifecycle cleanly."
        page.get_by_label("Interviewer note").fill(note_text)
        page.get_by_role("button", name="Save review").click()
        expect(page.get_by_text("Review saved")).to_be_visible()
        assert_no_horizontal_overflow(page)

        # Export Markdown report and verify printable CSP view.
        md_path = tmp_path / "interview-report.md"
        with page.expect_download() as md_dl:
            page.get_by_role("link", name="Export report").click()
        md_dl.value.save_as(str(md_path))
        md_body = md_path.read_text(encoding="utf-8")
        assert "Samira Chen" in md_body
        assert "How do you design idempotent retries?" in md_body
        assert part1 in md_body
        assert note_text in md_body

        session_id = review_url.split("id=")[-1].split("&")[0]
        print_resp = page.goto(f"{e2e_workspace.base_url}/api/sessions/{session_id}/print", wait_until="domcontentloaded")
        assert print_resp is not None and print_resp.status == 200
        assert "content-security-policy" in {k.lower() for k in print_resp.headers}
        expect(page.get_by_role("button", name="Print or save PDF")).to_be_visible()

        # Export archive CSV from /interviews/.
        page.goto(e2e_workspace.base_url + "/interviews/", wait_until="domcontentloaded")
        csv_path = tmp_path / "archive.csv"
        with page.expect_download() as csv_dl:
            page.get_by_role("link", name="Export archive CSV").click()
        csv_dl.value.save_as(str(csv_path))
        rows = list(csv.DictReader(io.StringIO(csv_path.read_text(encoding="utf-8-sig"))))
        assert len(rows) == 1
        assert rows[0]["Candidate"] == "Samira Chen"
        assert rows[0]["Interviewer disposition"] == "explained"
        assert rows[0]["Interviewer note"] == note_text
        collector.assert_clean()
    finally:
        ctx.close()


@pytest.mark.tier4
def test_scenario_e_transcript_batch_import_followup_lineage_and_brief_privacy(e2e_workspace, e2e_browser, tmp_path):
    ctx = e2e_browser.new_context(viewport=DESKTOP_VIEWPORT, reduced_motion="reduce", accept_downloads=True)
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    page.set_default_navigation_timeout(30_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)

    vtt_turns = [
        ("Interviewer", "How do you prevent split-brain in Raft?"),
        ("Candidate", "Use strict majority quorums for leader election."),
        ("Interviewer", "This prompt is interrupted by observer."),
        ("Observer", "Quick audio check."),
        ("Candidate", "Unattributed continuation."),
        ("Interviewer", "When do you trigger log compaction?"),
        ("Candidate", "Compact once committed entries cross a byte threshold."),
        ("Interviewer", "How do you validate snapshot integrity?"),
        ("Candidate", "Verify CRC checksums before installing snapshot state."),
    ]
    vtt_blocks = [
        f"00:00:{i * 2:02}.000 --> 00:00:{i * 2 + 1:02}.000\n<v {speaker}>{text}</v>"
        for i, (speaker, text) in enumerate(vtt_turns)
    ]
    vtt_bytes = ("WEBVTT\n\n" + "\n\n".join(vtt_blocks)).encode("utf-8")

    try:
        with e2e_workspace.client() as c:
            role = c.post(
                "/api/roles",
                json={
                    "name": "PrivateRoleName",
                    "description": "Consensus reliability.",
                    "questions": ["Explain Raft leader election.", "Explain snapshot compaction."],
                },
            )
            role.raise_for_status()
            session = c.post(
                "/api/sessions",
                json={
                    "candidate": "PrivateCandidateName",
                    "role": "PrivateRoleName",
                    "role_id": role.json()["id"],
                    "policy": "Closed book.",
                    "consent": True,
                },
            )
            session.raise_for_status()
            sid = session.json()["id"]

        # Import selected exchanges from WebVTT transcript.
        page.goto(f"{e2e_workspace.base_url}/interviews/review/?id={sid}", wait_until="domcontentloaded")
        page.get_by_text("Import transcript exchanges", exact=True).click()
        page.get_by_label("Conversation WebVTT file").set_input_files(
            {"name": "session.vtt", "mimeType": "text/vtt", "buffer": vtt_bytes}
        )
        page.get_by_label("Candidate in transcript").select_option("Candidate")
        page.get_by_role("checkbox", name="Interviewer", exact=True).check()
        page.get_by_role("button", name="Preview exchanges").click()

        expect(page.get_by_role("checkbox", name="Include exchange 1")).to_be_visible()
        assert page.get_by_role("checkbox", name="Include exchange", exact=False).count() == 3
        page.get_by_role("checkbox", name="Include exchange 1").uncheck()
        page.get_by_role("button", name="Import selected exchanges").click()
        expect(page.get_by_role("heading", name="When do you trigger log compaction?")).to_be_visible()

        # Navigate between imported exchanges and ask a follow-up question.
        page.get_by_role("button", name=re.compile(r"How do you validate snapshot integrity\?")).click()
        expect(page.get_by_role("heading", name="How do you validate snapshot integrity?")).to_be_visible()
        page.get_by_role("button", name="Ask this follow up").click()

        followup_q = "What happens if snapshot checksum verification fails?"
        followup_a = "SensitiveExcerptPhrase: abort installation and request chunk retransmission."
        page.get_by_role("textbox", name="Question", exact=True).fill(followup_q)
        page.get_by_label("Candidate answer").fill(followup_a)
        page.get_by_role("button", name="Save and compare").click()
        expect(page.get_by_role("heading", name=followup_q)).to_be_visible()

        # Verify parent lineage navigation and API parent_answer_id linkage.
        expect(page.get_by_role("button", name="Parent question 2", exact=True)).to_be_visible()
        with e2e_workspace.client() as c:
            answers = c.get(f"/api/sessions/{sid}").json()["answers"]
            assert len(answers) == 3
            assert answers[2]["parent_answer_id"] == answers[1]["id"]

        # Record private interviewer note on the follow-up exchange.
        private_note = "SensitivePrivateNote: candidate verified checksum flow."
        page.get_by_role("combobox", name=re.compile(r"^Review outcome")).select_option("disclosed")
        page.get_by_label("Interviewer note").fill(private_note)
        page.get_by_role("button", name="Save review").click()
        expect(page.get_by_text("Review saved")).to_be_visible()

        # Open Review Brief and verify default privacy omissions.
        page.get_by_role("link", name="Review brief").click()
        expect(page).to_have_url(re.compile(r"/interviews/brief/\?id="))
        doc = page.get_by_role("region", name="Brief preview")
        expect(doc.get_by_text("Assistance disclosed by the candidate: 1 (exchange 3).")).to_be_visible()
        default_text = doc.inner_text()
        for hidden in ("PrivateCandidateName", "PrivateRoleName", "SensitiveExcerptPhrase", "SensitivePrivateNote"):
            assert hidden not in default_text

        # Toggle optional excerpt & note, download brief, and verify contents + privacy.
        page.get_by_text("Choose excerpts and notes", exact=True).click()
        page.get_by_role("checkbox", name="Answer excerpt for exchange 3").check()
        page.get_by_role("checkbox", name="Interviewer note for exchange 3").check()
        expect(doc.get_by_text(re.compile("SensitiveExcerptPhrase"))).to_be_visible()
        expect(doc.get_by_text(private_note)).to_be_visible()

        brief_path = tmp_path / "review-brief.md"
        with page.expect_download() as dl:
            page.get_by_role("button", name="Download brief").click()
        dl.value.save_as(str(brief_path))
        brief_md = brief_path.read_text(encoding="utf-8")
        assert "SensitiveExcerptPhrase" in brief_md
        assert private_note in brief_md
        assert "PrivateCandidateName" not in brief_md
        assert "PrivateRoleName" not in brief_md

        page.get_by_role("button", name="Clear optional details").click()
        expect(doc.get_by_text(re.compile("SensitivePrivateNote"))).to_have_count(0)
        assert "SensitiveExcerptPhrase" not in doc.inner_text()
        collector.assert_clean()
    finally:
        ctx.close()
