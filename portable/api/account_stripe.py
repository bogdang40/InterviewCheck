"""Checkout reservations and authenticated Stripe requests."""
from contextvars import ContextVar
import os
import re
from urllib.parse import urlsplit
from uuid import uuid4

from fastapi import HTTPException
from starlette.concurrency import run_in_threadpool

from . import account_db as store
from .provider_http import fetch_json, setting

browser_return_origin = ContextVar("browser_return_origin", default=None)

CHECKOUT_BLOCKING = {"active", "trialing", "past_due", "incomplete", "paused", "unpaid"}


class CheckoutExpiryRejected(HTTPException):
    def __init__(self):
        super().__init__(502, "Stripe rejected the checkout expiration. Try checkout again.")


def checkout_error(data):
    error = data.get("error") if isinstance(data, dict) else None
    if isinstance(error, dict) and error.get("type") == "invalid_request_error" and error.get("param") == "expires_at":
        return CheckoutExpiryRejected()


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
        raise HTTPException(503, "Billing return origin must be configured as HTTPS or loopback.")
    return base


async def stripe_request(method, path, *, fields=None, key=None, params=None):
    headers = {"Authorization": "Bearer " + setting("STRIPE_SECRET_KEY")}
    if key:
        headers["Idempotency-Key"] = key
    classify = checkout_error if method == "POST" and path == "checkout/sessions" else None
    return await fetch_json("Stripe", method, "https://api.stripe.com/v1/" + path, headers=headers, data=fields,
                            params=params, classify_bad_request=classify)


def resource_id(value, prefix):
    value = value.get("id") if isinstance(value, dict) else value
    if not isinstance(value, str) or not re.fullmatch(re.escape(prefix) + r"[A-Za-z0-9_]{1,230}", value):
        raise HTTPException(422, "Invalid Stripe resource identifier.")
    return value


def checkout_attempt(user_id, plan, base, *, replace_pending=None):
    ts = store.now() // 1000
    with store.connection(write=True) as db:
        sub = db.execute("""SELECT 1 FROM subscriptions WHERE user_id=? AND plan IN ('monthly','annual')
                         AND status IN ('active','trialing','past_due','incomplete','paused','unpaid') LIMIT 1""", (user_id,)).fetchone()
        if sub:
            raise HTTPException(409, "This account has a subscription. Use the billing portal.")
        row = db.execute("SELECT * FROM checkout_requests WHERE user_id=?", (user_id,)).fetchone()
        if row and row["expires_at"] > ts and (row["request_id"] != replace_pending or row["url"] is not None):
            if row["plan"] != plan:
                raise HTTPException(409, "A checkout is open for the other plan. Reopen that plan or wait for it to expire.")
            return dict(row)
        expires = ts + 3600
        request_id = str(uuid4())
        db.execute("""INSERT INTO checkout_requests(user_id,plan,request_id,expires_at,return_base)
                      VALUES(?,?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET plan=excluded.plan,request_id=excluded.request_id,
                      expires_at=excluded.expires_at,return_base=excluded.return_base,url=NULL""",
                   (user_id, plan, request_id, expires, base))
        return {"request_id": request_id, "expires_at": expires, "return_base": base, "url": None}


async def check_customer_subscriptions(customer, prices):
    params = {"customer": customer, "limit": 100}
    for _ in range(10):
        page = await stripe_request("GET", "subscriptions", params=params)
        try:
            items, more = page["data"], page["has_more"]
            if not isinstance(items, list) or type(more) is not bool or (more and not items):
                raise ValueError
            for subscription in items:
                if subscription["status"] in CHECKOUT_BLOCKING and any(
                    item["price"]["id"] in prices for item in subscription["items"]["data"]
                ):
                    raise HTTPException(409, "This account has a subscription. Use the billing portal.")
            if not more:
                return
            params["starting_after"] = resource_id(items[-1]["id"], "sub_")
        except (KeyError, TypeError, ValueError) as exc:
            raise HTTPException(502, "Stripe returned an invalid subscription list.") from exc
    raise HTTPException(503, "Could not confirm the current subscription state.")


async def checkout_session(user_id, customer, attempt, price):
    base, request_id = attempt["return_base"], attempt["request_id"]
    return await stripe_request("POST", "checkout/sessions", fields={
        "expires_at": str(attempt["expires_at"]), "mode": "subscription", "customer": customer,
        "client_reference_id": user_id, "line_items[0][price]": price, "line_items[0][quantity]": "1",
        "allow_promotion_codes": "true", "subscription_data[metadata][userId]": user_id,
        "metadata[userId]": user_id, "metadata[checkoutRequestId]": request_id,
        "success_url": base + "?status=success", "cancel_url": base + "?status=cancel"},
        key=f"interviewcheck-checkout:{user_id}:{request_id}")


async def create_link(user, plan=None, *, portal=False, request_id):
    prices = plans()
    if not prices or not os.getenv("STRIPE_SECRET_KEY") or not os.getenv("STRIPE_WEBHOOK_SECRET"):
        raise HTTPException(503, "Configure Stripe billing and the webhook secret.")
    if not portal and plan not in prices:
        raise HTTPException(400, "This plan is unavailable.")
    base = origin() + "/v1/billing/return"
    uid = user["id"]
    attempt = None if portal else await run_in_threadpool(checkout_attempt, uid, plan, base)
    if attempt and attempt["url"]:
        return {"url": attempt["url"]}
    customer = user["stripe_customer_id"]
    if customer and not portal:
        await check_customer_subscriptions(customer, prices.values())
    if not customer:
        data = await stripe_request("POST", "customers", fields={"email": user["email"], "metadata[userId]": uid},
                                    key="interviewcheck-customer:" + uid)
        customer = await run_in_threadpool(_save_customer, uid, resource_id(data.get("id"), "cus_"))
    if portal:
        data = await stripe_request("POST", "billing_portal/sessions", fields={"customer": customer, "return_url": base + "?status=portal"},
                                    key=f"interviewcheck-portal:{uid}:{request_id}")
        host = "billing.stripe.com"
    else:
        try:
            data = await checkout_session(uid, customer, attempt, prices[plan])
        except CheckoutExpiryRejected:
            if attempt["expires_at"] - store.now() / 1000 > 1860:
                raise
            # An exact idempotent retry reached Stripe validation instead of returning a saved session.
            attempt = await run_in_threadpool(checkout_attempt, uid, plan, base, replace_pending=attempt["request_id"])
            if attempt["url"]:
                return {"url": attempt["url"]}
            data = await checkout_session(uid, customer, attempt, prices[plan])
        request_id = attempt["request_id"]
        host = "checkout.stripe.com"
    link = data.get("url", "")
    if not isinstance(link, str) or urlsplit(link).scheme != "https" or urlsplit(link).netloc != host:
        raise HTTPException(502, "Stripe returned an invalid billing URL.")
    await run_in_threadpool(_record_link, uid, plan, portal, request_id, link)
    return {"url": link}


def _save_customer(uid, customer):
    with store.connection(write=True) as db:
        db.execute("UPDATE users SET stripe_customer_id=COALESCE(stripe_customer_id,?),updated_at=? WHERE id=?",
                   (customer, store.now(), uid))
        return db.execute("SELECT stripe_customer_id FROM users WHERE id=?", (uid,)).fetchone()[0]


def _record_link(uid, plan, portal, request_id, link):
    with store.connection(write=True) as db:
        if not portal:
            db.execute("UPDATE checkout_requests SET url=? WHERE user_id=? AND request_id=?", (link, uid, request_id))
        store.audit(db, "billing.portal" if portal else "billing.checkout_started", uid, uid, {"plan": plan})
