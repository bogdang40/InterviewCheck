"""The admin cost log and its CSV must use the same period, company and outcome."""
import csv
from datetime import datetime, timedelta, timezone
import re
import sqlite3

import pytest
from playwright.sync_api import expect

from e2e_suite.harness import assert_no_horizontal_overflow, signup_user

ADMIN_EMAIL = "operator@usage.example"
PASSWORD = "Synthetic-Usage-Scope-4102"
BOOTSTRAP = "scope-bootstrap-fixture-4102"


def seed_calls(workspace):
    today = datetime.now(timezone.utc).date()
    with sqlite3.connect(workspace.review_db) as db:
        for age, company, model, status, cost in (
            (12, "north.example", "Archived failure", 503, 0.80),
            (1, "north.example", "Successful draft", 200, 0.60),
            (1, "south.example", "Other company failure", 429, 0.12),
            (1, "north.example", "Reference timeout", 504, 0.25),
        ):
            day = (today - timedelta(days=age)).isoformat()
            db.execute(
                """INSERT INTO ai_cost_log(at, day, account_email, company, capability, provider,
                                          model_id, model_name, ok, http_status, input_tokens, output_tokens,
                                          cost_usd, estimate_status)
                   VALUES (?, ?, ?, ?, 'reference', 'azure_openai', ?, ?, ?, ?, 250, 10, ?, ?)""",
                (day + "T12:00:00Z", day, "reviewer@" + company, company, model.lower().replace(" ", "-"),
                 model, int(status == 200), status, cost, "missing_rates" if status == 429 else "estimated"),
            )


def check_scope(page, workspace, viewport):
    page.goto(workspace.base_url + "/account/")
    page.get_by_label("Operator email").fill(ADMIN_EMAIL)
    page.get_by_label("Password", exact=True).fill(PASSWORD)
    page.get_by_role("button", name="Sign in", exact=True).click()
    expect(page.get_by_text(f"{ADMIN_EMAIL} · Access active")).to_be_visible()
    page.goto(workspace.base_url + "/admin/")
    page.get_by_role("tab", name="Usage", exact=True).click()
    log = page.get_by_role("region", name="AI cost log")
    recent = log.locator("ol.admin-usage-recent").get_by_role("listitem")
    expect(recent).to_have_count(4)
    expect(log).to_contain_text("Complete estimates for 3 of 4 calls.")
    expect(log.get_by_role("button", name="Manage model prices")).to_be_visible()
    page.get_by_label("Period", exact=True).select_option(label="Last 7 days")
    expect(recent).to_have_count(3)
    expect(log).not_to_contain_text("Archived failure")

    log.get_by_label("Company", exact=True).select_option(label="north.example")
    expect(recent).to_have_count(2)
    log.get_by_label("Outcome", exact=True).select_option(label="Failed requests")
    expect(recent).to_have_count(1)
    expect(recent).to_contain_text("Reference timeout")
    expect(recent).to_contain_text("Failed 504")
    summary = log.get_by_text(re.compile(r"^1 requests?\s*\(1 failed\)"))
    expect(summary).to_contain_text("250 in")
    expect(summary).to_contain_text("10 out")
    expect(summary).to_contain_text("$0.25")
    month_table = log.locator("table").filter(has=page.locator("thead th", has_text=re.compile(r"^Month$")))
    month_rows = month_table.locator("tbody tr")
    expect(month_rows).to_have_count(1)
    expect(month_rows).to_contain_text("north.example")
    expect(month_rows).to_contain_text("$0.25")
    expect(log).not_to_contain_text("Successful draft")
    expect(log).not_to_contain_text("Other company failure")
    expect(log).not_to_contain_text("Archived failure")
    assert "end_day=" in log.get_by_role("link", name="Download CSV").get_attribute("href")
    assert "through_id=" in log.get_by_role("link", name="Download CSV").get_attribute("href")
    assert_no_horizontal_overflow(page)
    log.screenshot(path=workspace.screenshot_dir / f"usage_cost_scope_{viewport}.png", timeout=20_000)

    with page.expect_download() as download:
        log.get_by_role("link", name="Download CSV").click()
    with download.value.path().open(encoding="utf-8-sig", newline="") as exported:
        rows = list(csv.DictReader(exported))
    assert len(rows) == 1
    row = rows[0]
    assert (row["company"], row["account_email"], row["model_name"], row["http_status"], row["ok"]) == (
        "north.example", "reviewer@north.example", "Reference timeout", "504", "0",
    )
    assert (int(row["input_tokens"]), int(row["output_tokens"]), float(row["cost_usd"])) == (250, 10, 0.25)
    assert row["estimate_status"] == "estimated"


@pytest.mark.tier3
def test_scoped_cost_totals_and_download_on_desktop_and_phone(e2e_workspace, desktop_page, mobile_page):
    e2e_workspace.configure_embedded_auth(admin_emails=(ADMIN_EMAIL,), bootstrap_secret=BOOTSTRAP)
    e2e_workspace.restart()
    with e2e_workspace.client() as client:
        signup_user(client, email=ADMIN_EMAIL, password=PASSWORD, admin_secret=BOOTSTRAP)
    seed_calls(e2e_workspace)
    page, _ = desktop_page
    page.set_viewport_size({"width": 1280, "height": 900})
    check_scope(page, e2e_workspace, "1280x900")
    # If only the overview fails, the cost log still shows the selected period.
    _, collector = desktop_page
    collector.ignore_server_5xx = True
    page.route("**/api/admin/usage?days=90", lambda route: route.fulfill(status=503, json={"detail": "Overview unavailable"}))
    page.get_by_label("Period", exact=True).select_option("90")
    expect(page.get_by_role("alert").filter(has_text="Overview unavailable")).to_be_visible()
    expect(page.get_by_label("Usage summary")).to_have_count(0)
    expect(page.get_by_role("region", name="AI cost log").get_by_role("listitem")).to_have_count(2)
    assert not collector.page_errors and not collector.server_errors
    assert all("503" in error for error in collector.console_errors)
    collector.reset()
    collector.ignore_server_5xx = False
    phone, _ = mobile_page
    check_scope(phone, e2e_workspace, "390x844")
