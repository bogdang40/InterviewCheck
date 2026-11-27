"""Verify partial archives, revoked history access and exact SQLite revision identifiers."""
import json
from urllib.parse import parse_qs, urlsplit
from uuid import uuid4

import httpx
from playwright.sync_api import expect

HEADERS = {"X-InterviewCheck": "1"}
FIRST = "Inspect the original circuit."
SECOND = "Verify the second circuit."
THIRD = "Explain the live circuit."


def create_versions(client):
    fields = {"name": "Circuit design", "policy": "Manuals",
              "questions": [FIRST], "permitted_sources": [{"label": "Guide", "text": "Private first material."}]}
    role = client.post("/api/roles", json=fields).raise_for_status().json()
    for question, material in ((SECOND, "Private second material."), (THIRD, "Private current material.")):
        fields.update(questions=[question], permitted_sources=[{"label": "Guide", "text": material}])
        role = client.put("/api/roles/" + role["id"], json={**fields, "version": role["version"]}).raise_for_status().json()
    return role


def restore_versions(client, numbers, *, partial=False):
    from api.role_kits import content_version

    source = create_versions(client)
    document = client.get("/api/backups/workspace").raise_for_status().json()
    role = next(r for r in document["roles"] if r["id"] == source["id"])
    # Build an independent record from the real writer's archive. Python retains 64 bit integers
    # exactly when submitting bytes to the restore endpoint.
    role["id"] = str(uuid4())
    role["name"] = "Recovered circuit design"
    role["version_number"] = numbers[2]
    for snapshot in role["versions"]:
        snapshot["id"] = str(uuid4())
        snapshot["name"] = role["name"]
        snapshot["version_number"] = numbers[snapshot["version_number"] - 1]
        snapshot["content_sha256"] = content_version({**snapshot, "id": role["id"]})
    if partial:
        role["versions"] = [v for v in role["versions"] if v["version_number"] != numbers[2]]
    document["roles"] = [role]
    raw = json.dumps(document).encode()
    plan = client.post("/api/backups/preview", content=raw).raise_for_status().json()
    assert plan["roles"]["new"] == 1
    client.post("/api/backups/restore", content=raw,
                headers={"X-Backup-Preview": plan["fingerprint"]}).raise_for_status()
    return role


def inspect_first(page, base_url, role):
    page.goto(base_url + "/roles/?role=" + role["id"])
    history = page.get_by_role("region", name="Version history for " + role["name"])
    entry = history.get_by_role("button", name="Preview interviewer guide for revision 1", exact=True).locator("..")
    entry.get_by_role("button", name="Inspect diff").click()
    comparison = history.get_by_role("region", name="Revision comparison")
    return history, comparison, comparison.get_by_label("Compare revision 1 with", exact=True)


def choose(page, selector, role_id, number):
    path = f"/api/roles/{role_id}/versions/1"
    target = {} if number is None else {"compare_to": [str(number)]}

    def matches(response):
        url = urlsplit(response.url)
        return response.request.method == "GET" and url.path == path and parse_qs(url.query) == target

    with page.expect_response(matches) as request:
        selector.select_option("live" if number is None else str(number))
    return request.value


def test_live_and_explicit_targets_survive_a_missing_live_history_row(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers=HEADERS) as client:
        role = restore_versions(client, (1, 2, 3), partial=True)
        rows = client.get(f"/api/roles/{role['id']}/versions").raise_for_status().json()
        assert [v["version_number_text"] for v in rows["versions"]] == ["2", "1"]
        assert rows["current_version_number_text"] == "3"

    _, comparison, targets = inspect_first(page, workspace_url, role)
    expect(targets.get_by_role("option")).to_have_count(3)
    expect(targets.get_by_role("option", name="Live role")).to_have_count(1)
    expect(targets).to_have_value("live")
    expect(comparison).to_contain_text("Diff vs live v3")
    expect(comparison.get_by_role("group", name="Revision 3", exact=True).first).to_contain_text(THIRD)
    assert choose(page, targets, role["id"], 2).ok
    expect(comparison).to_contain_text("Comparing v1 with v2")
    expect(comparison.get_by_role("group", name="Revision 2", exact=True).first).to_contain_text(SECOND)
    expect(comparison).not_to_contain_text(THIRD)
    assert choose(page, targets, role["id"], None).ok
    expect(comparison).to_contain_text("Diff vs live v3")
    expect(comparison).to_contain_text(THIRD)


def test_adjacent_large_revision_numbers_select_distinct_saved_rows(workspace_url, browser_page):
    page = browser_page
    # Both numbers exceed MAX_SAFE_INTEGER and compare equal as JavaScript numbers.
    left, right = 2**53, 2**53 + 1
    with httpx.Client(base_url=workspace_url, headers=HEADERS) as client:
        role = restore_versions(client, (1, left, right))
    _, comparison, targets = inspect_first(page, workspace_url, role)
    expect(comparison).to_contain_text(f"Diff vs live v{right}")
    for number, expected, other in ((left, SECOND, THIRD), (right, THIRD, SECOND)):
        response = choose(page, targets, role["id"], number)
        assert response.ok and json.loads(response.body())["diff"]["against_version_number_text"] == str(number)
        expect(targets).to_have_value(str(number))
        expect(comparison).to_contain_text(f"Comparing v1 with v{number}")
        expect(comparison.get_by_role("group", name=f"Revision {number}", exact=True).first).to_contain_text(expected)
        expect(comparison).not_to_contain_text(other)


def test_denied_comparison_and_history_reload_clear_the_previously_authorized_view(workspace_url, browser_page, monkeypatch):
    page = browser_page
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.setenv("TRIAL_DAYS", "2")
    email, password = "role-history@example.test", "Synthetic-Comparison-Viewer-42"
    with httpx.Client(base_url=workspace_url, headers=HEADERS) as client:
        client.post("/api/integrations/access/signup", json={"email": email, "password": password}).raise_for_status()
        role = create_versions(client)
    page.goto(workspace_url + "/account/")
    page.get_by_label("Operator email").fill(email)
    page.get_by_label("Password", exact=True).fill(password)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(f"{email} · Access active")).to_be_visible()
    history, comparison, targets = inspect_first(page, workspace_url, role)
    expect(comparison).to_contain_text("Diff vs live v3")
    comparison.get_by_text("Compare permitted materials", exact=True).click()
    expect(comparison).to_contain_text("Private first material.")
    expect(comparison).to_contain_text("Private current material.")
    expect(history.get_by_role("button", name="Restore version", exact=True).first).to_be_visible()
    page.context.clear_cookies()
    assert choose(page, targets, role["id"], 2).status == 401
    expect(comparison).to_have_count(0)
    expect(history).not_to_contain_text("Private first material.")
    expect(history.get_by_role("button", name="Restore version", exact=True)).to_have_count(0)
    retry = history.get_by_role("button", name="Reload history")
    with page.expect_response(lambda r: urlsplit(r.url).path == f"/api/roles/{role['id']}/versions") as result:
        retry.click()
    assert result.value.status == 401
    expect(retry).to_be_visible()
    expect(history.get_by_role("button", name="Inspect diff")).to_have_count(0)
    expect(history.get_by_role("button", name="Restore version", exact=True)).to_have_count(0)
    expect(history).not_to_contain_text("Private current material.")


def test_denied_history_refresh_drops_old_rows_after_a_real_restore(workspace_url, browser_page):
    page = browser_page
    with httpx.Client(base_url=workspace_url, headers=HEADERS) as client:
        role = create_versions(client)
        history, comparison, _ = inspect_first(page, workspace_url, role)
        expect(comparison).to_contain_text("Diff vs live v3")
        comparison.get_by_text("Compare permitted materials", exact=True).click()
        expect(comparison).to_contain_text("Private first material.")
        entry = history.get_by_role("button", name="Preview interviewer guide for revision 1", exact=True).locator("..")
        # The authorized restore commits normally. Model a permission change on the ensuing
        # history read, while previously authorized stored rows still exist in component state.
        path = f"/api/roles/{role['id']}/versions"
        page.route("**" + path, lambda route: route.fulfill(status=403, json={"detail": "History access was revoked."}))
        with page.expect_response(lambda r: urlsplit(r.url).path == path) as reload_result:
            entry.get_by_role("button", name="Restore version", exact=True).click()
        assert reload_result.value.status == 403
        expect(history.get_by_role("alert")).to_contain_text("History access was revoked.")
        expect(history.get_by_role("button", name="Restore version", exact=True)).to_have_count(0)
        expect(history.get_by_role("button", name="Inspect diff", exact=True)).to_have_count(0)
        expect(comparison).to_have_count(0)
        expect(history).not_to_contain_text("Private first material.")
        assert client.get("/api/roles/" + role["id"]).raise_for_status().json()["version_number"] == 4
