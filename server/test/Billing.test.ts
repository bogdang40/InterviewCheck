import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { SignedInResponse } from "../src/services/AuthService.js";
import type { AccessSnapshot } from "../src/services/EntitlementService.js";
import { CheckoutExpiryRejected, type GatewaySubscription } from "../src/stripe/StripeGateway.js";
import { buildHarness, get, json, post, type TestHarness } from "./support/TestContainer.js";

const DAY = 24 * 60 * 60 * 1000;

describe("billing", () => {
  let harness: TestHarness;
  let token: string;
  let userId: string;

  beforeEach(async () => {
    harness = buildHarness();
    const signup = await json<SignedInResponse>(await post(harness.app, "/v1/auth/signup", { email: "payer@example.com", password: "a-long-password" }));
    token = signup.token;
    userId = signup.user.id;
  });

  afterEach(() => {
    harness.container.close();
  });

  function liveSubscription(customerId: string, overrides: Partial<GatewaySubscription> = {}): GatewaySubscription {
    return {
      id: "sub_live",
      customerId,
      status: "active",
      priceId: "price_annual",
      currentPeriodEnd: new Date(harness.clock.now.getTime() + 365 * DAY),
      cancelAtPeriodEnd: false,
      metadataUserId: userId,
      ...overrides,
    };
  }

  it("lists configured plans without authentication", async () => {
    const body = await json<{ configured: boolean; plans: string[] }>(await get(harness.app, "/v1/billing/plans"));
    expect(body).toEqual({ configured: true, plans: ["monthly", "annual"] });
  });

  it("creates a checkout session bound to the user and a Stripe customer", async () => {
    const response = await post(harness.app, "/v1/billing/checkout", { plan: "annual" }, token);
    expect(response.status).toBe(200);
    const body = await json<{ url: string }>(response);
    expect(body.url).toContain("price_annual");
    const request = harness.gateway.checkouts[0];
    expect(request?.userId).toBe(userId);
    expect(request?.successUrl).toContain("/v1/billing/return?status=success");
    expect(harness.container.users.findById(userId)?.stripeCustomerId).toBe(request?.customerId);
  });

  it("reuses an open checkout and prevents another plan from opening", async () => {
    const first = await post(harness.app, "/v1/billing/checkout", { plan: "monthly" }, token);
    const repeated = await post(harness.app, "/v1/billing/checkout", { plan: "monthly" }, token);
    expect(await json(repeated)).toEqual(await json(first));
    expect((await post(harness.app, "/v1/billing/checkout", { plan: "annual" }, token)).status).toBe(409);
    expect(harness.gateway.checkouts).toHaveLength(1);
  });

  it("retries the same provider request after a lost response", async () => {
    const checkout = vi.spyOn(harness.gateway, "createCheckoutSession");
    checkout.mockRejectedValueOnce(new Error("test transport interruption"));
    const user = harness.container.users.requireById(userId);
    await expect(harness.container.billing.createCheckout(user, "monthly")).rejects.toThrow("transport interruption");
    harness.clock.now = new Date(harness.clock.now.getTime() + 1000);
    await expect(harness.container.billing.createCheckout(user, "monthly")).resolves.toHaveProperty("url");
    expect(checkout.mock.calls[1]).toEqual(checkout.mock.calls[0]);
    expect(harness.gateway.customers.size).toBe(1);
  });

  it("blocks a new checkout after the first expires if Stripe has a subscription and the webhook is late", async () => {
    await post(harness.app, "/v1/billing/checkout", { plan: "monthly" }, token);
    harness.gateway.seedSubscription(liveSubscription(harness.gateway.checkouts[0]!.customerId));
    harness.clock.now = new Date(harness.clock.now.getTime() + 3_600_000);
    expect((await post(harness.app, "/v1/billing/checkout", { plan: "annual" }, token)).status).toBe(409);
    expect(harness.gateway.checkouts).toHaveLength(1);
    expect(harness.container.subscriptions.currentForUser(userId)).toBeNull();
  });

  it("replaces a pending checkout after Stripe rejects the stale expiration on retry", async () => {
    const checkout = vi.spyOn(harness.gateway, "createCheckoutSession");
    checkout.mockRejectedValueOnce(new Error("test transport interruption")).mockRejectedValueOnce(new CheckoutExpiryRejected());
    const user = harness.container.users.requireById(userId);
    await expect(harness.container.billing.createCheckout(user, "monthly")).rejects.toThrow("transport interruption");
    harness.clock.now = new Date(harness.clock.now.getTime() + 31 * 60_000);
    await expect(harness.container.billing.createCheckout(user, "monthly")).resolves.toHaveProperty("url");
    expect(checkout).toHaveBeenCalledTimes(3);
    const original = checkout.mock.calls[0]![0];
    const retry = checkout.mock.calls[1]![0];
    const replacement = checkout.mock.calls[2]![0];
    expect(retry).toEqual(original);
    expect(replacement.requestId).not.toBe(original.requestId);
    expect(replacement.expiresAt).toBe(original.expiresAt + 31 * 60);
  });

  it("rejects unknown plans and unauthenticated checkout", async () => {
    expect((await post(harness.app, "/v1/billing/checkout", { plan: "lifetime" }, token)).status).toBe(400);
    expect((await post(harness.app, "/v1/billing/checkout", { plan: "monthly" })).status).toBe(401);
  });

  it("returns 503 when Stripe is not configured", async () => {
    harness.container.close();
    harness = buildHarness({ STRIPE_PRICE_MONTHLY: undefined, STRIPE_PRICE_ANNUAL: undefined });
    const signup = await json<SignedInResponse>(await post(harness.app, "/v1/auth/signup", { email: "nostripe@example.com", password: "a-long-password" }));
    expect((await post(harness.app, "/v1/billing/checkout", { plan: "monthly" }, signup.token)).status).toBe(503);
  });

  it("unlocks the account when checkout completes and the subscription is live", async () => {
    await post(harness.app, "/v1/billing/checkout", { plan: "annual" }, token);
    const customerId = harness.gateway.checkouts[0]!.customerId;
    harness.gateway.seedSubscription(liveSubscription(customerId));
    harness.gateway.nextEvent = { id: "evt_1", type: "checkout.completed", customerId, subscriptionId: "sub_live", clientReferenceId: userId,
      checkoutRequestId: harness.gateway.checkouts[0]!.requestId };

    const webhook = await harness.app.request("/v1/billing/webhook", { method: "POST", body: "{}", headers: { "stripe-signature": "sig" } });
    expect(webhook.status).toBe(200);
    expect(await json(webhook)).toMatchObject({ received: true, handled: true, type: "checkout.completed" });

    const me = await json<AccessSnapshot>(await get(harness.app, "/v1/me", token));
    expect(me.entitlement).toMatchObject({ active: true, source: "subscription", plan: "annual" });
    expect(me.subscription?.status).toBe("active");
    expect((await post(harness.app, "/v1/billing/checkout", { plan: "monthly" }, token)).status).toBe(409);
  });

  it("is idempotent for redelivered events", async () => {
    await post(harness.app, "/v1/billing/checkout", { plan: "monthly" }, token);
    const customerId = harness.gateway.checkouts[0]!.customerId;
    const sub = liveSubscription(customerId, { id: "sub_dup", priceId: "price_monthly" });
    harness.gateway.seedSubscription(sub);
    harness.gateway.nextEvent = { id: "evt_dup", type: "subscription.changed", subscription: sub };
    expect(await json(await harness.app.request("/v1/billing/webhook", { method: "POST", body: "{}" }))).toMatchObject({ handled: true });
    harness.gateway.nextEvent = { id: "evt_dup", type: "subscription.changed", subscription: sub };
    expect(await json(await harness.app.request("/v1/billing/webhook", { method: "POST", body: "{}" }))).toMatchObject({ handled: false });
  });

  it("revokes access when the subscription is deleted", async () => {
    await post(harness.app, "/v1/billing/checkout", { plan: "monthly" }, token);
    const customerId = harness.gateway.checkouts[0]!.customerId;
    const sub = liveSubscription(customerId, { id: "sub_gone", priceId: "price_monthly" });
    harness.gateway.seedSubscription(sub);
    harness.gateway.nextEvent = { id: "evt_a", type: "subscription.changed", subscription: sub };
    await harness.app.request("/v1/billing/webhook", { method: "POST", body: "{}" });
    expect((await json<AccessSnapshot>(await get(harness.app, "/v1/me", token))).entitlement.active).toBe(true);

    harness.gateway.nextEvent = { id: "evt_b", type: "subscription.deleted", subscription: sub };
    await harness.app.request("/v1/billing/webhook", { method: "POST", body: "{}" });
    const me = await json<AccessSnapshot>(await get(harness.app, "/v1/me", token));
    expect(me.entitlement.active).toBe(false);
    expect(me.subscription?.status).toBe("canceled");
  });

  it("resolves the user by customer id when metadata is missing", async () => {
    await post(harness.app, "/v1/billing/checkout", { plan: "monthly" }, token);
    const customerId = harness.gateway.checkouts[0]!.customerId;
    const sub = liveSubscription(customerId, { id: "sub_meta", priceId: "price_monthly", metadataUserId: null });
    harness.gateway.seedSubscription(sub);
    harness.gateway.nextEvent = { id: "evt_meta", type: "subscription.changed", subscription: sub };
    expect((await harness.app.request("/v1/billing/webhook", { method: "POST", body: "{}" })).status).toBe(200);
    expect(harness.container.subscriptions.findById("sub_meta")?.userId).toBe(userId);
  });

  it("renews a known legacy subscription without rebinding its customer", async () => {
    await post(harness.app, "/v1/billing/checkout", { plan: "monthly" }, token);
    const preferred = harness.gateway.checkouts[0]!.customerId;
    const sub = liveSubscription("cus_legacy", { priceId: "price_legacy" });
    harness.container.subscriptions.upsert({ ...sub, userId, plan: "monthly", status: "past_due" }, harness.clock.now);
    harness.gateway.seedSubscription(sub);
    harness.gateway.nextEvent = { id: "evt_legacy", type: "subscription.changed", subscription: sub };
    expect((await harness.app.request("/v1/billing/webhook", { method: "POST", body: "{}" })).status).toBe(200);
    expect(harness.container.subscriptions.findById(sub.id)).toMatchObject({ status: "active", plan: "monthly", stripeCustomerId: "cus_legacy" });
    expect(harness.container.users.requireById(userId).stripeCustomerId).toBe(preferred);
    const mismatched = { ...sub, customerId: "cus_unrelated" };
    harness.gateway.seedSubscription(mismatched);
    harness.gateway.nextEvent = { id: "evt_wrong_customer", type: "subscription.changed", subscription: mismatched };
    expect((await harness.app.request("/v1/billing/webhook", { method: "POST", body: "{}" })).status).toBe(422);
    expect(harness.container.stripeEvents.isApplied("evt_wrong_customer")).toBe(false);
  });

  it("rejects webhooks for unknown customers without recording a receipt", async () => {
    const stranger = liveSubscription("cus_unknown", { id: "sub_x", metadataUserId: null });
    harness.gateway.seedSubscription(stranger);
    harness.gateway.nextEvent = { id: "evt_x", type: "subscription.changed", subscription: stranger };
    expect((await harness.app.request("/v1/billing/webhook", { method: "POST", body: "{}" })).status).toBe(422);
    expect(harness.container.stripeEvents.isApplied("evt_x")).toBe(false);
  });

  it("rejects an in flight change if cancellation commits during the Stripe read", async () => {
    await post(harness.app, "/v1/billing/checkout", { plan: "monthly" }, token);
    const sub = liveSubscription(harness.gateway.checkouts[0]!.customerId);
    const service = harness.container.billingWebhook;
    let finishRead!: (value: GatewaySubscription) => void;
    vi.spyOn(harness.gateway, "retrieveSubscription").mockReturnValue(new Promise((resolve) => { finishRead = resolve; }));
    const change = { id: "evt_early", type: "subscription.changed", subscription: sub } as const;
    const pending = service.apply(change);
    const stale = expect(pending).rejects.toMatchObject({ status: 503 });
    await service.apply({ id: "evt_cancel", type: "subscription.deleted", subscription: sub });
    finishRead(sub);
    await stale;
    expect(harness.container.stripeEvents.isApplied(change.id)).toBe(false);
    await expect(service.apply(change)).resolves.toMatchObject({ handled: true });
    expect(harness.container.subscriptions.findById(sub.id)?.status).toBe("canceled");
  });

  it("rolls back event effects when the receipt cannot be written", async () => {
    await post(harness.app, "/v1/billing/checkout", { plan: "monthly" }, token);
    const sub = liveSubscription(harness.gateway.checkouts[0]!.customerId);
    harness.gateway.seedSubscription(sub);
    const event = { id: "evt_failed", type: "subscription.changed", subscription: sub } as const;
    const { database, subscriptions, stripeEvents, billingWebhook } = harness.container;
    database.exec(`CREATE TRIGGER reject_receipt BEFORE INSERT ON stripe_events BEGIN SELECT RAISE(ABORT, 'receipt failed'); END`);
    await expect(billingWebhook.apply(event)).rejects.toThrow("receipt failed");
    expect(subscriptions.findById(sub.id)).toBeNull();
    expect(subscriptions.version(sub.id)).toBe(0);
    expect(stripeEvents.isApplied(event.id)).toBe(false);
    expect(database.get("SELECT 1 FROM audit_log WHERE action = 'billing.subscription_synced'")).toBeUndefined();
    database.exec("DROP TRIGGER reject_receipt");
    await expect(billingWebhook.apply(event)).resolves.toMatchObject({ handled: true });
  });

  it("applies Stripe's current state when an older 'active' event arrives after deletion", async () => {
    await post(harness.app, "/v1/billing/checkout", { plan: "monthly" }, token);
    const customerId = harness.gateway.checkouts[0]!.customerId;
    const canceled = liveSubscription(customerId, { id: "sub_late", priceId: "price_monthly", status: "canceled" });
    harness.gateway.seedSubscription(canceled);
    const staleActive = { ...canceled, status: "active" as const };
    harness.gateway.nextEvent = { id: "evt_late", type: "subscription.changed", subscription: staleActive };
    expect((await harness.app.request("/v1/billing/webhook", { method: "POST", body: "{}" })).status).toBe(200);
    expect(harness.container.subscriptions.findById("sub_late")?.status).toBe("canceled");
    expect((await json<AccessSnapshot>(await get(harness.app, "/v1/me", token))).entitlement.active).toBe(false);
  });

  it("answers 503 on the webhook when Stripe is not configured", async () => {
    harness.container.close();
    harness = buildHarness();
    const { Container } = await import("../src/Container.js");
    const { AppConfigLoader } = await import("../src/config/AppConfig.js");
    const { AppFactory } = await import("../src/http/App.js");
    const bare = new Container(AppConfigLoader.forTesting());
    const app = AppFactory.create(bare, { quiet: true });
    expect((await app.request("/v1/billing/webhook", { method: "POST", body: "{}" })).status).toBe(503);
    bare.close();
  });

  it("serves a browser return page that deep links into the app", async () => {
    const response = await harness.app.request("/v1/billing/return?status=success");
    expect(response.status).toBe(200);
    const html = await response.text();
    expect(html).toContain("interviewcheck://billing/success");
    expect(html).toContain("check whether your subscription is active");
  });
});

describe("stripe event ledger", () => {
  let harness: TestHarness;

  beforeEach(() => {
    harness = buildHarness();
  });

  afterEach(() => {
    harness.container.close();
  });

  it("treats an applied event as a duplicate forever", () => {
    const events = harness.container.stripeEvents;
    const write = vi.fn();
    expect(events.apply("evt_done", "subscription.changed", harness.clock.now, write)).toBe(true);
    const muchLater = new Date(harness.clock.now.getTime() + 24 * 3600 * 1000);
    expect(events.apply("evt_done", "subscription.changed", muchLater, write)).toBe(false);
    expect(events.isApplied("evt_done")).toBe(true);
    expect(write).toHaveBeenCalledTimes(1);
  });

  it("retries a pending receipt left by an older version", () => {
    const { database, stripeEvents } = harness.container;
    database.run("INSERT INTO stripe_events (id, type, received_at) VALUES (?, ?, ?)", "evt_crash", "checkout.completed", harness.clock.now.getTime());
    const write = vi.fn();
    expect(stripeEvents.apply("evt_crash", "checkout.completed", harness.clock.now, write)).toBe(true);
    expect(stripeEvents.isApplied("evt_crash")).toBe(true);
    expect(write).toHaveBeenCalledOnce();
  });

  it("marks a webhook applied only after its effects landed", async () => {
    const signup = await json<SignedInResponse>(await post(harness.app, "/v1/auth/signup", { email: "ledger@example.com", password: "a-long-password" }));
    await post(harness.app, "/v1/billing/checkout", { plan: "monthly" }, signup.token);
    const customerId = harness.gateway.checkouts[0]!.customerId;
    const sub: GatewaySubscription = {
      id: "sub_ledger",
      customerId,
      status: "active",
      priceId: "price_monthly",
      currentPeriodEnd: new Date(harness.clock.now.getTime() + 30 * DAY),
      cancelAtPeriodEnd: false,
      metadataUserId: signup.user.id,
    };
    harness.gateway.seedSubscription(sub);
    harness.gateway.nextEvent = { id: "evt_ledger", type: "subscription.changed", subscription: sub };
    expect(await json(await harness.app.request("/v1/billing/webhook", { method: "POST", body: "{}" }))).toMatchObject({ handled: true });
    expect(harness.container.stripeEvents.isApplied("evt_ledger")).toBe(true);
  });
});
