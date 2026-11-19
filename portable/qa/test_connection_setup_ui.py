"""The catalog exposes local configuration state without touching vendor APIs."""

import httpx
from playwright.sync_api import expect


def test_partial_configuration_is_per_operation_and_local(workspace_url, browser_page, monkeypatch):
    secret = "synthetic-value-must-stay-server-side"
    monkeypatch.setenv("WORKABLE_API_KEY", secret)
    monkeypatch.setenv("WORKABLE_SUBDOMAIN", "sample-fixture-tenant")
    monkeypatch.delenv("WORKABLE_MEMBER_ID", raising=False)
    outbound = []

    async def deny_outbound(self, request, **options):
        outbound.append(request.url.host)
        raise AssertionError("Opening connection setup must not contact any vendor")

    monkeypatch.setattr(httpx.AsyncClient, "send", deny_outbound)
    endpoint = workspace_url + "/api/integrations/catalog"
    data = httpx.get(endpoint)
    data.raise_for_status()
    assert secret not in data.text and "sample-fixture-tenant" not in data.text
    provider = next(x for x in data.json()["providers"] if x["id"] == "workable")
    assert {op["task"]: op["state"] for op in provider["operations"]} == {
        "Candidate lookup": "configured",
        "Private notes": "needs_setup",
    }
    page = browser_page
    page.goto(workspace_url + "/connections/")
    page.get_by_label("Search provider or task").fill("Workable")
    expect(page.get_by_label("Setup provider")).to_have_value("workable")
    private = page.locator("summary").filter(has_text="Send a reviewed private note")
    expect(private).to_contain_text("Needs setup")
    private.click()
    expect(private.locator("..").get_by_text("WORKABLE_MEMBER_ID", exact=True)).to_be_visible()
    assert secret not in page.locator("body").inner_text()
    assert not outbound
