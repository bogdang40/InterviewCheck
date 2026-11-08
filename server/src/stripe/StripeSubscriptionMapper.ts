import type Stripe from "stripe";
import type { SubscriptionStatus } from "../domain/Subscription.js";
import type { GatewaySubscription } from "./StripeGateway.js";

/**
 * Translates Stripe's subscription object into the neutral gateway shape.
 * Handles both the legacy top level current_period_end and the newer per
 * item field so it works across Stripe API versions.
 */
export class StripeSubscriptionMapper {
  static map(subscription: Stripe.Subscription): GatewaySubscription {
    const firstItem = subscription.items?.data?.[0];
    const legacy = subscription as unknown as { current_period_end?: number | null };
    const periodEndSeconds = firstItem?.current_period_end ?? legacy.current_period_end ?? null;
    if (periodEndSeconds === null) {
      console.warn(`[stripe] subscription ${subscription.id} carries no current_period_end in either location`);
    }
    return {
      id: subscription.id,
      customerId: StripeSubscriptionMapper.idOf(subscription.customer),
      status: subscription.status as SubscriptionStatus,
      priceId: firstItem?.price?.id ?? null,
      currentPeriodEnd: periodEndSeconds ? new Date(periodEndSeconds * 1000) : null,
      cancelAtPeriodEnd: Boolean(subscription.cancel_at_period_end),
      metadataUserId: subscription.metadata?.["userId"] ?? null,
    };
  }

  static idOf(value: string | { id: string } | null | undefined): string {
    if (!value) return "";
    return typeof value === "string" ? value : value.id;
  }
}
