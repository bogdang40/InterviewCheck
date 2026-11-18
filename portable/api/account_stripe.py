"""Stripe request construction and signed event processing."""
from contextvars import ContextVar
import json
import os
import re
from urllib.parse import urlsplit

from fastapi import HTTPException

from . import account_db as store
from .provider_http import fetch_json, setting

browser_return_origin = ContextVar("browser_return_origin", default=None)

CHANGE = {"customer.subscription.created", "customer.subscription.updated", "customer.subscription.paused",
          "customer.subscription.resumed", "customer.subscription.deleted"}
STATES = {"active", "trialing", "past_due", "canceled", "unpaid", "incomplete", "incomplete_expired", "paused"}


def plans():
    return {plan: value for plan in ("monthly", "annual") if (value := os.getenv("STRIPE_PRICE_" + plan.upper()))}


def origin():
    port = os.getenv("INTERVIEWCHECK_WEB_PORT")
    fallback = f"http://localhost:{port}" if port else "http://127.0.0.1:8765"
    default = os.getenv("INTERVIEWCHECK_PUBLIC_ORIGIN", "") or browser_return_origin.get() or fallback
    base = os.getenv("PUBLIC_BASE_URL", default).rstrip("/")
    url = urlsplit(base)
    if (url.scheme != "https" and (url.scheme != "http" or url.hostname not in {"localhost", "127.0.0.1", "::1"})) or (
        not url.hostname or url.username or url.password or url.query or url.fragment
    ):
        raise HTTPException(503, "Configure PUBLIC_BASE_URL as the HTTPS service origin or loopback.")
    return base


async def stripe_request(method, path, *, fields=None, key=None):
    headers = {"Authorization": "Bearer " + setting("STRIPE_SECRET_KEY")}
    if key:
        headers["Idempotency-Key"] = key
    return await fetch_json("Stripe", method, "https://api.stripe.com/v1/" + path, headers=headers, data=fields)


def resource_id(value, prefix):
    value = value.get("id") if isinstance(value, dict) else value
    if not isinstance(value, str) or not re.fullmatch(re.escape(prefix) + r"[A-Za-z0-9_]{1,230}", value):
        raise HTTPException(422, "Invalid Stripe resource identifier.")
    return value


def checkout_attempt(user_id, plan, request_id, base):
    ts = store.now() // 1000
    with store.connection(write=True) as db:
        sub = store.current_subscription(db, user_id)
        if sub and sub["status"] in {"active", "trialing", "past_due"} and sub["plan"] in {"monthly", "annual"}:
            raise HTTPException(409, "This account has a subscription. Use the billing portal.")
        row = db.execute("SELECT * FROM checkout_requests WHERE user_id=?", (user_id,)).fetchone()
        if row and row["expires_at"] > ts:
            if row["plan"] != plan:
                raise HTTPException(409, "A checkout is open for the other plan. Reopen that plan or wait for it to expire.")
            return dict(row)
        expires = ts + 3600
        db.execute("""INSERT INTO checkout_requests(user_id,plan,request_id,expires_at,return_base)
                      VALUES(?,?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET plan=excluded.plan,request_id=excluded.request_id,
                      expires_at=excluded.expires_at,return_base=excluded.return_base,url=NULL""",
                   (user_id, plan, request_id, expires, base))
        return {"request_id": request_id, "expires_at": expires, "return_base": base, "url": None}


async def create_link(user, plan=None, *, portal=False, request_id):
    prices = plans()
    if not prices or not os.getenv("STRIPE_SECRET_KEY") or not os.getenv("STRIPE_WEBHOOK_SECRET"):
        raise HTTPException(503, "Configure Stripe billing and the webhook secret.")
    if not portal and plan not in prices:
        raise HTTPException(400, "This plan is unavailable.")
    base = origin() + "/v1/billing/return"
    uid = user["id"]
    attempt = None if portal else checkout_attempt(uid, plan, request_id, base)
    if attempt and attempt["url"]:
        return {"url": attempt["url"]}
    customer = user["stripe_customer_id"]
    if not customer:
        data = await stripe_request("POST", "customers", fields={"email": user["email"], "metadata[userId]": uid},
                                    key="interviewcheck-customer:" + uid)
        customer = resource_id(data.get("id"), "cus_")
        with store.connection(write=True) as db:
            db.execute("UPDATE users SET stripe_customer_id=COALESCE(stripe_customer_id,?),updated_at=? WHERE id=?",
                       (customer, store.now(), uid))
            customer = db.execute("SELECT stripe_customer_id FROM users WHERE id=?", (uid,)).fetchone()[0]
    if portal:
        data = await stripe_request("POST", "billing_portal/sessions", fields={"customer": customer, "return_url": base + "?status=portal"},
                                    key=f"interviewcheck-portal:{uid}:{request_id}")
        host = "billing.stripe.com"
    else:
        base = attempt["return_base"]
        request_id = attempt["request_id"]
        data = await stripe_request("POST", "checkout/sessions", fields={
            "expires_at": str(attempt["expires_at"]),
            "mode": "subscription", "customer": customer, "client_reference_id": uid,
            "line_items[0][price]": prices[plan], "line_items[0][quantity]": "1", "allow_promotion_codes": "true",
            "subscription_data[metadata][userId]": uid, "metadata[userId]": uid,
            "success_url": base + "?status=success", "cancel_url": base + "?status=cancel"},
            key=f"interviewcheck-checkout:{uid}:{request_id}")
        host = "checkout.stripe.com"
    link = data.get("url", "")
    if not isinstance(link, str) or urlsplit(link).scheme != "https" or urlsplit(link).netloc != host:
        raise HTTPException(502, "Stripe returned an invalid billing URL.")
    with store.connection(write=True) as db:
        if not portal:
            db.execute("UPDATE checkout_requests SET url=? WHERE user_id=? AND request_id=?", (link, uid, request_id))
        store.audit(db, "billing.portal" if portal else "billing.checkout_started", uid, uid, {"plan": plan})
    return {"url": link}


def verify(raw, signature):
    import stripe
    secret = setting("STRIPE_WEBHOOK_SECRET")
    try:
        # Verify the raw bytes before parsing or accessing any event fields.
        stripe.WebhookSignature.verify_header(raw.decode("utf-8"), signature or "", secret, tolerance=300)
        stamps = [int(item[2:]) for item in (signature or "").split(",") if item.startswith("t=")]
        if len(stamps) != 1 or abs(store.now() / 1000 - stamps[0]) > 300:
            raise ValueError("Signature timestamp outside tolerance")
        event = json.loads(raw)
        if not isinstance(event, dict) or not isinstance(event.get("type"), str):
            raise ValueError("Invalid event")
    except (ValueError, UnicodeError, stripe.SignatureVerificationError) as exc:
        raise HTTPException(400, "Invalid Stripe event signature or payload.") from exc
    return event


def normalized(sub, deleted=False):
    try:
        sid = resource_id(sub["id"], "sub_")
        customer = resource_id(sub["customer"], "cus_")
        status = "canceled" if deleted else sub["status"]
        if status not in STATES:
            raise ValueError
        items = sub.get("items", {}).get("data", [])
        by_price = {price: plan for plan, price in plans().items()}
        item = next((item for item in items if item.get("price", {}).get("id") in by_price), items[0] if items else {})
        price = item.get("price", {}).get("id")
        period = item.get("current_period_end") or sub.get("current_period_end")
        if period is not None and (type(period) is not int or not 0 < period < 253402300799):
            raise ValueError
        owner = (sub.get("metadata") or {}).get("userId")
        return sid, customer, status, price, by_price.get(price), period * 1000 if period else None, bool(sub.get("cancel_at_period_end")), owner
    except (KeyError, ValueError, TypeError, AttributeError) as exc:
        raise HTTPException(422, "Invalid Stripe subscription payload.") from exc


def applied(db, eid):
    return db.execute("SELECT 1 FROM stripe_events WHERE id=? AND applied_at IS NOT NULL", (eid,)).fetchone()


def version(db, sid):
    row = db.execute("SELECT version FROM subscription_versions WHERE id=?", (sid,)).fetchone()
    return row[0] if row else 0


async def apply(event):
    event_type = event["type"]
    if event_type not in CHANGE and event_type != "checkout.session.completed":
        return {"received": True, "handled": False, "type": event_type}
    eid = resource_id(event.get("id"), "evt_")
    obj = (event.get("data") or {}).get("object")
    if not isinstance(obj, dict):
        raise HTTPException(422, "Stripe event is missing its resource.")
    checkout = event_type == "checkout.session.completed"
    if checkout and obj.get("mode") != "subscription":
        return {"received": True, "handled": False, "type": event_type}
    sid = resource_id(obj.get("subscription") if checkout else obj.get("id"), "sub_")
    customer = resource_id(obj.get("customer"), "cus_")
    with store.connection() as db:
        if applied(db, eid):
            return {"received": True, "handled": False, "type": event_type}
        before = version(db, sid)
    deleted = event_type == "customer.subscription.deleted"
    sub = obj if deleted else await stripe_request("GET", "subscriptions/" + sid)
    rid, cust, status, price, plan, end, cancel, owner = normalized(sub, deleted)
    if rid != sid or customer != cust:
        raise HTTPException(422, "Stripe subscription and event ownership disagree.")
    ts = store.now()
    with store.connection(write=True) as db:
        if applied(db, eid):
            return {"received": True, "handled": False, "type": event_type}
        if version(db, sid) != before:
            raise HTTPException(503, "Concurrent subscription change. Retry this event.")
        user = db.execute("SELECT id FROM users WHERE stripe_customer_id=?", (cust,)).fetchone()
        if not user or (owner and owner != user[0]) or (checkout and obj.get("client_reference_id") not in {None, user[0]}):
            raise HTTPException(422, "Unknown or inconsistent billing customer.")
        uid = user[0]
        if checkout:
            db.execute("DELETE FROM checkout_requests WHERE user_id=?", (uid,))
        old = db.execute("SELECT status,user_id FROM subscriptions WHERE id=?", (sid,)).fetchone()
        if old and old["user_id"] != uid:
            raise HTTPException(422, "Subscription belongs to another account.")
        if not (old and old["status"] == "canceled" and status != "canceled"):
            db.execute("""INSERT INTO subscriptions(id,user_id,status,price_id,plan,current_period_end,cancel_at_period_end,
                created_at,updated_at,status_changed_at) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                status=excluded.status,price_id=excluded.price_id,plan=excluded.plan,current_period_end=excluded.current_period_end,
                cancel_at_period_end=excluded.cancel_at_period_end,updated_at=excluded.updated_at,status_changed_at=CASE
                WHEN subscriptions.status=excluded.status THEN COALESCE(subscriptions.status_changed_at,excluded.status_changed_at)
                ELSE excluded.status_changed_at END""", (sid, uid, status, price, plan, end, cancel, ts, ts, ts))
        db.execute("""INSERT INTO subscription_versions(id,version) VALUES(?,1) ON CONFLICT(id)
                      DO UPDATE SET version=version+1""", (sid,))
        db.execute("""INSERT INTO stripe_events(id,type,received_at,applied_at) VALUES(?,?,?,?)
                      ON CONFLICT(id) DO UPDATE SET applied_at=excluded.applied_at""", (eid, event_type, ts, ts))
        store.audit(db, "billing.subscription_synced", uid, details={"status": status, "subscriptionId": sid})
    return {"received": True, "handled": True, "type": event_type}
