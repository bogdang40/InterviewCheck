"""An administrator can see a retention conflict count without exposing the held interview."""
import json
from urllib.parse import parse_qs, urlsplit

import pytest
from playwright.sync_api import expect

from e2e_suite.harness import ConsoleErrorCollector, login_user
from e2e_suite.test_m21_compliance_retention_e2e import ADMIN_EMAIL, ADMIN_PASS, _setup_auth, _sign_in_admin

ROLE = "Retentionvisibilityfixture"
NORMAL = "Visible control interview"
HISTORY_ONLY = "Preerasurehistorymarker"


def seed(client, name, answer):
    sid = client.post("/api/sessions", json={"candidate": name, "role": ROLE, "policy": "Manual allowed",
                                            "consent": True}).raise_for_status().json()["id"]
    saved = client.post(f"/api/sessions/{sid}/answers", json={"question": "Describe the test.",
                                                            "answer": answer}).raise_for_status().json()
    return sid, saved


@pytest.mark.tier3
def test_admin_count_public_visibility_and_preselected_backup_refusal(e2e_workspace, desktop_page):
    from api import answer_history, store
    from api.retention_anonymizer import REDACTED_TEXT, SessionAnonymizer, anonymized_candidate_label

    _setup_auth(e2e_workspace)
    with e2e_workspace.client() as admin:
        login_user(admin, email=ADMIN_EMAIL, password=ADMIN_PASS)
        normal, normal_answer = seed(admin, NORMAL, "An unaffected response.")
        clean, clean_answer = seed(admin, "Clean fixture", "Erased clean response.")
        held, old_answer = seed(admin, "Held fixture", HISTORY_ONLY)
    with store.connection(e2e_workspace.review_db, write=True) as db:
        for sid in (clean, held):
            SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=False, actor_email=ADMIN_EMAIL,
                                           now_iso=store.timestamp())
    page, collector = desktop_page
    base = e2e_workspace.base_url
    _sign_in_admin(page, base)
    transfer = page.context.new_page()
    transfer_errors = ConsoleErrorCollector()
    transfer_errors.attach(transfer)
    downloads = []
    transfer.on("download", lambda download: downloads.append(download))
    try:
        # The reviewer selected this scope while its erasure receipt was consistent.
        transfer.goto(base + "/data/", wait_until="domcontentloaded")
        picker = transfer.get_by_label("Backup contents")
        picker.select_option(held)
        link = transfer.get_by_role("link", name="Download backup for this interview")
        expect(link).to_have_attribute("href", f"/api/backups/workspace?session_id={held}")

        with store.connection(e2e_workspace.review_db, write=True) as db:
            # Represent the physical legacy history directly. The current app never
            # receives a request to reintroduce the erased answer.
            snapshot = json.dumps(answer_history.snapshot(old_answer), ensure_ascii=False)
            db.execute("""INSERT INTO answer_history(answer_id,revision,kind,actor,saved_at,snapshot)
                          VALUES (?,?,'baseline',NULL,NULL,?)""", (old_answer["id"], old_answer["revision"], snapshot))

        page.get_by_role("tab", name="Compliance", exact=True).click()
        retention = page.get_by_role("region", name="Data retention and PII anonymization")
        notice = retention.get_by_role("alert")
        expect(notice).to_contain_text("Interviews withheld by erasure checks: 1.")
        expect(notice).not_to_contain_text(HISTORY_ONLY)
        retention.screenshot(path=e2e_workspace.screenshot_dir / "admin-retention-hold.png")

        clean_label, held_label = anonymized_candidate_label(clean), anonymized_candidate_label(held)
        for route in ("/", "/interviews/"):
            page.goto(base + route, wait_until="domcontentloaded")
            expect(page.get_by_text(NORMAL, exact=True).first).to_be_visible()
            expect(page.get_by_text(clean_label, exact=True).first).to_be_visible()
            expect(page.get_by_text(held_label, exact=True)).to_have_count(0)
            expect(page.locator(f'a[href*="{held}"]')).to_have_count(0)
            expect(page.locator("body")).not_to_contain_text(HISTORY_ONLY)

        page.get_by_role("button", name="Search workspace", exact=True).click()
        search = page.get_by_role("dialog", name="Search workspace")
        query = search.get_by_role("combobox", name="Search workspace records")
        for term, expected in ((ROLE, {normal, clean}), (HISTORY_ONLY, set())):
            with page.expect_response(lambda r: urlsplit(r.url).path == "/api/search" and
                                      r.request.post_data_json.get("query") == term) as observed:
                query.fill(term)
            response = observed.value
            assert response.status == 200
            assert {row["id"] for row in response.json()["items"]} == expected
            assert HISTORY_ONLY.encode() not in response.body()
            if expected:
                expect(search.get_by_text(NORMAL, exact=True)).to_be_visible()
                expect(search.get_by_text(clean_label, exact=True)).to_be_visible()
            else:
                expect(search.get_by_role("status")).to_contain_text("No matching commands or records.")
        page.keyboard.press("Escape")
        for sid, answer, text in ((normal, normal_answer, normal_answer["answer"]), (clean, clean_answer, REDACTED_TEXT)):
            page.goto(base + f"/interviews/review/?id={sid}&answer={answer['id']}", wait_until="domcontentloaded")
            expect(page.get_by_role("heading", name=answer["question"], exact=True)).to_be_visible()
            expect(page.locator("body")).to_contain_text(text)

        transfer_errors.assert_clean()
        with transfer.expect_response(lambda r: urlsplit(r.url).path == "/api/backups/workspace" and
                                      parse_qs(urlsplit(r.url).query).get("session_id") == [held]) as denied:
            link.click()
        response = denied.value
        assert response.status == 409 and "attachment" not in response.headers.get("content-disposition", "")
        assert HISTORY_ONLY.encode() not in response.body() and "sessions" not in response.json()
        expect(transfer.get_by_role("alert").filter(has_text="consistent SQLite backup")).to_be_visible()
        assert not downloads
        assert not transfer_errors.page_errors and not transfer_errors.server_errors
        assert all("409" in message for message in transfer_errors.console_errors), transfer_errors.console_errors
        collector.assert_clean()
    finally:
        transfer.close()
