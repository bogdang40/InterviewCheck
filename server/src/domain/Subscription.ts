export const PLANS = ["monthly", "annual"] as const;
export type Plan = (typeof PLANS)[number];

/** Stripe subscription statuses we persist verbatim. */
export type SubscriptionStatus =
  | "trialing"
  | "active"
  | "past_due"
  | "canceled"
  | "unpaid"
  | "incomplete"
  | "incomplete_expired"
  | "paused";

export const CHECKOUT_BLOCKING_STATUSES: readonly SubscriptionStatus[] = [
  "active", "trialing", "past_due", "incomplete", "paused", "unpaid",
];

export interface Subscription {
  readonly id: string;
  readonly userId: string;
  readonly stripeCustomerId: string | null;
  readonly status: SubscriptionStatus;
  readonly priceId: string | null;
  readonly plan: Plan | null;
  readonly currentPeriodEnd: Date | null;
  readonly cancelAtPeriodEnd: boolean;
  /** When the status last changed; drives the past_due grace window. */
  readonly statusChangedAt: Date;
  readonly createdAt: Date;
  readonly updatedAt: Date;
}

export interface PublicSubscription {
  readonly id: string;
  readonly status: SubscriptionStatus;
  readonly plan: Plan | null;
  readonly currentPeriodEnd: string | null;
  readonly cancelAtPeriodEnd: boolean;
}

export class SubscriptionPresenter {
  static toPublic(subscription: Subscription | null): PublicSubscription | null {
    if (!subscription) return null;
    return {
      id: subscription.id,
      status: subscription.status,
      plan: subscription.plan,
      currentPeriodEnd: subscription.currentPeriodEnd?.toISOString() ?? null,
      cancelAtPeriodEnd: subscription.cancelAtPeriodEnd,
    };
  }
}

/** Maps configured Stripe price ids to the plan names the app understands. */
export class PlanCatalog {
  private readonly priceByPlan: ReadonlyMap<Plan, string>;

  constructor(prices: { monthly?: string | undefined; annual?: string | undefined }) {
    const entries: Array<[Plan, string]> = [];
    if (prices.monthly) entries.push(["monthly", prices.monthly]);
    if (prices.annual) entries.push(["annual", prices.annual]);
    this.priceByPlan = new Map(entries);
  }

  get isConfigured(): boolean {
    return this.priceByPlan.size > 0;
  }

  priceId(plan: Plan): string | undefined {
    return this.priceByPlan.get(plan);
  }

  planFor(priceId: string | null | undefined): Plan | null {
    if (!priceId) return null;
    for (const [plan, id] of this.priceByPlan) {
      if (id === priceId) return plan;
    }
    return null;
  }

  availablePlans(): Plan[] {
    return [...this.priceByPlan.keys()];
  }

  priceIds(): string[] {
    return [...this.priceByPlan.values()];
  }
}
