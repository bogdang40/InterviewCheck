"""Tier 1 opaque-box Model Admin API and auth boundary smoke tests."""
from uuid import uuid4

import pytest

from e2e_suite.harness import login_user, signup_user

ADMIN_EMAILS = ("admin1@example.test", "admin2@example.test")
BOOTSTRAP_SECRET = "e2e-bootstrap-secret-1234"


def _openai_payload(**overrides):
    payload = {
        "slug": "e2e-openai-ref",
        "display_name": "E2E OpenAI Reference",
        "provider": "openai",
        "capability": "reference",
        "model_id": "gpt-4o",
        "apiKey": "sk-e2e-initial-key-1234",
        "parameters": {"temperature": 0.3, "max_tokens": 900, "timeout_s": 25.0, "fallback_priority": 10},
        "enabled": True,
        "is_default": True,
    }
    payload.update(overrides)
    return payload


@pytest.mark.tier1
def test_admin_routes_fail_closed_and_require_csrf(e2e_workspace):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)
    target_id = str(uuid4())
    routes = (
        ("GET", "/api/admin/models", None),
        ("POST", "/api/admin/models", _openai_payload()),
        ("PATCH", f"/api/admin/models/{target_id}", {"display_name": "Updated"}),
        ("POST", f"/api/admin/models/{target_id}/toggle", {"enabled": False}),
        ("POST", f"/api/admin/models/{target_id}/probe", None),
        ("DELETE", f"/api/admin/models/{target_id}", None),
    )

    # Unauthenticated and forged-cookie calls must return 401.
    with e2e_workspace.client() as anon:
        for method, path, body in routes:
            resp = anon.request(method, path, json=body)
            assert resp.status_code == 401, (method, path, resp.text)
            forged = anon.request(
                method,
                path,
                json=body,
                headers={"Cookie": "ic_access=mm_forged_invalid_token_abcdefghijklmnopqrstuvwxyz1234"},
            )
            assert forged.status_code == 401, (method, path, forged.text)

    # Non-admin authenticated member must receive 403 on all admin routes.
    with e2e_workspace.client() as member:
        signup_user(member, email="member@example.test")
        for method, path, body in routes:
            resp = member.request(method, path, json=body)
            assert resp.status_code == 403, (method, path, resp.text)

    # Authenticated admin without X-InterviewCheck CSRF header must fail with 403 on mutations.
    with e2e_workspace.client() as admin_client:
        info = signup_user(admin_client, email="admin1@example.test", admin_secret=BOOTSTRAP_SECRET)
        assert info.get("admin") is True
        cookie_header = "; ".join(f"{k}={v}" for k, v in admin_client.cookies.items())

    with e2e_workspace.client(headers={"X-InterviewCheck": ""}) as no_csrf:
        no_csrf.headers.pop("X-InterviewCheck", None)
        no_csrf.headers["Cookie"] = cookie_header
        assert no_csrf.get("/api/admin/models").status_code == 200
        assert no_csrf.post("/api/admin/models", json=_openai_payload()).status_code == 403
        assert no_csrf.patch(f"/api/admin/models/{target_id}", json={"display_name": "No CSRF"}).status_code == 403
        assert no_csrf.delete(f"/api/admin/models/{target_id}").status_code == 403


@pytest.mark.tier1
def test_multi_admin_model_crud_toggle_probe_and_restart_persistence(e2e_workspace):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)

    secret_one = "sk-e2e-first-secret-1111"
    secret_two = "sk-e2e-second-secret-2222"

    with e2e_workspace.client() as admin1:
        s1 = signup_user(admin1, email="admin1@example.test", admin_secret=BOOTSTRAP_SECRET)
        assert s1.get("admin") is True

        initial = admin1.get("/api/admin/models")
        assert initial.status_code == 200
        initial_json = initial.json()
        assert initial_json["models"] == []
        assert "openai" in initial_json["providers"]

        created = admin1.post("/api/admin/models", json=_openai_payload(apiKey=secret_one))
        assert created.status_code == 201, created.text
        assert secret_one not in created.text
        model = created.json()["model"]
        model_id = model["id"]
        assert model["hasKey"] is True
        assert model["key_hint"] == "...1111"
        assert model["status"] == "unverified"

        # Update metadata without apiKey preserves existing encrypted key.
        patched = admin1.patch(f"/api/admin/models/{model_id}", json={"display_name": "OpenAI Primary"})
        assert patched.status_code == 200
        assert patched.json()["model"]["display_name"] == "OpenAI Primary"
        assert patched.json()["model"]["key_hint"] == "...1111"

        # Rotate key via PATCH updates key_hint without exposing plaintext secret.
        rotated = admin1.patch(f"/api/admin/models/{model_id}", json={"apiKey": secret_two})
        assert rotated.status_code == 200
        assert secret_two not in rotated.text
        assert rotated.json()["model"]["key_hint"] == "...2222"

        # Probe with synthetic key returns explicit error JSON without crashing.
        probed = admin1.post(f"/api/admin/models/{model_id}/probe")
        assert probed.status_code in (400, 502, 504), probed.text
        probe_body = probed.json()
        assert probe_body["detail"]
        assert probe_body["model"]["status"] == "error"
        assert probe_body["model"]["last_error"]
        assert secret_two not in probed.text

        # Toggle off and back on.
        disabled = admin1.post(f"/api/admin/models/{model_id}/toggle", json={"enabled": False})
        assert disabled.status_code == 200
        assert disabled.json()["model"]["enabled"] is False
        assert disabled.json()["model"]["status"] == "disabled"

        enabled = admin1.post(f"/api/admin/models/{model_id}/toggle", json={"enabled": True})
        assert enabled.status_code == 200
        assert enabled.json()["model"]["enabled"] is True
        assert enabled.json()["model"]["status"] == "error"

    # Restart server against same temp SQLite DBs and verify persistence via second admin.
    e2e_workspace.restart()
    with e2e_workspace.client() as admin2:
        s2 = signup_user(admin2, email="admin2@example.test", admin_secret=BOOTSTRAP_SECRET)
        assert s2.get("admin") is True
        listed = admin2.get("/api/admin/models")
        assert listed.status_code == 200
        models = listed.json()["models"]
        assert len(models) == 1
        assert models[0]["id"] == model_id
        assert models[0]["display_name"] == "OpenAI Primary"
        assert models[0]["key_hint"] == "...2222"
        assert secret_two not in listed.text

        deleted = admin2.delete(f"/api/admin/models/{model_id}")
        assert deleted.status_code == 200
        assert deleted.json() == {"deleted": True, "id": model_id}
        assert admin2.get("/api/admin/models").json()["models"] == []


@pytest.mark.tier1
@pytest.mark.parametrize(
    ("bad_payload", "expected_status"),
    [
        (_openai_payload(provider="openai_compatible", endpoint="http://127.0.0.1/v1", apiKey=None), 400),
        (_openai_payload(provider="openai_compatible", endpoint="https://127.0.0.1/v1", apiKey=None), 400),
        (_openai_payload(provider="openai_compatible", endpoint="https://169.254.169.254/v1", apiKey=None), 400),
        (_openai_payload(provider="openai_compatible", endpoint="https://localhost/v1", apiKey=None), 400),
        (_openai_payload(provider="openai_compatible", endpoint="https://metadata.internal/v1", apiKey=None), 400),
        (_openai_payload(provider="openai_compatible", endpoint="https://user:pass@api.example.com/v1", apiKey=None), 400),
        (_openai_payload(provider="deepgram", capability="reference"), 422),
        (_openai_payload(apiKey=""), 422),
        (_openai_payload(parameters={"temperature": 2.5}), 422),
        (_openai_payload(extra_field="forbidden"), 422),
    ],
)
def test_ssrf_and_invalid_model_configs_leave_zero_partial_rows(e2e_workspace, bad_payload, expected_status):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as admin:
        signup_user(admin, email="admin1@example.test", admin_secret=BOOTSTRAP_SECRET)
        resp = admin.post("/api/admin/models", json=bad_payload)
        assert resp.status_code == expected_status, resp.text
        assert admin.get("/api/admin/models").json()["models"] == []


@pytest.mark.tier1
def test_admin_login_after_logout_preserves_model_access(e2e_workspace):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as admin:
        signup_user(admin, email="admin1@example.test", admin_secret=BOOTSTRAP_SECRET)
        assert admin.post("/api/integrations/logout").status_code == 200
        assert admin.get("/api/admin/models").status_code == 401
        logged_in = login_user(admin, email="admin1@example.test")
        assert logged_in.get("admin") is True
        assert admin.get("/api/admin/models").status_code == 200


@pytest.mark.tier1
@pytest.mark.m2_gated
@pytest.mark.xfail(strict=False, reason="Requires M2 CSRF enforcement on /v1/* routes.")
def test_m2_v1_mutations_require_csrf_header(e2e_workspace):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client(headers={"X-InterviewCheck": ""}) as raw:
        raw.headers.pop("X-InterviewCheck", None)
        resp = raw.post("/v1/auth/login", json={"email": "admin1@example.test", "password": "Synthetic-E2E-Pass-9876"})
        assert resp.status_code == 403
