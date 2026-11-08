import { describe, expect, it } from "vitest";
import type Stripe from "stripe";
import { StripeSdkGateway } from "../src/stripe/StripeSdkGateway.js";
import { StripeSubscriptionMapper } from "../src/stripe/StripeSubscriptionMapper.js";

function subscription(overrides: Record<string, unknown>): Stripe.Subscription {
  return {
    id: "sub_1",
    object: "subscription",
    customer: "cus_1",
    status: "active",
    cancel_at_period_end: false,
    metadata: { userId: "u1" },
    items: { object: "list", data: [], has_more: false, url: "" },
    ...overrides,
  } as unknown as Stripe.Subscription;
}

describe("StripeSubscriptionMapper", () => {
  it("reads current_period_end from the subscription item (newer API versions)", () => {
    const mapped = StripeSubscriptionMapper.map(
      subscription({ items: { object: "list", data: [{ id: "si_1", current_period_end: 1_800_000_000, price: { id: "price_annual" } }] } }),
    );
    expect(mapped.currentPeriodEnd?.getTime()).toBe(1_800_000_000_000);
    expect(mapped.priceId).toBe("price_annual");
    expect(mapped.customerId).toBe("cus_1");
    expect(mapped.metadataUserId).toBe("u1");
  });

  it("falls back to the legacy top level current_period_end", () => {
    const mapped = StripeSubscriptionMapper.map(subscription({ current_period_end: 1_700_000_000 }));
    expect(mapped.currentPeriodEnd?.getTime()).toBe(1_700_000_000_000);
    expect(mapped.priceId).toBeNull();
  });

  it("handles expanded customer objects and missing metadata", () => {
    const mapped = StripeSubscriptionMapper.map(subscription({ customer: { id: "cus_expanded" }, metadata: {}, current_period_end: 1 }));
    expect(mapped.customerId).toBe("cus_expanded");
    expect(mapped.metadataUserId).toBeNull();
  });

  it("maps event types to billing events", () => {
    const event = (type: string, object: unknown) => ({ id: "evt", type, data: { object } }) as unknown as Stripe.Event;
    expect(StripeSdkGateway.toBillingEvent(event("customer.subscription.deleted", subscription({ current_period_end: 1 }))).type).toBe("subscription.deleted");
    expect(StripeSdkGateway.toBillingEvent(event("customer.subscription.paused", subscription({ current_period_end: 1 }))).type).toBe("subscription.changed");
    expect(StripeSdkGateway.toBillingEvent(event("invoice.paid", {}))).toMatchObject({ type: "ignored", rawType: "invoice.paid" });
    const checkout = StripeSdkGateway.toBillingEvent(
      event("checkout.session.completed", { customer: "cus_9", subscription: { id: "sub_9" }, client_reference_id: null, metadata: { userId: "u9" } }),
    );
    expect(checkout).toMatchObject({ type: "checkout.completed", customerId: "cus_9", subscriptionId: "sub_9", clientReferenceId: "u9" });
  });
});
