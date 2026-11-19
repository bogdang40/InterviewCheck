"""Tier 1 opaque-box route, viewport layout, audio mock, and header smoke tests."""
import pytest
from playwright.sync_api import expect

from e2e_suite.harness import (
    assert_no_horizontal_overflow,
    capture_screenshot,
    install_audio_mock,
)

PRIMARY_ROUTES = (
    ("/", "Interview workspace"),
    ("/interviews/", "Interviews"),
    ("/interviews/new/", "New interview"),
    ("/interviews/review/", None),
    ("/interviews/brief/", "Review brief"),
    ("/roles/", "Role library"),
    ("/connections/", "Connections"),
    ("/data/", "Data"),
    ("/account/", "Account"),
    ("/sample/", "Sample review"),
    ("/trash/", "Trash"),
)


@pytest.mark.tier1
@pytest.mark.parametrize(("route", "expected_heading"), PRIMARY_ROUTES)
def test_primary_routes_render_cleanly_desktop(e2e_workspace, desktop_page, route, expected_heading):
    page, collector = desktop_page
    response = page.goto(e2e_workspace.base_url + route, wait_until="domcontentloaded")
    assert response is not None and response.status == 200
    expect(page.locator("main#main-content")).to_be_visible()
    if expected_heading:
        expect(page.get_by_role("heading", name=expected_heading).first).to_be_visible()
    assert_no_horizontal_overflow(page)
    capture_screenshot(page, e2e_workspace.screenshot_dir, f"route_{route.strip('/') or 'overview'}", "1440x900")
    collector.assert_clean()


@pytest.mark.tier1
@pytest.mark.parametrize(("route", "expected_heading"), PRIMARY_ROUTES)
def test_primary_routes_render_cleanly_mobile(e2e_workspace, mobile_page, route, expected_heading):
    page, collector = mobile_page
    response = page.goto(e2e_workspace.base_url + route, wait_until="domcontentloaded")
    assert response is not None and response.status == 200
    expect(page.locator("main#main-content")).to_be_visible()
    if expected_heading:
        expect(page.get_by_role("heading", name=expected_heading).first).to_be_visible()
    assert_no_horizontal_overflow(page)
    capture_screenshot(page, e2e_workspace.screenshot_dir, f"route_{route.strip('/') or 'overview'}", "390x844")
    collector.assert_clean()


@pytest.mark.tier1
def test_macos_playwright_audio_mock_acquires_track_without_stalling(e2e_workspace, desktop_page):
    page, collector = desktop_page
    install_audio_mock(page)
    page.goto(e2e_workspace.base_url + "/", wait_until="domcontentloaded")
    result = page.evaluate(
        """async () => {
          const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
          const kinds = stream.getTracks().map(track => ({ kind: track.kind, readyState: track.readyState }));
          for (const track of stream.getTracks()) track.stop();
          return kinds;
        }"""
    )
    assert result == [{"kind": "audio", "readyState": "live"}]
    collector.assert_clean()


@pytest.mark.tier1
def test_baseline_security_headers_on_api_and_html(e2e_workspace):
    with e2e_workspace.client() as client:
        api_resp = client.get("/api/health")
        assert api_resp.status_code == 200
        assert api_resp.headers.get("x-content-type-options") == "nosniff"
        assert api_resp.headers.get("x-frame-options") == "DENY"
        assert api_resp.headers.get("referrer-policy") == "no-referrer"
        assert api_resp.headers.get("cache-control") == "no-store"

        html_resp = client.get("/")
        assert html_resp.status_code == 200
        assert html_resp.headers.get("x-content-type-options") == "nosniff"
        assert html_resp.headers.get("x-frame-options") == "DENY"


@pytest.mark.tier1
def test_m2_security_headers_csp_and_permissions_policy(e2e_workspace):
    with e2e_workspace.client() as client:
        resp = client.get("/api/health")
        assert resp.status_code == 200
        assert "content-security-policy" in {k.lower() for k in resp.headers.keys()}
        assert "permissions-policy" in {k.lower() for k in resp.headers.keys()}


@pytest.mark.tier1
def test_m3_admin_route_renders_without_errors(e2e_workspace, desktop_page, mobile_page):
    for page, collector, viewport_label in (
        (*desktop_page, "1440x900"),
        (*mobile_page, "390x844"),
    ):
        response = page.goto(e2e_workspace.base_url + "/admin/", wait_until="domcontentloaded")
        assert response is not None and response.status == 200
        expect(page.locator("main#main-content")).to_be_visible()
        assert_no_horizontal_overflow(page)
        capture_screenshot(page, e2e_workspace.screenshot_dir, "route_admin", viewport_label)
        collector.assert_clean()
