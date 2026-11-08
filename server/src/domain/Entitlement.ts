import { MILLISECONDS_PER_DAY } from "../config/AppConfig.js";
import type { Plan, Subscription } from "./Subscription.js";
import type { User } from "./User.js";

export type EntitlementSource = "admin" | "subscription" | "complimentary" | "trial" | "none";

export interface Entitlement {
  /** True when the app may be used right now. */
  readonly active: boolean;
  readonly source: EntitlementSource;
  /** When the current grant lapses (null for admins). */
  readonly expiresAt: string | null;
  /** How long the desktop app may trust this snapshot without reconnecting. */
  readonly graceUntil: string;
  readonly plan: Plan | null;
  readonly subscriptionStatus: string | null;
}

export interface EntitlementPolicy {
  readonly pastDueGraceDays: number;
  readonly offlineGraceDays: number;
}

/**
 * Pure decision function. Given what we know about a user and their newest
 * subscription, decide whether the app is usable and why. Ordered by
 * strength of the grant so the reported source is the most durable one.
 */
export class EntitlementResolver {
  constructor(private readonly policy: EntitlementPolicy) {}

  resolve(user: User, subscription: Subscription | null, now: Date = new Date()): Entitlement {
    if (user.disabled) {
      return this.inactive(subscription, now);
    }
    if (user.role === "admin") {
      return this.active("admin", null, subscription, now);
    }

    const subscriptionExpiry = this.subscriptionExpiry(subscription, now);
    if (subscriptionExpiry) {
      return this.active("subscription", subscriptionExpiry, subscription, now);
    }
    if (user.complimentaryUntil && user.complimentaryUntil > now) {
      return this.active("complimentary", user.complimentaryUntil, subscription, now);
    }
    if (user.trialEndsAt && user.trialEndsAt > now) {
      return this.active("trial", user.trialEndsAt, subscription, now);
    }
    return this.inactive(subscription, now);
  }

  private subscriptionExpiry(subscription: Subscription | null, now: Date): Date | null {
    if (!subscription) return null;
    const periodEnd = subscription.currentPeriodEnd;
    switch (subscription.status) {
      case "active":
      case "trialing":
        if (!periodEnd) return new Date(now.getTime() + this.policy.offlineGraceDays * MILLISECONDS_PER_DAY);
        return periodEnd > now ? periodEnd : null;
      case "past_due": {
        // Stripe already advanced the period when the charge failed, so the
        // grace window is measured from the moment the row went past_due.
        const graceEnd = new Date(subscription.statusChangedAt.getTime() + this.policy.pastDueGraceDays * MILLISECONDS_PER_DAY);
        return graceEnd > now ? graceEnd : null;
      }
      default:
        return null;
    }
  }

  private active(source: EntitlementSource, expiresAt: Date | null, subscription: Subscription | null, now: Date): Entitlement {
    const offlineLimit = now.getTime() + this.policy.offlineGraceDays * MILLISECONDS_PER_DAY;
    const graceMillis = expiresAt ? Math.min(offlineLimit, expiresAt.getTime()) : offlineLimit;
    return {
      active: true,
      source,
      expiresAt: expiresAt?.toISOString() ?? null,
      graceUntil: new Date(graceMillis).toISOString(),
      plan: subscription?.plan ?? null,
      subscriptionStatus: subscription?.status ?? null,
    };
  }

  private inactive(subscription: Subscription | null, now: Date): Entitlement {
    return {
      active: false,
      source: "none",
      expiresAt: null,
      graceUntil: now.toISOString(),
      plan: subscription?.plan ?? null,
      subscriptionStatus: subscription?.status ?? null,
    };
  }
}
