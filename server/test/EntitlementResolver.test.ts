import { describe, expect, it } from "vitest";
import { EntitlementResolver } from "../src/domain/Entitlement.js";
import type { Subscription } from "../src/domain/Subscription.js";
import type { User } from "../src/domain/User.js";

const NOW = new Date("2026-09-02T12:00:00Z");
const DAY = 24 * 60 * 60 * 1000;

function user(overrides: Partial<User> = {}): User {
  return {
    id: "u1",
    email: "a@example.com",
    role: "user",
    disabled: false,
    trialEndsAt: null,
    complimentaryUntil: null,
    stripeCustomerId: null,
    createdAt: NOW,
    updatedAt: NOW,
    lastLoginAt: null,
    ...overrides,
  };
}

function subscription(overrides: Partial<Subscription> = {}): Subscription {
  return {
    id: "sub_1",
    userId: "u1",
    status: "active",
    priceId: "price_monthly",
    plan: "monthly",
    currentPeriodEnd: new Date(NOW.getTime() + 20 * DAY),
    cancelAtPeriodEnd: false,
    statusChangedAt: NOW,
    createdAt: NOW,
    updatedAt: NOW,
    ...overrides,
  };
}

const resolver = new EntitlementResolver({ pastDueGraceDays: 3, offlineGraceDays: 7 });

describe("EntitlementResolver", () => {
  it("denies a brand new user with no grants", () => {
    const result = resolver.resolve(user(), null, NOW);
    expect(result.active).toBe(false);
    expect(result.source).toBe("none");
    expect(result.graceUntil).toBe(NOW.toISOString());
  });

  it("grants admins regardless of subscription", () => {
    const result = resolver.resolve(user({ role: "admin" }), null, NOW);
    expect(result).toMatchObject({ active: true, source: "admin", expiresAt: null });
    expect(new Date(result.graceUntil).getTime()).toBe(NOW.getTime() + 7 * DAY);
  });

  it("denies disabled accounts even when they are admins with subscriptions", () => {
    const result = resolver.resolve(user({ role: "admin", disabled: true }), subscription(), NOW);
    expect(result.active).toBe(false);
    expect(result.subscriptionStatus).toBe("active");
  });

  it("grants an active subscription until the period end", () => {
    const sub = subscription();
    const result = resolver.resolve(user(), sub, NOW);
    expect(result).toMatchObject({ active: true, source: "subscription", plan: "monthly" });
    expect(result.expiresAt).toBe(sub.currentPeriodEnd?.toISOString());
  });

  it("caps offline grace at the subscription expiry when that is sooner", () => {
    const soon = new Date(NOW.getTime() + 2 * DAY);
    const result = resolver.resolve(user(), subscription({ currentPeriodEnd: soon }), NOW);
    expect(result.graceUntil).toBe(soon.toISOString());
  });

  it("measures past_due grace from the status change, not the (already advanced) period end", () => {
    const wentPastDue = new Date(NOW.getTime() - 1 * DAY);
    const farPeriodEnd = new Date(NOW.getTime() + 29 * DAY);
    const inside = resolver.resolve(user(), subscription({ status: "past_due", currentPeriodEnd: farPeriodEnd, statusChangedAt: wentPastDue }), NOW);
    expect(inside.active).toBe(true);
    expect(inside.expiresAt).toBe(new Date(wentPastDue.getTime() + 3 * DAY).toISOString());
    const later = new Date(NOW.getTime() + 3 * DAY);
    const outside = resolver.resolve(user(), subscription({ status: "past_due", currentPeriodEnd: farPeriodEnd, statusChangedAt: wentPastDue }), later);
    expect(outside.active).toBe(false);
  });

  it("treats canceled and unpaid subscriptions as no grant", () => {
    for (const status of ["canceled", "unpaid", "incomplete_expired", "paused"] as const) {
      expect(resolver.resolve(user(), subscription({ status }), NOW).active).toBe(false);
    }
  });

  it("falls back to complimentary and trial grants in that order", () => {
    const complimentary = new Date(NOW.getTime() + 10 * DAY);
    const trial = new Date(NOW.getTime() + 5 * DAY);
    const both = resolver.resolve(user({ complimentaryUntil: complimentary, trialEndsAt: trial }), null, NOW);
    expect(both.source).toBe("complimentary");
    const trialOnly = resolver.resolve(user({ trialEndsAt: trial }), null, NOW);
    expect(trialOnly).toMatchObject({ active: true, source: "trial", expiresAt: trial.toISOString() });
  });

  it("ignores expired complimentary and trial dates", () => {
    const past = new Date(NOW.getTime() - DAY);
    expect(resolver.resolve(user({ complimentaryUntil: past, trialEndsAt: past }), null, NOW).active).toBe(false);
  });

  it("prefers a live subscription over a complimentary grant when reporting the source", () => {
    const result = resolver.resolve(user({ complimentaryUntil: new Date(NOW.getTime() + 90 * DAY) }), subscription(), NOW);
    expect(result.source).toBe("subscription");
  });
});
