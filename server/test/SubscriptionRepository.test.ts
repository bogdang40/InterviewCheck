import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { SubscriptionStatus } from "../src/domain/Subscription.js";
import { buildHarness, type TestHarness } from "./support/TestContainer.js";

describe("current subscription selection", () => {
  let harness: TestHarness;
  let userId: string;

  beforeEach(() => {
    harness = buildHarness();
    userId = harness.container.users.create({
      email: "subscriber@example.com", passwordHash: "unused", role: "user", trialEndsAt: null,
    }, harness.clock.now).id;
  });

  afterEach(() => harness.container.close());

  function save(id: string, status: SubscriptionStatus, offset: number) {
    return harness.container.subscriptions.upsert({
      id, userId, status, priceId: "price_monthly", plan: "monthly",
      currentPeriodEnd: new Date(harness.clock.now.getTime() + 86400000), cancelAtPeriodEnd: false,
    }, new Date(harness.clock.now.getTime() + offset));
  }

  it("returns null when the user has no subscriptions", () => {
    expect(harness.container.subscriptions.currentForUser(userId)).toBeNull();
    save("sub_other", "active", 0);
    expect(harness.container.subscriptions.currentForUser("other_user")).toBeNull();
  });

  it("prefers the newest live status over newer nonlive history", () => {
    save("sub_canceled", "canceled", 10000);
    const statuses: SubscriptionStatus[] = ["active", "trialing", "past_due"];
    for (const [index, status] of statuses.entries()) {
      const expected = save(`sub_${status}`, status, index * 1000);
      expect(harness.container.subscriptions.currentForUser(userId)).toEqual(expected);
    }
  });

  it("falls back to the newest nonlive subscription after all live plans end", () => {
    save("sub_old", "unpaid", 0);
    save("sub_live", "active", 1000);
    save("sub_recent", "paused", 2000);
    const expected = save("sub_live", "canceled", 3000);
    expect(harness.container.subscriptions.currentForUser(userId)).toEqual(expected);
  });

  it("preserves insertion order when update times tie", () => {
    const firstCanceled = save("sub_canceled_z", "canceled", 0);
    save("sub_canceled_a", "canceled", 0);
    expect(harness.container.subscriptions.currentForUser(userId)).toEqual(firstCanceled);
    const firstLive = save("sub_live_z", "trialing", 0);
    save("sub_live_a", "active", 0);
    expect(harness.container.subscriptions.currentForUser(userId)).toEqual(firstLive);
  });
});
