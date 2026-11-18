"""Verify Stripe's byte signature across the same ingress used by the app."""
import hashlib
import hmac
import time

import httpx


def test_webhook_signature_survives_ingress(workspace_url, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    secret = "whsec_synthetic_transport"
    monkeypatch.setenv("STRIPE_WEBHOOK_SECRET", secret)
    raw = '{"id":"evt_wire_fixture", "type":"unused.fixture","data":{"object":{"text":"café"}}}\n'.encode()
    timestamp = str(int(time.time()))
    signature = hmac.new(secret.encode(), timestamp.encode() + b"." + raw, hashlib.sha256).hexdigest()
    headers = {"Content-Type": "application/json", "Stripe-Signature": f"t={timestamp},v1={signature}"}
    with httpx.Client(base_url=workspace_url) as client:
        invalid = client.post("/v1/billing/webhook", content=raw.rstrip(), headers=headers)
        assert invalid.status_code == 400
        accepted = client.post("/v1/billing/webhook", content=raw, headers=headers)
        accepted.raise_for_status()
        assert accepted.json()["handled"] is False
