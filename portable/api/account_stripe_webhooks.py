"""Verify Stripe webhooks and apply account changes in one transaction."""
import json

from fastapi import HTTPException
from starlette.concurrency import run_in_threadpool

from . import account_db as store
from . import account_stripe as stripe_api
from .account_stripe import plans, resource_id
from .provider_http import setting

CHANGE = {"customer.subscription.created", "customer.subscription.updated", "customer.subscription.paused",
          "customer.subscription.resumed", "customer.subscription.deleted"}
STATES = {"active", "trialing", "past_due", "canceled", "unpaid", "incomplete", "incomplete_expired", "paused"}

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


def revision_before_fetch(eid, sid):
    with store.connection() as db:
        return None if applied(db, eid) else version(db, sid)


async def apply(event):
    event_type = event["type"]
    if event_type not in CHANGE and event_type != "checkout.session.completed":
        return {"received": True, "handled": False, "type": event_type}
    eid = resource_id(event.get("id"), "evt_")
    data = event.get("data")
    obj = data.get("object") if isinstance(data, dict) else None
    if not isinstance(obj, dict):
        raise HTTPException(422, "Stripe event is missing its resource.")
    checkout = event_type == "checkout.session.completed"
    if checkout and obj.get("mode") != "subscription":
        return {"received": True, "handled": False, "type": event_type}
    sid = resource_id(obj.get("subscription") if checkout else obj.get("id"), "sub_")
    customer = resource_id(obj.get("customer"), "cus_")
    before = await run_in_threadpool(revision_before_fetch, eid, sid)
    if before is None:
        return {"received": True, "handled": False, "type": event_type}
    deleted = event_type == "customer.subscription.deleted"
    sub = obj if deleted else await stripe_api.stripe_request("GET", "subscriptions/" + sid)
    mapped = normalized(sub, deleted)
    if mapped[:2] != (sid, customer):
        raise HTTPException(422, "Stripe subscription and event ownership disagree.")
    handled = await run_in_threadpool(record, eid, event_type, before, mapped, obj if checkout else None)
    return {"received": True, "handled": handled, "type": event_type}


def record(eid, event_type, before, mapped, checkout):
    sid, cust, status, price, plan, end, cancel, owner = mapped
    ts = store.now()
    with store.connection(write=True) as db:
        if applied(db, eid):
            return False
        if version(db, sid) != before:
            raise HTTPException(503, "Concurrent subscription change. Retry this event.")
        old = db.execute("SELECT status,user_id,stripe_customer_id,price_id,plan FROM subscriptions WHERE id=?", (sid,)).fetchone()
        user = db.execute("SELECT id FROM users WHERE stripe_customer_id=?", (cust,)).fetchone()
        if not user and old:
            user = db.execute("SELECT id FROM users WHERE id=?", (old["user_id"],)).fetchone()
        checkout_owner = checkout.get("client_reference_id") if checkout else None
        if not user or (owner and owner != user[0]) or (checkout_owner is not None and checkout_owner != user[0]):
            raise HTTPException(422, "Unknown or inconsistent billing customer.")
        uid = user[0]
        metadata = checkout.get("metadata") if checkout else None
        request_id = metadata.get("checkoutRequestId") if isinstance(metadata, dict) else None
        if isinstance(request_id, str):
            db.execute("DELETE FROM checkout_requests WHERE user_id=? AND request_id=?", (uid, request_id))
        if old and (old["user_id"] != uid or old["stripe_customer_id"] not in (None, cust)):
            raise HTTPException(422, "Subscription belongs to another account.")
        if not (old and old["status"] == "canceled" and status != "canceled"):
            if not plan and old and old["price_id"] == price:
                plan = old["plan"]
            db.execute("""INSERT INTO subscriptions(id,user_id,stripe_customer_id,status,price_id,plan,current_period_end,cancel_at_period_end,
                created_at,updated_at,status_changed_at) VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                stripe_customer_id=COALESCE(subscriptions.stripe_customer_id,excluded.stripe_customer_id),
                status=excluded.status,price_id=excluded.price_id,plan=excluded.plan,current_period_end=excluded.current_period_end,
                cancel_at_period_end=excluded.cancel_at_period_end,updated_at=excluded.updated_at,status_changed_at=CASE
                WHEN subscriptions.status=excluded.status THEN COALESCE(subscriptions.status_changed_at,excluded.status_changed_at)
                ELSE excluded.status_changed_at END""", (sid, uid, cust, status, price, plan, end, cancel, ts, ts, ts))
        db.execute("""INSERT INTO subscription_versions(id,version) VALUES(?,1) ON CONFLICT(id)
                      DO UPDATE SET version=version+1""", (sid,))
        db.execute("""INSERT INTO stripe_events(id,type,received_at,applied_at) VALUES(?,?,?,?)
                      ON CONFLICT(id) DO UPDATE SET applied_at=excluded.applied_at""", (eid, event_type, ts, ts))
        store.audit(db, "billing.subscription_synced", uid, details={"status": status, "subscriptionId": sid})
    return True
