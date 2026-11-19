"""Tier 2 opaque-box boundary tests for F8 exports XSS/CSP/CSV and F9 status/catalog minimization."""
import json
import re

import pytest

from e2e_suite.harness import signup_user

ADMIN_EMAILS = ("admin1@example.test",)
BOOTSTRAP_SECRET = "e2e-bootstrap-secret-1234"


@pytest.mark.tier2
def test_status_and_catalog_minimization_across_auth_tiers(e2e_workspace, monkeypatch):
    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET, trial_days="0")
    monkeypatch.setenv("DEEPGRAM_API_KEY", "dg-secret-key-minimization")
    monkeypatch.setenv("ASHBY_API_KEY", "ashby-secret-minimization")
    e2e_workspace.restart()

    with e2e_workspace.client() as anon:
        st = anon.get("/api/integrations/status")
        assert st.status_code == 200
        assert st.json() == {"access": True, "inviteRequired": False, "signedIn": False}
        assert anon.get("/api/integrations/catalog").status_code == 401

    with e2e_workspace.client() as unentitled:
        signup_user(unentitled, email="unentitled@example.test")
        st = unentitled.get("/api/integrations/status")
        assert st.status_code == 200
        assert st.json() == {"access": True, "inviteRequired": False, "signedIn": True}
        assert unentitled.get("/api/integrations/catalog").status_code == 402

    e2e_workspace.configure_embedded_auth(admin_emails=ADMIN_EMAILS, bootstrap_secret=BOOTSTRAP_SECRET, trial_days="3")
    with e2e_workspace.client() as admin, e2e_workspace.client() as member:
        signup_user(admin, email="admin1@example.test", admin_secret=BOOTSTRAP_SECRET)
        admin.post(
            "/api/admin/models",
            json={
                "slug": "cat-oa-ref",
                "display_name": "Catalog OpenAI",
                "provider": "openai",
                "capability": "reference",
                "model_id": "gpt-4o",
                "apiKey": "sk-catalog-secret-4321",
            },
        ).raise_for_status()

        signup_user(member, email="entitled@example.test")
        member_status = member.get("/api/integrations/status").json()
        assert member_status["signedIn"] is True and member_status["transcription"] is True
        assert "ashby" in member_status["ats"]

        member_cat = member.get("/api/integrations/catalog").json()["providers"]
        assert all(op["alternatives"] == [] and op["optional"] == [] for p in member_cat for op in p["operations"])
        serialized = json.dumps(member_cat)
        assert "DEEPGRAM_API_KEY" not in serialized
        assert "ADMIN_BOOTSTRAP_SECRET" not in serialized
        assert "...4321" not in serialized

        admin_cat = admin.get("/api/integrations/catalog").json()["providers"]
        admin_serialized = json.dumps(admin_cat)
        assert "DEEPGRAM_API_KEY" in admin_serialized
        assert "...4321" in admin_serialized


@pytest.mark.tier2
def test_exports_print_xss_escaping_csp_print_js_and_csv_formula_neutralization(e2e_workspace):
    xss = '<script>alert("xss")</script><img src=x onerror=alert(1)>'
    with e2e_workspace.client() as client:
        sess = client.post(
            "/api/sessions",
            json={
                "candidate": f"=SUM(1,1) {xss}",
                "role": f"+cmd {xss}",
                "policy": f"-policy {xss}",
                "permitted_sources": [{"label": f"@label {xss}", "text": f"Ref {xss}"}],
                "consent": True,
            },
        )
        assert sess.status_code == 201
        sid = sess.json()["id"]

        ans = client.post(
            f"/api/sessions/{sid}/answers",
            json={
                "question": f"=Q {xss}",
                "answer": f"@A {xss}",
                "references": [{"label": f"Src {xss}", "text": f"SrcText {xss}", "permitted": False}],
            },
        )
        assert ans.status_code == 201
        aid = ans.json()["id"]
        assert client.patch(
            f"/api/sessions/{sid}/answers/{aid}",
            json={"disposition": "explained", "note": f"=NOTE {xss}"},
        ).status_code == 200

        printed = client.get(f"/api/sessions/{sid}/print")
        assert printed.status_code == 200
        assert "<script>alert" not in printed.text
        assert "<img src=x" not in printed.text
        assert "&lt;script&gt;alert" in printed.text
        assert "onclick=" not in printed.text
        assert '<script src="/api/exports/print.js" defer></script>' in printed.text
        assert len(re.findall(r"<script\b", printed.text)) == 1
        csp = printed.headers["content-security-policy"]
        assert "script-src 'self'" in csp and "'unsafe-inline'" not in csp
        assert "frame-ancestors 'none'" in csp

        js = client.get("/api/exports/print.js")
        assert js.status_code == 200
        assert "application/javascript" in js.headers["content-type"]
        assert "print-report" in js.text and "window.print()" in js.text

        csv_resp = client.get("/api/exports/interviews.csv")
        assert csv_resp.status_code == 200
        assert "'=SUM(1,1)" in csv_resp.text
        assert "'+cmd" in csv_resp.text
        assert "'-policy" in csv_resp.text
        assert "'=NOTE" in csv_resp.text
