"""Opaque-box Playwright E2E tests for M12 role calibration, rubric versioning, and bulk operations."""
import json
from uuid import uuid4

from playwright.sync_api import expect
import pytest

from e2e_suite.harness import (
    ConsoleErrorCollector,
    assert_no_horizontal_overflow,
    login_user,
    signup_user,
)

ALICE_EMAIL = "alice-m12@example.test"
BOB_EMAIL = "bob-m12@example.test"
PASS = "Synthetic-M12-Pass-9876"


def _setup_reviewers(e2e_workspace) -> None:
    e2e_workspace.configure_embedded_auth()
    e2e_workspace.restart()
    with e2e_workspace.client() as c:
        signup_user(c, email=ALICE_EMAIL, password=PASS)
        signup_user(c, email=BOB_EMAIL, password=PASS)


def _sign_in_browser(page, base_url: str, email: str, password: str = PASS) -> None:
    page.goto(base_url + "/account/", wait_until="domcontentloaded")
    page.get_by_label("Operator email").fill(email)
    page.get_by_label("Password", exact=True).fill(password)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(f"{email} · Access active")).to_be_visible()


def _create_role_api(client, *, name: str = "Systems Calibration Role") -> dict:
    res = client.post("/api/roles", json={
        "name": name,
        "description": "Concurrency and storage evaluation",
        "questions": ["How do you avoid deadlocks?", "Explain WAL durability."],
        "policy": "No external assistance.",
        "permitted_sources": [],
        "rubric": [{
            "id": "crit-lock", "criterion": "Lock ordering", "weight": 60,
            "expected_signals": ["States lock hierarchy"], "red_flags": ["Ignores deadlock"],
        }],
        "change_note": "Initial calibration rubric",
    })
    res.raise_for_status()
    return res.json()


def _create_session_with_answer(client, *, candidate: str, role: dict | None = None, match: bool = False) -> tuple[str, str]:
    payload = {"candidate": candidate, "role": role["name"] if role else "Backend Engineer", "consent": True}
    if role is not None:
        payload["role_id"] = role["id"]
    else:
        payload["policy"] = "No external assistance."
    s_res = client.post("/api/sessions", json=payload)
    s_res.raise_for_status()
    sid = s_res.json()["id"]
    text = "Acquire latches in deterministic total order across shards to prevent cyclic deadlock."
    refs = [{"label": "Source ref", "text": text}] if match else []
    a_res = client.post(f"/api/sessions/{sid}/answers", json={
        "question": "How do you avoid deadlocks?", "answer": text, "references": refs, "planned_slot": 1,
    })
    a_res.raise_for_status()
    return sid, a_res.json()["id"]


def test_m12_role_calibration_analytics_and_disagreements(e2e_workspace, desktop_page):
    _setup_reviewers(e2e_workspace)
    with e2e_workspace.client() as anon:
        for path in ("/api/roles/analytics", f"/api/roles/{uuid4()}/calibration", f"/api/roles/{uuid4()}/versions"):
            assert anon.get(path).status_code == 401

    with e2e_workspace.client() as alice_api:
        login_user(alice_api, email=ALICE_EMAIL, password=PASS)
        role = _create_role_api(alice_api, name="Staff Storage Engineer")
        sid, aid1 = _create_session_with_answer(alice_api, candidate="Ada Lovelace", role=role, match=True)
        a2_res = alice_api.post(f"/api/sessions/{sid}/answers", json={
            "question": "Explain WAL durability.",
            "answer": "Flush journal frames with fsync prior to returning commit acknowledgement.",
            "references": [], "planned_slot": 2,
        })
        a2_res.raise_for_status()
        aid2 = a2_res.json()["id"]

    page, collector = desktop_page
    _sign_in_browser(page, e2e_workspace.base_url, ALICE_EMAIL)

    page.goto(f"{e2e_workspace.base_url}/interviews/review/?id={sid}", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="How do you avoid deadlocks?")).to_be_visible()
    page.get_by_label("Review outcome").select_option("explained")
    page.get_by_label("Interviewer note").fill("Candidate explained total lock order clearly.")
    page.get_by_role("button", name="Save review").click()
    expect(page.get_by_text("Review saved")).to_be_visible()

    with e2e_workspace.client() as alice_api, e2e_workspace.client() as bob_api:
        login_user(alice_api, email=ALICE_EMAIL, password=PASS)
        login_user(bob_api, email=BOB_EMAIL, password=PASS)
        alice_api.patch(f"/api/sessions/{sid}/answers/{aid2}", json={"disposition": "explained", "note": "Solid WAL answer"}).raise_for_status()
        bob_api.patch(f"/api/sessions/{sid}/answers/{aid1}", json={"disposition": "unresolved", "note": "Needs deadlock proof"}).raise_for_status()
        cal = alice_api.get(f"/api/roles/{role['id']}/calibration").json()
        assert cal["summary"]["multi_reviewer_disagreements"] == 1
        assert len(cal["disagreements"]) == 1 and len(cal["disagreements"][0]["reviewers"]) == 2

    page.goto(e2e_workspace.base_url + "/roles/", wait_until="domcontentloaded")
    panel = page.get_by_label("Role calibration analytics")
    expect(panel.get_by_role("heading", name="Role analytics and reviewer spread")).to_be_visible()
    expect(panel).to_contain_text("Active sessions")
    expect(panel).to_contain_text("50.0%")
    expect(panel).to_contain_text("1 disagreements")

    spread = panel.get_by_role("table", name="Workspace reviewer calibration spread")
    expect(spread).to_contain_text(ALICE_EMAIL)
    expect(spread).to_contain_text("+50.0 pp")
    expect(spread).to_contain_text(BOB_EMAIL)
    expect(spread).to_contain_text("-50.0 pp")

    panel.get_by_role("button", name="Inspect calibration").click()
    expect(panel.get_by_role("heading", name=f"Reviewer spread for {role['name']}")).to_be_visible()
    expect(panel.get_by_role("heading", name="Question breakdown")).to_be_visible()
    question = panel.get_by_role("list", name="Question breakdown").get_by_role("listitem").filter(has_text="How do you avoid deadlocks?")
    expect(question).to_contain_text("Question 1 · Saved plan")
    expect(question).to_contain_text("Disagreements 1")
    collector.assert_clean()


def test_m12_rubric_authoring_versioning_diff_rollback_and_409_guard(e2e_workspace, desktop_page):
    page, collector = desktop_page
    page.goto(e2e_workspace.base_url + "/roles/", wait_until="domcontentloaded")
    expect(page.get_by_role("heading", name="Role library")).to_be_visible()

    page.get_by_role("button", name="Add role").click()
    page.get_by_label("Role name").fill("Distributed Systems Lead")
    page.get_by_label("Description").fill("Consensus and replication interviews")
    page.get_by_label("Planned questions, one per line").fill("Explain Raft leader election.")
    page.get_by_role("button", name="Add rubric criterion").click()
    page.get_by_label("Criterion title").fill("Safety invariants")
    page.get_by_label("Weight (1 to 100)").fill("60")
    page.get_by_label("Expected signals, one per line").fill("Explains term monotonicity")
    page.get_by_label("Red flags, one per line").fill("Confuses term with commit index")
    page.get_by_label("Version change note").fill("Initial rubric v1")
    page.get_by_role("button", name="Save role").click()

    role_row = page.locator(".role-row", has_text="Distributed Systems Lead")
    expect(role_row).to_contain_text("v1 | 1 rubric criterion")

    role_row.get_by_role("button", name="Edit role").click()
    page.get_by_label("Planned questions, one per line").fill("Explain Raft leader election.\nDesign log compaction.")
    page.get_by_role("button", name="Add rubric criterion").click()
    page.get_by_label("Criterion title").nth(1).fill("Failure recovery")
    page.get_by_label("Weight (1 to 100)").nth(1).fill("40")
    page.get_by_label("Version change note").fill("Added recovery criterion")
    page.get_by_role("button", name="Save role").click()
    expect(role_row).to_contain_text("v2 | 2 rubric criteria")

    role_row.get_by_role("button", name="Version history for Distributed Systems Lead", exact=True).click()
    history = page.get_by_role("region", name="Version history for Distributed Systems Lead")
    expect(history).to_contain_text("Current live version: v2")
    expect(history).to_contain_text("Added recovery criterion")

    v1_card = history.locator("div.rounded-lg", has_text="Initial rubric v1")
    v1_card.get_by_role("button", name="Inspect diff").click()
    expect(v1_card).to_contain_text("Diff vs live v2")
    expect(v1_card).to_contain_text("Changed fields: questions, rubric")
    expect(v1_card).to_contain_text("Design log compaction.")
    added = v1_card.get_by_label("Grading changes")
    expect(added).to_contain_text("Failure recovery")
    expect(added).to_contain_text("Weight 40")

    # Advance live role in background so browser holds a stale version hash and hits 409 on rollback.
    with e2e_workspace.client() as c:
        live = next(r for r in c.get("/api/roles").json() if r["name"] == "Distributed Systems Lead")
        c.put(f"/api/roles/{live['id']}", json={
            "id": live["id"], "version": live["version"], "name": live["name"],
            "description": "Updated concurrently", "questions": live["questions"],
            "policy": live["policy"], "permitted_sources": live["permitted_sources"],
            "rubric": live["rubric"], "change_note": "Concurrent v3 update",
        }).raise_for_status()

    collector.assert_clean()
    history.get_by_label("Rollback note (optional)").fill("Rollback to v1")
    v1_card.get_by_role("button", name="Restore version").click()
    expect(history.get_by_role("alert")).to_contain_text("Version conflict (409)")
    assert not collector.page_errors and not collector.server_errors
    assert len(collector.console_errors) == 1 and "409" in collector.console_errors[0]
    collector.reset()

    history.get_by_role("button", name="Reload latest role").click()
    expect(history).to_contain_text("Current live version: v3")

    v1_card.get_by_role("button", name="Restore version").click()
    expect(history.get_by_role("status").filter(has_text="Restored version 1 as version 4.")).to_be_visible()
    expect(history).to_contain_text("Current live version: v4")
    expect(role_row).to_contain_text("v4 | 1 rubric criterion")

    page.reload(wait_until="domcontentloaded")
    expect(page.locator(".role-row", has_text="Distributed Systems Lead")).to_contain_text("v4 | 1 rubric criterion")
    collector.assert_clean()


def test_m12_bulk_tag_export_archive_restore_and_csrf_guards(e2e_workspace, desktop_page):
    with e2e_workspace.client() as c:
        role = _create_role_api(c, name="Bulk Ops Role")
        sid1, _ = _create_session_with_answer(c, candidate="Alice Candidate", role=role, match=True)
        sid2, _ = _create_session_with_answer(c, candidate="=CMD('calc')", role=role, match=False)
        with e2e_workspace.client() as no_csrf:
            no_csrf.headers.pop("X-InterviewCheck", None)
            for path, body in (
                ("/api/interviews/bulk/archive", {"session_ids": [sid1], "confirm_count": 1}),
                ("/api/interviews/bulk/restore", {"items": [{"session_id": sid1, "operation_version": str(uuid4())}]}),
                ("/api/interviews/bulk/tag", {"session_ids": [sid1], "add": ["t1"], "remove": []}),
                ("/api/interviews/bulk/export", {"session_ids": [sid1], "format": "csv"}),
                (f"/api/roles/{role['id']}/versions/1/restore", {"expected_version": role["version"]}),
            ):
                assert no_csrf.post(path, json=body).status_code == 403
        assert c.post("/api/interviews/bulk/archive", json={"session_ids": [sid1, sid2], "confirm_count": 1}).status_code == 409
        assert len(c.get("/api/trash").json()["items"]) == 0

    page, collector = desktop_page
    page.goto(e2e_workspace.base_url + "/interviews/", wait_until="domcontentloaded")
    expect(page.get_by_label("Select Alice Candidate")).to_be_visible()

    toolbar = page.get_by_label("Bulk selection actions")
    toolbar.get_by_role("button", name="Select all (2)").click()
    expect(toolbar).to_contain_text("2 selected")

    toolbar.get_by_label("Bulk tags").fill("cohort-m12")
    toolbar.get_by_role("button", name="Add tags").click()
    expect(page.get_by_text("Updated tags on 2 interviews.")).to_be_visible()

    toolbar.get_by_role("button", name="Clear selection").click()
    page.get_by_label("Select Alice Candidate").check()
    toolbar.get_by_label("Bulk tags").fill("priority-a")
    toolbar.get_by_role("button", name="Add tags").click()
    expect(page.get_by_text("Updated tags on 1 interview.")).to_be_visible()

    page.get_by_role("group", name="Tag filters").get_by_role("button", name="priority-a").click()
    expect(page.locator("ul.work-list > li")).to_have_count(1)
    expect(page.locator("ul.work-list")).to_contain_text("Alice Candidate")
    page.get_by_role("button", name="Clear filters").click()
    expect(page.locator("ul.work-list > li")).to_have_count(2)

    toolbar.get_by_role("button", name="Select all (2)").click()
    with page.expect_download() as csv_dl:
        toolbar.get_by_role("button", name="Export CSV").click()
    csv_text = csv_dl.value.path().read_text(encoding="utf-8-sig")
    assert "'=CMD('calc')" in csv_text and "cohort-m12" in csv_text

    with page.expect_download() as json_dl:
        toolbar.get_by_role("button", name="Export JSON").click()
    exported = json.loads(json_dl.value.path().read_text(encoding="utf-8"))
    assert exported["count"] == 2 and any("cohort-m12" in item["tags"] for item in exported["sessions"])

    toolbar.get_by_role("button", name="Archive selected").click()
    confirm_btn = toolbar.get_by_role("button", name="Confirm archive (2)")
    toolbar.get_by_label("Confirm selection count").fill("1")
    expect(confirm_btn).to_be_disabled()
    toolbar.get_by_label("Confirm selection count").fill("2")
    expect(confirm_btn).to_be_enabled()
    confirm_btn.click()
    expect(page.get_by_text("Moved 2 interviews to Trash.")).to_be_visible()

    page.get_by_role("link", name="Open Trash").click()
    expect(page.get_by_role("heading", name="2 interviews in Trash")).to_be_visible()

    with e2e_workspace.client() as c:
        trash_items = {item["id"]: item["operation_version"] for item in c.get("/api/trash").json()["items"]}
        assert c.post("/api/interviews/bulk/restore", json={"items": [
            {"session_id": sid1, "operation_version": str(uuid4())},
            {"session_id": sid2, "operation_version": trash_items[sid2]},
        ]}).status_code == 409
        assert len(c.get("/api/trash").json()["items"]) == 2
        c.post(f"/api/trash/{sid1}/restore", json={"operation_version": trash_items[sid1]}).raise_for_status()
        c.post(f"/api/sessions/{sid1}/trash").raise_for_status()

    collector.assert_clean()
    trash_bar = page.get_by_label("Bulk selection actions")
    trash_bar.get_by_role("button", name="Select all (2)").click()
    trash_bar.get_by_role("button", name="Restore selected").click()
    trash_bar.get_by_label("Confirm selection count").fill("2")
    with page.expect_response(lambda r: "/api/trash" in r.url and r.request.method == "GET" and r.status == 200):
        trash_bar.get_by_role("button", name="Confirm restore (2)").click()
    expect(page.locator("[role='alert']").first).to_be_visible()
    assert not collector.page_errors and not collector.server_errors
    assert len(collector.console_errors) == 1 and "409" in collector.console_errors[0]
    collector.reset()

    trash_bar.get_by_role("button", name="Confirm restore (2)").click()
    expect(page.get_by_text("Restored 2 interviews from Trash.")).to_be_visible()
    expect(page.get_by_role("heading", name="Trash is empty")).to_be_visible()

    page.goto(e2e_workspace.base_url + "/interviews/", wait_until="domcontentloaded")
    expect(page.locator("ul.work-list > li")).to_have_count(2)
    collector.assert_clean()


@pytest.mark.parametrize("viewport", [(1440, 900, "desktop-1440"), (390, 844, "mobile-390")], ids=lambda v: v[2])
def test_m12_responsive_roles_interviews_and_trash_viewports(e2e_workspace, e2e_browser, viewport):
    width, height, _ = viewport
    with e2e_workspace.client() as c:
        role = _create_role_api(c, name="Responsive Role")
        c.put(f"/api/roles/{role['id']}", json={
            "id": role["id"], "version": role["version"], "name": role["name"],
            "description": "Updated", "questions": [*role["questions"], "Describe replication lag."],
            "policy": role["policy"], "permitted_sources": role["permitted_sources"],
            "rubric": role["rubric"], "change_note": "v2",
        }).raise_for_status()
        sid1, aid1 = _create_session_with_answer(c, candidate="Resp Active 1", role=role, match=True)
        sid2, _ = _create_session_with_answer(c, candidate="Resp Active 2", role=role, match=False)
        sid3, _ = _create_session_with_answer(c, candidate="Resp Trashed", role=role, match=False)
        c.patch(f"/api/sessions/{sid1}/answers/{aid1}", json={"disposition": "explained", "note": "Clear"}).raise_for_status()
        c.post("/api/interviews/bulk/tag", json={"session_ids": [sid1, sid2], "add": ["responsive"], "remove": []}).raise_for_status()
        c.post(f"/api/sessions/{sid3}/trash").raise_for_status()

    mobile = width <= 480
    ctx = e2e_browser.new_context(viewport={"width": width, "height": height}, reduced_motion="reduce", is_mobile=mobile, has_touch=mobile)
    page = ctx.new_page()
    page.set_default_timeout(10_000)
    collector = ConsoleErrorCollector()
    collector.attach(page)
    try:
        page.goto(e2e_workspace.base_url + "/roles/", wait_until="domcontentloaded")
        expect(page.get_by_role("heading", name="Role library")).to_be_visible()
        page.locator(".role-row", has_text="Responsive Role").get_by_role("button", name="Version history for Responsive Role", exact=True).click()
        page.get_by_role("region", name="Version history for Responsive Role").get_by_role("button", name="Inspect diff").last.click()
        page.get_by_label("Role calibration analytics").get_by_role("button", name="Inspect calibration").click()
        assert_no_horizontal_overflow(page)

        page.goto(e2e_workspace.base_url + "/interviews/", wait_until="domcontentloaded")
        expect(page.get_by_label("Bulk selection actions")).to_be_visible()
        page.get_by_label("Select Resp Active 1").check()
        assert_no_horizontal_overflow(page)

        page.goto(e2e_workspace.base_url + "/trash/", wait_until="domcontentloaded")
        expect(page.get_by_role("heading", name="1 interview in Trash")).to_be_visible()
        page.get_by_label("Select Resp Trashed").check()
        assert_no_horizontal_overflow(page)
        collector.assert_clean()
    finally:
        ctx.close()
