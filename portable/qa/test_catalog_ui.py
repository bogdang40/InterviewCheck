from playwright.sync_api import expect


def test_searchable_provider_setup_preserves_imports_without_checking_vendor(
    workspace_url, browser_page, monkeypatch, tmp_path
):
    from unittest.mock import AsyncMock

    transport = AsyncMock(side_effect=AssertionError("No external operation was requested"))
    monkeypatch.setattr("httpx.AsyncClient.send", transport)
    monkeypatch.setenv("WORKABLE_API_KEY", "private-catalog-fixture")
    monkeypatch.setenv("WORKABLE_SUBDOMAIN", "private-catalog-fixture")
    monkeypatch.delenv("WORKABLE_MEMBER_ID", raising=False)
    page = browser_page
    page.goto(workspace_url + "/connections/")
    expect(page.get_by_label("Import calendar events")).to_be_visible()
    expect(page.get_by_label("Import candidates from CSV")).to_be_visible()
    page.get_by_label("Search provider or task").fill("workable")
    card = page.get_by_role("region", name="Workable setup")
    expect(card).to_be_visible()
    expect(card.get_by_text("Configured", exact=True)).to_be_visible()
    card.locator("summary").filter(has_text="Send a reviewed private note").click()
    expect(card.get_by_text("WORKABLE_MEMBER_ID")).to_be_visible()
    expect(card.get_by_text("Missing", exact=True)).to_be_visible()
    assert "private-catalog-fixture" not in page.locator("body").inner_text()
    page.screenshot(path=tmp_path / "connection-setup.png", full_page=True)
    page.get_by_label("Connection task").select_option("Private notes")
    expect(card.get_by_text("Find a candidate by email")).to_have_count(0)
    page.get_by_label("Search provider or task").fill("no such provider")
    expect(page.get_by_text("0 providers available for this search")).to_be_visible()
    transport.assert_not_called()
