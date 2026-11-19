"""Tier 2 opaque-box boundary tests for F5 (Dynamic Model Resolution) and F9 (Framing, Sanitization, Backups)."""
import json

import pytest

from e2e_suite.harness import signup_user

ADMIN_EMAILS = ("admin1@example.test",)
BOOTSTRAP_SECRET = "e2e-bootstrap-secret-1234"


def _model_payload(**overrides):
    data = {
        "slug": "t2-res-openai",
        "display_name": "Tier 2 Resolution OpenAI",
        "provider": "openai",
        "capability": "reference",
        "model_id": "gpt-4o",
        "apiKey": "sk-tier2-resolution-secret-5566",
        "enabled": True,
        "is_default": False,
    }
    data.update(overrides)
    return data


@pytest.mark.tier2
def test_authoring_providers_and_models_track_registry_toggles_and_capabilities(e2e_workspace):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as admin:
        signup_user(admin, email="admin1@example.test", admin_secret=BOOTSTRAP_SECRET)

        assert admin.get("/api/authoring/providers").json() == []
        assert admin.get("/api/authoring/models").json() == {"models": []}

        # Registering a reference model makes it available for both reference and question_planning fallback.
        ref = admin.post("/api/admin/models", json=_model_payload(slug="ref-primary", is_default=True))
        assert ref.status_code == 201
        ref_id = ref.json()["model"]["id"]

        # Registering a dedicated question_planning openai_compatible model scopes to question_planning only.
        qp = admin.post(
            "/api/admin/models",
            json=_model_payload(
                slug="qp-compat",
                provider="openai_compatible",
                capability="question_planning",
                endpoint="https://example.com/v1",
                apiKey=None,
            ),
        )
        assert qp.status_code == 201
        qp_id = qp.json()["model"]["id"]

        ref_providers = admin.get("/api/authoring/providers?capability=reference").json()
        qp_providers = admin.get("/api/authoring/providers?capability=question_planning").json()
        assert "OpenAI" in ref_providers and "qp-compat" not in ref_providers
        assert "OpenAI" in qp_providers and "qp-compat" in qp_providers

        models_list = admin.get("/api/authoring/models").json()["models"]
        assert {m["slug"] for m in models_list} == {"ref-primary", "qp-compat"}
        assert "sk-tier2" not in json.dumps(models_list)

        # Toggling off immediately removes models from authoring discovery.
        assert admin.post(f"/api/admin/models/{qp_id}/toggle", json={"enabled": False}).status_code == 200
        assert "qp-compat" not in admin.get("/api/authoring/providers?capability=question_planning").json()
        assert admin.post(f"/api/admin/models/{ref_id}/toggle", json={"enabled": False}).status_code == 200
        assert admin.get("/api/authoring/providers").json() == []
        assert admin.get("/api/authoring/models").json() == {"models": []}


@pytest.mark.tier2
def test_dynamic_resolution_fails_closed_503_across_authoring_scoring_and_audio(e2e_workspace):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)
    with e2e_workspace.client() as admin:
        signup_user(admin, email="admin1@example.test", admin_secret=BOOTSTRAP_SECRET)

        # No models configured -> 503 across all AI/transcription routes.
        assert admin.post("/api/authoring/questions", json={"provider": "OpenAI", "role": "SRE", "description": "On-call"}).status_code == 503
        assert admin.post("/api/authoring/reference", json={"provider": "OpenAI", "style": "Spoken answer", "role": "SRE", "question": "Q?"}).status_code == 503
        assert admin.post("/api/integrations/reference", json={"role": "SRE", "question": "Q?"}).status_code == 503
        assert admin.post("/api/scoring/semantic", json={"answer": "A", "references": [{"label": "R", "text": "T", "permitted": False}]}).status_code == 503
        assert admin.post("/api/scoring/judge", json={"question": "Q?", "answer": "A"}).status_code == 503
        assert admin.post(
            "/api/integrations/transcribe",
            content=b"RIFFdata",
            headers={"x-send-audio": "deepgram", "content-type": "audio/wav"},
        ).status_code == 503

        # Permitted-only references in /api/scoring/semantic short-circuit cleanly with available=False.
        permitted_only = admin.post(
            "/api/scoring/semantic",
            json={"answer": "Candidate answer", "references": [{"label": "Permitted", "text": "Allowed note", "permitted": True}]},
        )
        assert permitted_only.status_code == 200
        assert permitted_only.json() == {"available": False, "reason": "No non-permitted references supplied.", "matches": []}

        # Disabled embedding/judge/transcription models still fail 503 and flip status flags to False.
        emb = admin.post("/api/admin/models", json=_model_payload(slug="emb-off", capability="embedding", enabled=False)).json()["model"]
        jdg = admin.post("/api/admin/models", json=_model_payload(slug="jdg-off", capability="judge", enabled=False)).json()["model"]
        dg = admin.post(
            "/api/admin/models",
            json=_model_payload(slug="dg-off", provider="deepgram", capability="transcription", model_id="nova-2", enabled=False),
        ).json()["model"]
        st = admin.get("/api/integrations/status").json()
        assert st["embedding"] is False and st["judge"] is False and st["transcription"] is False
        assert admin.post("/api/scoring/semantic", json={"answer": "A", "references": [{"label": "R", "text": "T"}], "model_slug": emb["slug"]}).status_code == 503
        assert admin.post("/api/scoring/judge", json={"question": "Q?", "answer": "A", "model_slug": jdg["slug"]}).status_code == 503
        assert admin.post(
            "/api/integrations/transcribe",
            content=b"RIFFdata",
            headers={"x-send-audio": "deepgram", "content-type": "audio/wav"},
        ).status_code == 503

        # Enabling flips status flags to True.
        assert admin.post(f"/api/admin/models/{emb['id']}/toggle", json={"enabled": True}).status_code == 200
        assert admin.post(f"/api/admin/models/{jdg['id']}/toggle", json={"enabled": True}).status_code == 200
        assert admin.post(f"/api/admin/models/{dg['id']}/toggle", json={"enabled": True}).status_code == 200
        st_on = admin.get("/api/integrations/status").json()
        assert st_on["embedding"] is True and st_on["judge"] is True and st_on["transcription"] is True


@pytest.mark.tier2
def test_disabled_db_model_suppresses_env_fallback_and_status_updates(e2e_workspace, monkeypatch):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)
    monkeypatch.setenv("OPENAI_API_KEY", "sk-env-fallback-secret-9999")
    monkeypatch.setenv("INTERVIEWCHECK_REFERENCE_MODEL", "gpt-4o")
    e2e_workspace.restart()

    with e2e_workspace.client() as admin:
        signup_user(admin, email="admin1@example.test", admin_secret=BOOTSTRAP_SECRET)
        assert admin.get("/api/integrations/status").json()["reference"] is True
        assert "OpenAI" in admin.get("/api/authoring/providers?capability=reference").json()

        env_summary = admin.get("/api/admin/models").json()["envFallbacks"]
        assert any(item["provider"] == "openai" and item["capability"] == "reference" and item["configured"] is True for item in env_summary)
        assert "sk-env-fallback" not in json.dumps(env_summary)

        # Registering a disabled OpenAI reference model suppresses the env fallback.
        disabled_ref = admin.post("/api/admin/models", json=_model_payload(slug="oa-disabled", enabled=False))
        assert disabled_ref.status_code == 201
        assert admin.get("/api/integrations/status").json()["reference"] is False
        assert "OpenAI" not in admin.get("/api/authoring/providers?capability=reference").json()
        assert admin.post("/api/integrations/reference", json={"role": "Eng", "question": "Q?"}).status_code == 503


@pytest.mark.tier2
def test_authoring_lineup_and_ai_input_validation_boundaries(e2e_workspace):
    with e2e_workspace.client() as client:
        # Duplicate (provider, style) and > 12 reference limits fail 422 before external dispatch.
        dup = client.post(
            "/api/authoring/references",
            json={
                "role": "Staff",
                "question": "Explain consensus.",
                "existing_reference_count": 0,
                "pairs": [
                    {"provider": "OpenAI", "style": "Spoken answer"},
                    {"provider": "OpenAI", "style": "Spoken answer"},
                ],
            },
        )
        assert dup.status_code == 422

        over_limit = client.post(
            "/api/authoring/references",
            json={
                "role": "Staff",
                "question": "Explain consensus.",
                "existing_reference_count": 11,
                "pairs": [
                    {"provider": "OpenAI", "style": "Spoken answer"},
                    {"provider": "OpenAI", "style": "Talking points"},
                ],
            },
        )
        assert over_limit.status_code == 422

        # AI endpoint size and strict schema boundaries.
        assert client.post("/api/integrations/reference", json={"role": "Eng", "question": "Q" * 4001}).status_code == 422
        assert client.post("/api/integrations/reference", json={"role": "Eng", "question": ""}).status_code == 422
        assert client.post(
            "/api/authoring/reference",
            json={"provider": "OpenAI", "style": "Spoken answer", "role": "Eng", "question": "   "},
        ).status_code == 422
        assert client.post("/api/scoring/semantic", json={"answer": "A" * 24001, "references": [{"label": "L", "text": "T"}]}).status_code == 422
        assert client.post("/api/scoring/semantic", json={"answer": "A", "references": []}).status_code == 422
        assert client.post("/api/scoring/judge", json={"question": "Q", "answer": "A", "extra": 1}).status_code == 422
        assert client.post("/api/scoring/judge", json={"question": "Q", "answer": "A", "signals": {"ratio": True}}).status_code == 422

        # Transcribe preflight header and media-type boundaries before model lookup.
        assert client.post("/api/integrations/transcribe", content=b"123", headers={"content-type": "audio/wav"}).status_code == 400
        assert client.post(
            "/api/integrations/transcribe",
            content=b"123",
            headers={"x-send-audio": "deepgram", "content-type": "text/plain"},
        ).status_code == 415
        # Empty audio fails 422 only after transcription model resolution; with no model it fails 503.
        assert client.post(
            "/api/integrations/transcribe",
            content=b"",
            headers={"x-send-audio": "deepgram", "content-type": "audio/wav"},
        ).status_code == 503


@pytest.mark.tier2
def test_error_sanitization_and_workspace_backup_excludes_model_secrets(e2e_workspace, monkeypatch):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET)
    monkeypatch.setenv("WORKABLE_API_KEY", "wk-secret-123456")
    monkeypatch.setenv("WORKABLE_SUBDOMAIN", "bad domain!")
    monkeypatch.setenv("IMAP_HOST", "mail.example.test")
    monkeypatch.setenv("IMAP_USERNAME", "user")
    monkeypatch.setenv("IMAP_PASSWORD", "pass")
    monkeypatch.setenv("IMAP_FOLDER", "INBOX\rINJECT")

    with e2e_workspace.client() as admin:
        signup_user(admin, email="admin1@example.test", admin_secret=BOOTSTRAP_SECRET)

        # Integration 503 responses never leak env var names or secrets.
        wk_err = admin.post("/api/integrations/ats/workable/lookup", json={"email": "cand@example.test"})
        assert wk_err.status_code == 503
        for leaked in ("WORKABLE_API_KEY", "WORKABLE_SUBDOMAIN", "wk-secret-123456"):
            assert leaked not in wk_err.text

        imap_err = admin.post("/api/integrations/calendar/sync/imap")
        assert imap_err.status_code == 503
        for leaked in ("IMAP_FOLDER", "IMAP_PASSWORD", "IMAP_HOST"):
            assert leaked not in imap_err.text

        # SSRF rejection with embedded userinfo secret never echoes the secret in error JSON.
        ssrf_err = admin.post(
            "/api/admin/models",
            json=_model_payload(
                slug="ssrf-secret-echo",
                provider="openai_compatible",
                endpoint="https://op:sk-topsecret-userinfo-9999@example.com/v1",
                apiKey=None,
            ),
        )
        assert ssrf_err.status_code == 400
        assert "sk-topsecret-userinfo-9999" not in ssrf_err.text

        # Create workspace role + session + connected model and verify backup excludes all model/secret data.
        assert admin.post("/api/roles", json={"name": "Security Role", "description": "Desc", "questions": ["Q1"]}).status_code == 201
        assert admin.post("/api/sessions", json={"candidate": "Ada", "role": "Security Role", "policy": "Notes allowed", "consent": True}).status_code == 201
        created = admin.post(
            "/api/admin/models",
            json=_model_payload(slug="backup-isolation", apiKey="sk-backup-isolation-7777"),
        )
        assert created.status_code == 201

        backup_resp = admin.get("/api/backups/workspace")
        assert backup_resp.status_code == 200
        body = backup_resp.text
        for forbidden in (
            "connected_models",
            "encrypted_api_key",
            "key_hint",
            "sk-backup-isolation-7777",
            "7777",
            "e2e-deterministic-test-secret-key",
            "backup-isolation",
        ):
            assert forbidden not in body
