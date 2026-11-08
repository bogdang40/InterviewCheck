import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { SignedInResponse } from "../src/services/AuthService.js";
import type { AccessSnapshot } from "../src/services/EntitlementService.js";
import type { GatewaySubscription } from "../src/stripe/StripeGateway.js";
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
    harness.gateway.nextEvent = { id: "evt_1", type: "checkout.completed", customerId, subscriptionId: "sub_live", clientReferenceId: userId };

    const webhook = await harness.app.request("/v1/billing/webhook", { method: "POST", body: "{}", headers: { "stripe-signature": "sig" } });
    expect(webhook.status).toBe(200);
    expect(await json(webhook)).toMatchObject({ received: true, handled: true, type: "checkout.completed" });

    const me = await json<AccessSnapshot>(await get(harness.app, "/v1/me", token));
    expect(me.entitlement).toMatchObject({ active: true, source: "subscription", plan: "annual" });
    expect(me.subscription?.status).toBe("active");
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

  it("rejects webhooks for unknown customers and releases the idempotency claim", async () => {
    const stranger = liveSubscription("cus_unknown", { id: "sub_x", metadataUserId: null });
    harness.gateway.seedSubscription(stranger);
    harness.gateway.nextEvent = { id: "evt_x", type: "subscription.changed", subscription: stranger };
    expect((await harness.app.request("/v1/billing/webhook", { method: "POST", body: "{}" })).status).toBe(422);
    expect(harness.container.stripeEvents.claim("evt_x", "subscription.changed")).toBe(true);
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
    expect(html).toContain("memanager://billing/success");
    expect(html).toContain("Subscription active");
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
    expect(events.claim("evt_done", "subscription.changed", harness.clock.now)).toBe(true);
    events.markApplied("evt_done", harness.clock.now);
    const muchLater = new Date(harness.clock.now.getTime() + 24 * 3600 * 1000);
    expect(events.claim("evt_done", "subscription.changed", muchLater)).toBe(false);
    expect(events.isApplied("evt_done")).toBe(true);
  });

  it("lets a stale pending claim be taken again after a crash mid apply", () => {
    const events = harness.container.stripeEvents;
    expect(events.claim("evt_crash", "checkout.completed", harness.clock.now)).toBe(true);
    // A concurrent redelivery inside the window is still refused.
    const soon = new Date(harness.clock.now.getTime() + 1000);
    expect(events.claim("evt_crash", "checkout.completed", soon)).toBe(false);
    const afterWindow = new Date(harness.clock.now.getTime() + 6 * 60 * 1000);
    expect(events.claim("evt_crash", "checkout.completed", afterWindow)).toBe(true);
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
