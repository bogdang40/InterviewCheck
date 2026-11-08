import type { SubscriptionStatus } from "../domain/Subscription.js";
import { HttpError } from "../http/HttpError.js";

/** Provider neutral view of a Stripe subscription. */
export interface GatewaySubscription {
  readonly id: string;
  readonly customerId: string;
  readonly status: SubscriptionStatus;
  readonly priceId: string | null;
  readonly currentPeriodEnd: Date | null;
  readonly cancelAtPeriodEnd: boolean;
  /** userId we stamped into subscription metadata at checkout. */
  readonly metadataUserId: string | null;
}

export type BillingEvent =
  | {
      readonly id: string;
      readonly type: "checkout.completed";
      readonly customerId: string | null;
      readonly subscriptionId: string | null;
      readonly clientReferenceId: string | null;
    }
  | { readonly id: string; readonly type: "subscription.changed"; readonly subscription: GatewaySubscription }
  | { readonly id: string; readonly type: "subscription.deleted"; readonly subscription: GatewaySubscription }
  | { readonly id: string; readonly type: "ignored"; readonly rawType: string };

export interface CheckoutRequest {
  readonly customerId: string;
  readonly priceId: string;
  readonly userId: string;
  readonly successUrl: string;
  readonly cancelUrl: string;
}

/**
 * Everything the billing service needs from Stripe, expressed without
 * Stripe SDK types so it can be faked in tests and swapped later.
 */
export interface StripeGateway {
  readonly isConfigured: boolean;
  createCustomer(email: string, userId: string): Promise<string>;
  createCheckoutSession(request: CheckoutRequest): Promise<{ id: string; url: string }>;
  createPortalSession(customerId: string, returnUrl: string): Promise<{ url: string }>;
  retrieveSubscription(subscriptionId: string): Promise<GatewaySubscription>;
  parseWebhook(rawBody: string, signature: string | null): Promise<BillingEvent>;
}

export class UnconfiguredStripeGateway implements StripeGateway {
  readonly isConfigured = false;

  createCustomer(): Promise<string> {
    return Promise.reject(new Error("Stripe is not configured"));
  }

  createCheckoutSession(): Promise<{ id: string; url: string }> {
    return Promise.reject(new Error("Stripe is not configured"));
  }

  createPortalSession(): Promise<{ url: string }> {
    return Promise.reject(new Error("Stripe is not configured"));
  }

  retrieveSubscription(): Promise<GatewaySubscription> {
    return Promise.reject(new Error("Stripe is not configured"));
  }

  parseWebhook(): Promise<BillingEvent> {
    return Promise.reject(new HttpError(503, "billing_not_configured", "Billing is not configured on this server."));
  }
}
