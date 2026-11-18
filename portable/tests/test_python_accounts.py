import hashlib
import hmac
import json
import time
from unittest.mock import AsyncMock

from fastapi.testclient import TestClient
import pytest

from api import account_db as db, account_stripe as billing
from api.account_server import app as standalone
from api.main import app

C = {"email": "operator@example.invalid", "password": "fixture-password"}
A = "/api/integrations/"
V = "/v1/"


@pytest.fixture
def embedded(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite"))
    monkeypatch.setenv("INTERVIEWCHECK_OPERATOR_EMAIL", C["email"])
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_URL", raising=False)
    monkeypatch.delenv("INTERVIEWCHECK_PUBLIC_ORIGIN", raising=False)
    monkeypatch.delenv("INTERVIEWCHECK_SIGNUP_SECRET", raising=False)
    monkeypatch.setenv("TRIAL_DAYS", "0")
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_fixture")
    monkeypatch.setenv("STRIPE_WEBHOOK_SECRET", "whsec_fixture")
    monkeypatch.setenv("STRIPE_PRICE_MONTHLY", "price_month")
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as test:
        yield test


def event(kind, obj, eid="evt_one"):
    return {"id": eid, "type": kind, "data": {"object": obj}}


def send(test, evt, *, ts=None, corrupt=False):
    raw = json.dumps(evt).encode()
    ts = ts or int(time.time())
    sig = hmac.new(b"whsec_fixture", str(ts).encode() + b"." + raw, hashlib.sha256).hexdigest()
    return test.post(V + "billing/webhook", content=raw + (b" " if corrupt else b""),
                     headers={"Content-Type": "application/json", "stripe-signature": f"t={ts},v1={sig}"})


def test_embedded_workspace_lifecycle(embedded, monkeypatch):
    c = embedded
    monkeypatch.setenv("TRIAL_DAYS", "2")
    assert c.get(A + "status").json()["access"]
    assert c.get("/api/sessions").status_code == 401
    assert c.post(A + "access/signup", json=C).status_code == 200
    assert c.get("/api/sessions").status_code == 200
    assert c.get(A + "account").json() == {"email": C["email"], "active": True}
    auth = {"Authorization": "Bearer " + c.cookies["ic_access"]}
    assert c.get(V + "me", headers=auth).json()["entitlement"]["source"] == "trial"
    with db.connection() as conn:
        user = conn.execute("select * from users").fetchone()
        stored = conn.execute("select * from sessions").fetchone()
        assert user["password_hash"].startswith("scrypt$32768$8$1$")
        assert stored["token_hash"] == db.digest(c.cookies["ic_access"])
        assert C["password"] not in str(dict(user))
    assert c.post(A + "logout").status_code == 200
    assert c.get(V + "me", headers=auth).status_code == 401
    assert c.get("/api/sessions").status_code == 401
    assert c.post(A + "access/login", json={**C, "password":"incorrect-fixture"}).status_code == 401
    assert c.post(A + "access/login", json=C).status_code == 200
    assert c.post(A + "access/signup", json=C).status_code == 409
    assert c.post(V + "auth/signup", json={**C, "email":"other@example.invalid"}).status_code == 403


def test_standalone_service_requires_signup_invitation(embedded, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_SIGNUP_SECRET", "fixture invitation")
    with TestClient(standalone) as test:
        assert test.post(V + "auth/signup", json=C).status_code == 403
        result = test.post(V + "auth/signup", json={**C, "inviteCode": "fixture invitation"})
        assert result.status_code == 201
        assert test.get(V + "me", headers={"Authorization":"Bearer " + result.json()["token"]}).status_code == 200
        assert test.get("/api/sessions").status_code == 404


def test_signup_bounded_and_limited(embedded):
    assert embedded.post(V + "auth/signup", content="x" * 270000, headers={"content-type":"application/json"}).status_code == 413
    for _ in range(10):
        assert embedded.post(V + "auth/login", json=C).status_code == 401
    assert embedded.post(V + "auth/login", json=C).status_code == 429


def test_webhook_verifies_exact_body_and_timestamp(embedded):
    payload = event("example.ignore", {})
    assert send(embedded, payload, corrupt=True).status_code == 400
    assert send(embedded, payload, ts=int(time.time()) - 400).status_code == 400
    assert send(embedded, payload, ts=int(time.time()) + 400).status_code == 400
    assert send(embedded, payload).json()["handled"] is False


def test_checkout_webhook_portal_and_replay(embedded, monkeypatch):
    c = embedded
    c.post(A + "access/signup", json=C).raise_for_status()
    assert c.get("/api/sessions").status_code == 402
    remote = AsyncMock(side_effect=[{"id":"cus_fixture"}, {"url":"https://checkout.stripe.com/c/fixture"}])
    monkeypatch.setattr(billing, "stripe_request", remote)
    assert c.post(A + "billing/checkout", json={"plan":"monthly"}).json() == {"url":"https://checkout.stripe.com/c/fixture"}
    assert remote.await_args.kwargs["fields"]["line_items[0][price]"] == "price_month"
    assert remote.await_args.kwargs["fields"]["customer"] == "cus_fixture"
    previous_count = remote.await_count
    duplicate = c.post(A + "billing/checkout", json={"plan":"monthly"})
    assert duplicate.status_code == 200 and remote.await_count == previous_count
    uid = remote.await_args.kwargs["fields"]["client_reference_id"]
    sub = {"id":"sub_fixture", "customer":"cus_fixture", "status":"active", "items":{"data":[{"price":{"id":"price_month"},
           "current_period_end":int(time.time()) + 86400}]}, "metadata":{"userId":uid}}
    checkout = event("checkout.session.completed", {"subscription":"sub_fixture", "customer":"cus_fixture",
                     "mode":"subscription", "client_reference_id":uid})
    remote.side_effect = None
    remote.return_value = sub
    assert send(c, checkout).json()["handled"] is True
    assert send(c, checkout).json()["handled"] is False
    assert c.get("/api/sessions").status_code == 200
    assert c.post(A + "billing/checkout", json={"plan":"monthly"}).status_code == 409
    remote.return_value = {"url":"https://billing.stripe.com/p/session/fixture"}
    assert c.post(A + "billing/portal", json={}).json()["url"].startswith("https://billing.stripe.com/")
    removed = event("customer.subscription.deleted", sub, "evt_deleted")
    assert send(c, removed).json()["handled"] is True
    remote.return_value = sub
    assert send(c, event("customer.subscription.updated", sub, "evt_delayed")).status_code == 200
    assert c.get("/api/sessions").status_code == 402
    stranger = {**sub, "customer":"cus_other"}
    remote.return_value = stranger
    assert send(c, event("customer.subscription.created", stranger, "evt_unknown")).status_code == 422
    with db.connection() as conn:
        assert conn.execute("select 1 from stripe_events where id='evt_unknown'").fetchone() is None


def test_admin_can_grant_and_revoke_with_audit(embedded, monkeypatch):
    admin_code = "fixture bootstrap"
    monkeypatch.setenv("ADMIN_EMAILS", C["email"])
    monkeypatch.setenv("ADMIN_BOOTSTRAP_SECRET", admin_code)
    admin = embedded.post(A + "access/signup", json={**C, "adminSecret": admin_code}).json()
    assert admin["admin"] is True and admin["active"]
    auth = {"Authorization": "Bearer " + embedded.cookies["ic_access"]}
    me = embedded.get(V + "me", headers=auth).json()["user"]
    assert embedded.patch(A + "admin/users/" + me["id"], json={"role":"user"}).status_code == 409
    assert embedded.patch(A + "admin/users/" + me["id"], json={"disabled":True}).status_code == 409
    monkeypatch.setenv("INTERVIEWCHECK_SIGNUP_SECRET", "fixture invite")
    with TestClient(standalone) as service:
        person = service.post(V + "auth/signup", json={**C, "email":"member@example.invalid", "inviteCode":"fixture invite"})
        person.raise_for_status()
        uid = person.json()["user"]["id"]
        personal = {"Authorization": "Bearer " + person.json()["token"]}
        assert service.get(V + "admin/stats", headers=personal).status_code == 403
        assert embedded.get(A + "admin/users?q=member").json()["users"][0]["user"]["id"] == uid
        grant = embedded.patch(A + "admin/users/" + uid, json={"complimentaryUntil":"2099-01-01T00:00:00Z"})
        assert grant.json()["entitlement"]["source"] == "complimentary"
        assert embedded.patch(A + "admin/users/" + uid, json={"complimentaryUntil":None}).json()["entitlement"]["active"] is False
        assert embedded.patch(A + "admin/users/" + uid, json={"disabled":True}).status_code == 200
        assert service.get(V + "me", headers=personal).status_code == 401
    audit = embedded.get(A + "admin/audit").json()["entries"]
    assert sum(item["action"] == "admin.update_user" for item in audit) == 3


def test_compatible_node_schema_and_hash(embedded):
    # Generated by node:crypto.scryptSync with the upstream production parameters.
    import sqlite3
    salt = "AAECAwQFBgcICQoLDA0ODw=="
    key = "FM0xZIf3kkduZNb8J9si8eNNJ0FiRExlHDV18xQRxiDwpPuFLlVYPKPNnLGr251ipv3AoRakDDpU08Scov6/cg=="
    password = "existing-node-account"
    uid = "11111111-2222-4333-8444-555555555555"
    with sqlite3.connect(db.database()) as conn:
        for statement in db.SCHEMA:
            conn.execute(statement)
        # The Node access service's initial schema predates both columns.
        conn.execute("ALTER TABLE subscriptions DROP COLUMN status_changed_at")
        conn.execute("ALTER TABLE stripe_events DROP COLUMN applied_at")
        conn.execute("PRAGMA user_version=1")
        encoded = f"scrypt$32768$8$1${salt}${key}"
        conn.execute("""INSERT INTO users (id,email,password_hash,role,disabled,created_at,updated_at)
                        VALUES(?,?,?,'admin',0,?,?)""",(uid,C["email"],encoded,db.now(),db.now()))
    assert embedded.post(A + "access/login", json={**C,"password":password}).json()["admin"]


def test_custom_browser_origin_for_checkout(embedded, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_WEB_PORT","3107")
    remote = AsyncMock(side_effect=[{"id":"cus_fixture"},{"url":"https://checkout.stripe.com/c/fixture"}])
    monkeypatch.setattr(billing,"stripe_request",remote)
    embedded.post(A + "access/signup",json=C).raise_for_status()
    embedded.post(A + "billing/checkout",json={"plan":"monthly"},headers={"x-forwarded-host":"localhost:3107"}).raise_for_status()
    assert remote.await_args.kwargs["fields"]["success_url"] == "http://localhost:3107/v1/billing/return?status=success"
    assert "/account/" in embedded.get(V + "billing/return").text
