"""Tier 2 opaque-box boundary and corner-case tests for F3, F4, and F6 (Model Registry, Admin API, SSRF)."""
import pytest

from e2e_suite.harness import signup_user

ADMIN_EMAILS = ("admin1@example.test", "admin2@example.test")
BOOTSTRAP_SECRET = "e2e-bootstrap-secret-1234"


def _payload(**overrides):
    data = {
        "slug": "t2-openai-ref",
        "display_name": "Tier 2 OpenAI",
        "provider": "openai",
        "capability": "reference",
        "model_id": "gpt-4o",
        "apiKey": "sk-tier2-initial-secret-9001",
        "parameters": {"temperature": 0.4, "max_tokens": 512, "timeout_s": 30.0, "fallback_priority": 100},
        "enabled": True,
        "is_default": False,
    }
    data.update(overrides)
    return data


@pytest.mark.tier2
@pytest.mark.parametrize(
    ("overrides", "expected_status"),
    [
        ({"slug": "a"}, 422),
        ({"slug": "ab"}, 201),
        ({"slug": "a" * 64}, 201),
        ({"slug": "a" * 65}, 422),
        ({"slug": "-ab"}, 422),
        ({"slug": "ab-"}, 422),
        ({"slug": "UpperCase"}, 422),
        ({"slug": "under_score"}, 422),
        ({"slug": "openai"}, 422),
        ({"slug": "anthropic"}, 422),
        ({"slug": "azure_openai"}, 422),
        ({"slug": "azure-openai"}, 422),
        ({"slug": "deepgram"}, 422),
        ({"slug": "openai_compatible"}, 422),
        ({"slug": "openai-compatible"}, 422),
        ({"display_name": ""}, 422),
        ({"display_name": "   "}, 422),
        ({"display_name": "X"}, 201),
        ({"display_name": "D" * 120}, 201),
        ({"display_name": "D" * 121}, 422),
        ({"display_name": "Bad\x00Name"}, 422),
        ({"display_name": "Bad\nName"}, 422),
        ({"model_id": ""}, 422),
        ({"model_id": "m"}, 201),
        ({"model_id": "m" * 180}, 201),
        ({"model_id": "m" * 181}, 422),
        ({"model_id": "gpt..4o"}, 422),
        ({"model_id": "org//model"}, 422),
        ({"model_id": "-gpt-4o"}, 422),
    ],
)
def test_model_string_length_pattern_and_reserved_slug_boundaries(e2e_workspace, overrides, expected_status):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as admin:
        signup_user(admin, email="admin1@example.test", admin_secret=BOOTSTRAP_SECRET)
        resp = admin.post("/api/admin/models", json=_payload(**overrides))
        assert resp.status_code == expected_status, resp.text
        count = len(admin.get("/api/admin/models").json()["models"])
        assert count == (1 if expected_status == 201 else 0)


@pytest.mark.tier2
@pytest.mark.parametrize(
    ("params", "expected_status"),
    [
        ({"temperature": -0.1}, 422),
        ({"temperature": 0.0}, 201),
        ({"temperature": 2.0}, 201),
        ({"temperature": 2.1}, 422),
        ({"temperature": "0.5"}, 422),
        ({"temperature": True}, 422),
        ({"max_tokens": 0}, 422),
        ({"max_tokens": 1}, 201),
        ({"max_tokens": 128000}, 201),
        ({"max_tokens": 128001}, 422),
        ({"max_tokens": 100.0}, 422),
        ({"max_tokens": "100"}, 422),
        ({"max_tokens": True}, 422),
        ({"timeout_s": 0.9}, 422),
        ({"timeout_s": 1.0}, 201),
        ({"timeout_s": 180.0}, 201),
        ({"timeout_s": 180.1}, 422),
        ({"timeout_s": "10.0"}, 422),
        ({"fallback_priority": -1}, 422),
        ({"fallback_priority": 0}, 201),
        ({"fallback_priority": 10000}, 201),
        ({"fallback_priority": 10001}, 422),
        ({"fallback_priority": 10.0}, 422),
        ({"fallback_priority": "10"}, 422),
    ],
)
def test_model_numeric_bounds_and_strict_json_type_rejections(e2e_workspace, params, expected_status):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as admin:
        signup_user(admin, email="admin1@example.test", admin_secret=BOOTSTRAP_SECRET)
        resp = admin.post("/api/admin/models", json=_payload(parameters=params))
        assert resp.status_code == expected_status, resp.text
        assert len(admin.get("/api/admin/models").json()["models"]) == (1 if expected_status == 201 else 0)


@pytest.mark.tier2
@pytest.mark.parametrize(
    ("overrides", "expected_status"),
    [
        ({"provider": "azure_openai", "endpoint": "https://westus.openai.azure.com", "api_version": None}, 422),
        ({"provider": "azure_openai", "endpoint": "https://westus.openai.azure.com", "api_version": "1"}, 201),
        ({"provider": "azure_openai", "endpoint": "https://eastus.cognitiveservices.azure.com/", "api_version": "v" * 64}, 201),
        ({"provider": "azure_openai", "endpoint": "https://westus.openai.azure.com", "api_version": "v" * 65}, 422),
        ({"provider": "azure_openai", "endpoint": "https://westus.openai.azure.com", "api_version": "2024/02"}, 422),
        ({"provider": "azure_openai", "endpoint": "https://evil.example.com", "api_version": "2024-06-01"}, 400),
        ({"provider": "azure_openai", "endpoint": "https://openai.azure.com", "api_version": "2024-06-01"}, 400),
        ({"provider": "azure_openai", "endpoint": "https://westus.openai.azure.com/openai", "api_version": "2024-06-01"}, 400),
        ({"provider": "openai", "api_version": "2024-06-01"}, 422),
        ({"provider": "openai_compatible", "endpoint": "https://example.com/v1", "api_version": "2024-06-01", "apiKey": None}, 422),
        ({"provider": "openai", "endpoint": "https://api.openai.com/v1"}, 422),
        ({"provider": "anthropic", "capability": "embedding"}, 422),
        ({"provider": "deepgram", "capability": "judge"}, 422),
        ({"provider": "openai", "capability": "transcription"}, 422),
    ],
)
def test_azure_api_version_host_allowlist_and_capability_boundaries(e2e_workspace, overrides, expected_status):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as admin:
        signup_user(admin, email="admin1@example.test", admin_secret=BOOTSTRAP_SECRET)
        resp = admin.post("/api/admin/models", json=_payload(**overrides))
        assert resp.status_code == expected_status, resp.text
        if expected_status == 201:
            assert resp.json()["model"]["endpoint"] in (
                "https://westus.openai.azure.com",
                "https://eastus.cognitiveservices.azure.com",
            )


@pytest.mark.tier2
@pytest.mark.parametrize(
    ("endpoint", "expected_status"),
    [
        ("http://example.com/v1", 400),
        ("https://127.0.0.1/v1", 400),
        ("https://10.0.0.1/v1", 400),
        ("https://172.16.0.1/v1", 400),
        ("https://192.168.1.1/v1", 400),
        ("https://169.254.169.254/latest/meta-data", 400),
        ("https://[::1]/v1", 400),
        ("https://[::ffff:127.0.0.1]/v1", 400),
        ("https://[fe80::1]/v1", 400),
        ("https://2130706433/v1", 400),
        ("https://0x7f000001/v1", 400),
        ("https://0177.0.0.1/v1", 400),
        ("https://user:pass@example.com/v1", 400),
        ("https://example.com:8443/v1", 400),
        ("https://localhost/v1", 400),
        ("https://api.localhost/v1", 400),
        ("https://svc.internal/v1", 400),
        ("https://printer.local/v1", 400),
        ("https://router.home.arpa/v1", 400),
        ("https://example.com/v1?key=1", 400),
        ("https://example.com/v1#frag", 400),
        ("https://example.com/v1\\admin", 400),
        ("https://example.com/../secret", 400),
        ("https://example.com//v1", 400),
        ("https://nxdomain-e2e-check.invalid/v1", 400),
        ("https://example.com:443/v1/", 201),
    ],
)
def test_ssrf_ipv4_ipv6_numeric_userinfo_port_and_dns_boundaries(e2e_workspace, endpoint, expected_status):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as admin:
        signup_user(admin, email="admin1@example.test", admin_secret=BOOTSTRAP_SECRET)
        resp = admin.post(
            "/api/admin/models",
            json=_payload(provider="openai_compatible", endpoint=endpoint, apiKey=None),
        )
        assert resp.status_code == expected_status, (endpoint, resp.text)
        if expected_status == 201:
            assert resp.json()["model"]["endpoint"] == "https://example.com/v1"


@pytest.mark.tier2
def test_patch_clear_api_key_key_rotation_and_null_field_boundaries(e2e_workspace):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as admin:
        signup_user(admin, email="admin1@example.test", admin_secret=BOOTSTRAP_SECRET)

        # Required-key providers reject clearApiKey=True while openai_compatible allows it.
        req_ids = []
        for idx, (prov, cap, extra) in enumerate([
            ("openai", "reference", {}),
            ("anthropic", "reference", {}),
            ("deepgram", "transcription", {"model_id": "nova-2"}),
            ("azure_openai", "reference", {"endpoint": "https://westus.openai.azure.com", "api_version": "2024-06-01"}),
        ]):
            r = admin.post("/api/admin/models", json=_payload(slug=f"req-{idx}", provider=prov, capability=cap, **extra))
            assert r.status_code == 201, r.text
            req_ids.append(r.json()["model"]["id"])

        for mid in req_ids:
            cleared = admin.patch(f"/api/admin/models/{mid}", json={"clearApiKey": True})
            assert cleared.status_code == 422

        # Empty patch, null non-nullable fields, and clearApiKey + apiKey conflict all fail 422.
        primary_id = req_ids[0]
        assert admin.patch(f"/api/admin/models/{primary_id}", json={}).status_code == 422
        assert admin.patch(f"/api/admin/models/{primary_id}", json={"display_name": None}).status_code == 422
        assert admin.patch(f"/api/admin/models/{primary_id}", json={"parameters": {"fallback_priority": None}}).status_code == 422
        assert admin.patch(f"/api/admin/models/{primary_id}", json={"clearApiKey": True, "apiKey": "sk-new-9999"}).status_code == 422

        # Metadata patch preserves key_hint; key rotation updates key_hint and persists across restart.
        meta_patch = admin.patch(f"/api/admin/models/{primary_id}", json={"display_name": "Preserved Key"})
        assert meta_patch.status_code == 200
        assert meta_patch.json()["model"]["key_hint"] == "...9001"
        assert meta_patch.json()["model"]["hasKey"] is True

        rotated = admin.patch(f"/api/admin/models/{primary_id}", json={"apiKey": "sk-short"})
        assert rotated.status_code == 200
        assert rotated.json()["model"]["key_hint"] == "****"
        assert "sk-short" not in rotated.text

        # openai_compatible supports optional key, rotation, and clearApiKey.
        compat = admin.post(
            "/api/admin/models",
            json=_payload(slug="compat-clear", provider="openai_compatible", endpoint="https://example.com/v1", apiKey="sk-compat-key-7788"),
        )
        assert compat.status_code == 201
        cid = compat.json()["model"]["id"]
        assert compat.json()["model"]["key_hint"] == "...7788"
        cleared_compat = admin.patch(f"/api/admin/models/{cid}", json={"clearApiKey": True})
        assert cleared_compat.status_code == 200
        assert cleared_compat.json()["model"]["hasKey"] is False
        assert cleared_compat.json()["model"]["key_hint"] is None

    e2e_workspace.restart()
    with e2e_workspace.client() as admin2:
        signup_user(admin2, email="admin2@example.test", admin_secret=BOOTSTRAP_SECRET)
        models = {m["id"]: m for m in admin2.get("/api/admin/models").json()["models"]}
        assert models[primary_id]["key_hint"] == "****"
        assert models[cid]["hasKey"] is False


@pytest.mark.tier2
def test_registry_default_atomicity_slug_conflicts_filtering_and_secret_key_mismatch(e2e_workspace, monkeypatch):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as admin:
        signup_user(admin, email="admin1@example.test", admin_secret=BOOTSTRAP_SECRET)

        # Auto-generated slug when omitted and atomic default replacement per capability.
        m1 = admin.post("/api/admin/models", json=_payload(slug=None, is_default=True)).json()["model"]
        assert m1["slug"] and m1["is_default"] is True
        m2 = admin.post("/api/admin/models", json=_payload(slug="second-ref", is_default=True)).json()["model"]
        m_judge = admin.post(
            "/api/admin/models",
            json=_payload(slug="judge-def", capability="judge", is_default=True),
        ).json()["model"]

        all_models = {m["id"]: m for m in admin.get("/api/admin/models").json()["models"]}
        assert all_models[m1["id"]]["is_default"] is False
        assert all_models[m2["id"]]["is_default"] is True
        assert all_models[m_judge["id"]]["is_default"] is True

        # Duplicate slug on POST or PATCH yields 409 without modifying state.
        dup_post = admin.post("/api/admin/models", json=_payload(slug="second-ref"))
        assert dup_post.status_code == 409
        dup_patch = admin.patch(f"/api/admin/models/{m1['id']}", json={"slug": "second-ref"})
        assert dup_patch.status_code == 409

        # Query filtering and UUID/enum path validation.
        judges = admin.get("/api/admin/models?capability=judge&provider=openai").json()["models"]
        assert [m["id"] for m in judges] == [m_judge["id"]]
        assert admin.get("/api/admin/models?capability=invalid").status_code == 422
        assert admin.patch("/api/admin/models/not-a-uuid", json={"display_name": "X"}).status_code == 422
        assert admin.post("/api/admin/models/not-a-uuid/toggle", json={"enabled": False}).status_code == 422
        assert admin.post("/api/admin/models/00000000-0000-4000-8000-000000000000/toggle", json={"enabled": False}).status_code == 404
        assert admin.post(f"/api/admin/models/{m1['id']}/toggle", json={"enabled": "false"}).status_code == 422

    # Changing master encryption key and restarting causes probe to fail gracefully (502) without crashing.
    monkeypatch.setenv("INTERVIEWCHECK_MODEL_SECRET_KEY", "rotated-different-master-key")
    e2e_workspace.restart()
    with e2e_workspace.client() as admin2:
        signup_user(admin2, email="admin2@example.test", admin_secret=BOOTSTRAP_SECRET)
        probed = admin2.post(f"/api/admin/models/{m2['id']}/probe")
        assert probed.status_code == 502
        body = probed.json()
        assert body["model"]["status"] == "error"
        assert "decrypted" in body["detail"].lower()
        assert "sk-tier2" not in probed.text
