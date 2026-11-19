import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { FixedWindowRateLimiter } from "../src/http/middleware/RateLimit.js";
import type { AdminUserView } from "../src/services/AdminService.js";
import type { SignedInResponse } from "../src/services/AuthService.js";
import type { GatewaySubscription } from "../src/stripe/StripeGateway.js";
import { buildHarness, get, json, patch, post, type TestHarness } from "./support/TestContainer.js";

describe("T5-08: UserRepository keyset pagination and cursor handling", () => {
  let harness: TestHarness;
  let adminToken: string;

  beforeEach(async () => {
    harness = buildHarness();
    const admin = await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/signup", { email: "owner@example.com", password: "a-long-password", adminSecret: "bootstrap-secret" }),
    );
    adminToken = admin.token;
  });

  afterEach(() => {
    harness.container.close();
  });

  it("paginates deterministically across identical created_at timestamps via id DESC tie-breaker", async () => {
    for (let i = 0; i < 4; i += 1) {
      await post(harness.app, "/v1/auth/signup", { email: `same-ts-${i}@example.com`, password: "a-long-password" });
    }
    const page1 = await json<{ users: AdminUserView[]; nextCursor: string | null }>(await get(harness.app, "/v1/admin/users?limit=2", adminToken));
    const page2 = await json<{ users: AdminUserView[]; nextCursor: string | null }>(
      await get(harness.app, `/v1/admin/users?limit=2&cursor=${encodeURIComponent(page1.nextCursor ?? "")}`, adminToken),
    );
    const page3 = await json<{ users: AdminUserView[]; nextCursor: string | null }>(
      await get(harness.app, `/v1/admin/users?limit=2&cursor=${encodeURIComponent(page2.nextCursor ?? "")}`, adminToken),
    );

    expect(page1.users).toHaveLength(2);
    expect(page2.users).toHaveLength(2);
    expect(page3.users).toHaveLength(1);
    expect(page3.nextCursor).toBeNull();

    const ordered = [...page1.users, ...page2.users, ...page3.users].map((v) => v.user);
    expect(new Set(ordered.map((u) => u.id)).size).toBe(5);
    expect(new Set(ordered.map((u) => u.createdAt)).size).toBe(1);
    for (let i = 1; i < ordered.length; i += 1) {
      expect(ordered[i - 1]!.id > ordered[i]!.id).toBe(true);
    }
  });

  it("rejects malformed and non-finite pagination cursors with 400", async () => {
    await post(harness.app, "/v1/auth/signup", { email: "member@example.com", password: "a-long-password" });
    const malformed = [
      "not-base64!!!",
      "a",
      Buffer.from("notanumber|id-1", "utf8").toString("base64url"),
      Buffer.from("12345|", "utf8").toString("base64url"),
      Buffer.from("|id-1", "utf8").toString("base64url"),
      Buffer.from("12345", "utf8").toString("base64url"),
      Buffer.from("12345|id-1|extra", "utf8").toString("base64url"),
      Buffer.from("Infinity|id-1", "utf8").toString("base64url"),
      Buffer.from("-Infinity|id-1", "utf8").toString("base64url"),
      Buffer.from("12.34|id-1", "utf8").toString("base64url"),
    ];
    for (const badCursor of malformed) {
      const res = await get(harness.app, `/v1/admin/users?limit=1&cursor=${encodeURIComponent(badCursor)}`, adminToken);
      expect(res.status).toBe(400);
      expect(await json<{ error: { code: string } }>(res)).toMatchObject({ error: { code: "invalid_cursor" } });
    }
  });
});

describe("T5-09: RateLimit proxy resolution and sweep capacity", () => {
  let harness: TestHarness;

  afterEach(() => {
    harness?.container.close();
  });

  function loginWithHeaders(headers: Record<string, string>): Promise<Response> {
    return harness.app.request("/v1/auth/login", {
      method: "POST",
      headers: { "content-type": "application/json", ...headers },
      body: JSON.stringify({ email: "nobody@example.com", password: "a-long-password" }),
    });
  }

  it("uses fly-client-ip precedence and rightmost x-forwarded-for hop when TRUST_PROXY=true", async () => {
    harness = buildHarness({ TRUST_PROXY: true });
    for (let i = 0; i < 10; i += 1) {
      expect((await loginWithHeaders({ "fly-client-ip": "203.0.113.10", "x-forwarded-for": `10.0.0.${i}, 198.51.100.${i}` })).status).toBe(401);
    }
    expect((await loginWithHeaders({ "fly-client-ip": "203.0.113.10", "x-forwarded-for": "10.0.0.99, 198.51.100.99" })).status).toBe(429);
    expect((await loginWithHeaders({ "fly-client-ip": "203.0.113.11" })).status).toBe(401);

    for (let i = 0; i < 10; i += 1) {
      expect((await loginWithHeaders({ "x-forwarded-for": `10.0.0.${i}, 198.51.100.77` })).status).toBe(401);
    }
    expect((await loginWithHeaders({ "x-forwarded-for": "10.0.0.250, 198.51.100.77" })).status).toBe(429);
    expect((await loginWithHeaders({ "x-forwarded-for": "10.0.0.250, 198.51.100.78" })).status).toBe(401);
  });

  it("sweeps expired buckets and evicts oldest active buckets to keep size <= 5000", () => {
    let now = 1_000;
    const limiter = new FixedWindowRateLimiter({ windowMs: 60_000, max: 2 }, () => now);
    const buckets = (): Map<string, unknown> => (limiter as unknown as { buckets: Map<string, unknown> }).buckets;

    for (let i = 0; i < 4_999; i += 1) limiter.hit(`expired-${i}`);
    expect(buckets().size).toBe(4_999);

    now = 61_001;
    limiter.hit("trigger-sweep");
    expect(buckets().size).toBe(1);

    for (let i = 0; i < 5_050; i += 1) limiter.hit(`active-${i}`);
    expect(buckets().size).toBeLessThanOrEqual(5_000);
    expect(buckets().has("active-0")).toBe(false);
    expect(buckets().has("active-5049")).toBe(true);
  });
});

describe("T5-10: AdminService guards, CSRF/500 sanitization, and BillingWebhookService checks", () => {
  let harness: TestHarness;
  let ownerToken: string;
  let ownerId: string;
  let memberToken: string;
  let memberId: string;

  beforeEach(async () => {
    harness = buildHarness();
    const owner = await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/signup", { email: "owner@example.com", password: "a-long-password", adminSecret: "bootstrap-secret" }),
    );
    ownerToken = owner.token;
    ownerId = owner.user.id;
    const member = await json<SignedInResponse>(
      await post(harness.app, "/v1/auth/signup", { email: "member@example.com", password: "a-long-password" }),
    );
    memberToken = member.token;
    memberId = member.user.id;
  });

  afterEach(() => {
    vi.restoreAllMocks();
    harness.container.close();
  });

  it("rejects stale admin actor demoted or disabled mid-update with 403", async () => {
    const target = await json<SignedInResponse>(await post(harness.app, "/v1/auth/signup", { email: "target@example.com", password: "a-long-password" }));
    await patch(harness.app, `/v1/admin/users/${memberId}`, { role: "admin" }, ownerToken);
    const staleAdmin = harness.container.users.requireById(memberId);

    await patch(harness.app, `/v1/admin/users/${memberId}`, { role: "user" }, ownerToken);
    expect(() => harness.container.admin.updateUser(staleAdmin, target.user.id, { role: "admin" })).toThrowError(
      expect.objectContaining({ status: 403, code: "forbidden" }),
    );
    expect(harness.container.users.requireById(target.user.id).role).toBe("user");

    await patch(harness.app, `/v1/admin/users/${memberId}`, { role: "admin" }, ownerToken);
    await patch(harness.app, `/v1/admin/users/${memberId}`, { disabled: true }, ownerToken);
    expect(() => harness.container.admin.updateUser(staleAdmin, target.user.id, { disabled: true })).toThrowError(
      expect.objectContaining({ status: 403, code: "forbidden" }),
    );
    expect(harness.container.users.requireById(target.user.id).disabled).toBe(false);
  });

  it("distinguishes 2-admin self_disable 409 from 1-admin last_admin 409", async () => {
    const oneAdmin = await patch(harness.app, `/v1/admin/users/${ownerId}`, { disabled: true }, ownerToken);
    expect(oneAdmin.status).toBe(409);
    expect(await json<{ error: { code: string } }>(oneAdmin)).toMatchObject({ error: { code: "last_admin" } });

    await patch(harness.app, `/v1/admin/users/${memberId}`, { role: "admin" }, ownerToken);
    const twoAdminSelfDisable = await patch(harness.app, `/v1/admin/users/${ownerId}`, { disabled: true }, ownerToken);
    expect(twoAdminSelfDisable.status).toBe(409);
    expect(await json<{ error: { code: string } }>(twoAdminSelfDisable)).toMatchObject({ error: { code: "self_disable" } });
    expect((await patch(harness.app, `/v1/admin/users/${ownerId}`, { role: "user" }, ownerToken)).status).toBe(200);
  });

  it("exempts /v1/billing/webhook from Origin/Cookie CSRF while enforcing it on /v1/auth/password", async () => {
    const pwHeaders = { authorization: `Bearer ${memberToken}`, origin: "https://evil.example", "content-type": "application/json" };
    const pwBody = JSON.stringify({ currentPassword: "a-long-password", newPassword: "new-long-password" });
    expect((await harness.app.request("/v1/auth/password", { method: "POST", headers: pwHeaders, body: pwBody })).status).toBe(403);
    expect((await harness.app.request("/v1/auth/password", {
      method: "POST", headers: { ...pwHeaders, "x-interviewcheck": "1" }, body: pwBody,
    })).status).toBe(200);

    await post(harness.app, "/v1/billing/checkout", { plan: "monthly" }, ownerToken);
    const sub: GatewaySubscription = {
      id: "sub_csrf", customerId: harness.gateway.checkouts[0]!.customerId, status: "active", priceId: "price_monthly",
      currentPeriodEnd: new Date(harness.clock.now.getTime() + 86_400_000), cancelAtPeriodEnd: false, metadataUserId: ownerId,
    };
    harness.gateway.seedSubscription(sub);
    harness.gateway.nextEvent = { id: "evt_csrf", type: "subscription.changed", subscription: sub };
    const webhookRes = await harness.app.request("/v1/billing/webhook", {
      method: "POST",
      headers: { origin: "https://stripe.com", cookie: "ic_access=ignored", "stripe-signature": "sig" },
      body: "{}",
    });
    expect(webhookRes.status).toBe(200);
    expect(await json(webhookRes)).toMatchObject({ received: true, handled: true });
  });

  it("sanitizes unexpected 500 errors and suppresses unsafe codes/messages in logs", async () => {
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(harness.container.entitlements, "snapshotFor").mockImplementationOnce(() => {
      throw Object.assign(new Error("sk_live_secret_999 /var/lib/ic.db"), { code: "bad-secret-code" });
    });

    const res = await get(harness.app, "/v1/me", memberToken);
    expect(res.status).toBe(500);
    expect(await json(res)).toEqual({ error: { code: "internal_error", message: "Something went wrong." } });
    expect(errSpy).toHaveBeenCalledWith("[server] GET failed with Error");
    const logged = errSpy.mock.calls.flat().join(" ");
    expect(logged).not.toContain("sk_live_secret_999");
    expect(logged).not.toContain("bad-secret-code");
  });

  it("rejects BillingWebhookService missing IDs, subscription/customer mismatches, and owner conflicts", async () => {
    await post(harness.app, "/v1/billing/checkout", { plan: "monthly" }, memberToken);
    await post(harness.app, "/v1/billing/checkout", { plan: "monthly" }, ownerToken);
    const memberCustomerId = harness.gateway.checkouts[0]!.customerId;
    const ownerCustomerId = harness.gateway.checkouts[1]!.customerId;
    const service = harness.container.billingWebhook;
    const periodEnd = new Date(harness.clock.now.getTime() + 86_400_000);

    await expect(
      service.apply({ id: "evt_missing", type: "checkout.completed", customerId: memberCustomerId, subscriptionId: null, clientReferenceId: memberId, checkoutRequestId: null }),
    ).rejects.toMatchObject({ status: 422, code: "invalid_event" });

    const baseSub: GatewaySubscription = {
      id: "sub_match", customerId: memberCustomerId, status: "active", priceId: "price_monthly",
      currentPeriodEnd: periodEnd, cancelAtPeriodEnd: false, metadataUserId: memberId,
    };
    const retrieveSpy = vi.spyOn(harness.gateway, "retrieveSubscription");
    retrieveSpy.mockResolvedValueOnce({ ...baseSub, id: "sub_wrong_id" });
    await expect(service.apply({ id: "evt_id_mismatch", type: "subscription.changed", subscription: baseSub })).rejects.toMatchObject({
      status: 422, code: "invalid_event",
    });

    retrieveSpy.mockResolvedValueOnce({ ...baseSub, customerId: "cus_wrong" });
    await expect(service.apply({ id: "evt_cus_mismatch", type: "subscription.changed", subscription: baseSub })).rejects.toMatchObject({
      status: 422, code: "invalid_event",
    });
    retrieveSpy.mockRestore();

    harness.gateway.seedSubscription({ ...baseSub, metadataUserId: ownerId });
    await expect(
      service.apply({ id: "evt_owner_mismatch", type: "subscription.changed", subscription: { ...baseSub, metadataUserId: ownerId } }),
    ).rejects.toMatchObject({ status: 422, code: "unknown_customer" });
    expect(harness.container.stripeEvents.isApplied("evt_owner_mismatch")).toBe(false);

    harness.gateway.seedSubscription(baseSub);
    await expect(
      service.apply({ id: "evt_client_ref", type: "checkout.completed", customerId: memberCustomerId, subscriptionId: "sub_match", clientReferenceId: ownerId, checkoutRequestId: null }),
    ).rejects.toMatchObject({ status: 422, code: "unknown_customer" });
    expect(harness.container.stripeEvents.isApplied("evt_client_ref")).toBe(false);

    harness.container.subscriptions.upsert({ ...baseSub, userId: memberId, plan: "monthly" }, harness.clock.now);
    const crossUserSub: GatewaySubscription = { ...baseSub, customerId: ownerCustomerId, metadataUserId: null };
    harness.gateway.seedSubscription(crossUserSub);
    await expect(
      service.apply({ id: "evt_cross_owner", type: "subscription.changed", subscription: crossUserSub }),
    ).rejects.toMatchObject({ status: 422, code: "unknown_customer" });
    expect(harness.container.stripeEvents.isApplied("evt_cross_owner")).toBe(false);
  });
});
