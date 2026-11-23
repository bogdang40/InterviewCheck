import Stripe from "stripe";
import { CHECKOUT_BLOCKING_STATUSES } from "../domain/Subscription.js";
import { HttpError } from "../http/HttpError.js";
import type { BillingEvent, CheckoutRequest, GatewaySubscription, StripeGateway } from "./StripeGateway.js";
import { CheckoutExpiryRejected } from "./StripeGateway.js";
import { StripeSubscriptionMapper } from "./StripeSubscriptionMapper.js";

/** Well under the SDK default of 80 seconds so a stalled Stripe call cannot pin a request for minutes. */
const STRIPE_TIMEOUT_MS = 12_000;
const STRIPE_MAX_NETWORK_RETRIES = 2;

export class StripeSdkGateway implements StripeGateway {
  private readonly stripe: Stripe;

  constructor(
    secretKey: string,
    private readonly webhookSecret: string | undefined,
    private readonly priceIds: readonly string[],
  ) {
    this.stripe = new Stripe(secretKey, { typescript: true, timeout: STRIPE_TIMEOUT_MS, maxNetworkRetries: STRIPE_MAX_NETWORK_RETRIES });
  }

  get isConfigured(): boolean {
    return Boolean(this.webhookSecret);
  }

  async createCustomer(email: string, userId: string): Promise<string> {
    const customer = await this.stripe.customers.create(
      { email, metadata: { userId } }, { idempotencyKey: `interviewcheck-customer:${userId}` },
    );
    return customer.id;
  }

  async hasCheckoutBlockingSubscription(customerId: string, priceIds: readonly string[]): Promise<boolean> {
    let scanned = 0;
    for await (const subscription of this.stripe.subscriptions.list({ customer: customerId, limit: 100 })) {
      if (CHECKOUT_BLOCKING_STATUSES.includes(subscription.status)
          && subscription.items.data.some((item) => priceIds.includes(item.price.id))) return true;
      if (++scanned >= 1000) throw new HttpError(503, "billing_unavailable", "Could not confirm the current subscription state.");
    }
    return false;
  }

  async createCheckoutSession(request: CheckoutRequest): Promise<{ id: string; url: string }> {
    const params: Stripe.Checkout.SessionCreateParams = {
      mode: "subscription",
      expires_at: request.expiresAt,
      customer: request.customerId,
      client_reference_id: request.userId,
      line_items: [{ price: request.priceId, quantity: 1 }],
      success_url: request.successUrl,
      cancel_url: request.cancelUrl,
      allow_promotion_codes: true,
      subscription_data: { metadata: { userId: request.userId } },
      metadata: { userId: request.userId, checkoutRequestId: request.requestId },
    };
    const options = { idempotencyKey: `interviewcheck-checkout:${request.userId}:${request.requestId}` };
    const session = await this.stripe.checkout.sessions.create(params, options).catch((error: unknown) => {
      if (error instanceof Stripe.errors.StripeInvalidRequestError && error.param === "expires_at") {
        throw new CheckoutExpiryRejected();
      }
      throw error;
    });
    if (!session.url) throw new Error("Stripe did not return a checkout URL");
    return { id: session.id, url: session.url };
  }

  async createPortalSession(customerId: string, returnUrl: string): Promise<{ url: string }> {
    const session = await this.stripe.billingPortal.sessions.create({ customer: customerId, return_url: returnUrl });
    return { url: session.url };
  }

  async retrieveSubscription(subscriptionId: string): Promise<GatewaySubscription> {
    const subscription = await this.stripe.subscriptions.retrieve(subscriptionId);
    return StripeSubscriptionMapper.map(subscription, this.priceIds);
  }

  async parseWebhook(rawBody: string, signature: string | null): Promise<BillingEvent> {
    if (!this.webhookSecret) {
      throw new HttpError(503, "webhook_not_configured", "Stripe webhook handling is not configured.");
    }
    if (!signature) {
      throw new HttpError(400, "missing_signature", "Missing stripe-signature header.");
    }
    let event: Stripe.Event;
    try {
      event = await this.stripe.webhooks.constructEventAsync(rawBody, signature, this.webhookSecret);
    } catch {
      throw new HttpError(400, "invalid_signature", "Webhook signature verification failed.");
    }
    return StripeSdkGateway.toBillingEvent(event, this.priceIds);
  }

  static toBillingEvent(event: Stripe.Event, priceIds: readonly string[] = []): BillingEvent {
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object;
        if (session.mode !== "subscription") return { id: event.id, type: "ignored", rawType: event.type };
        const checkoutRequestId = session.metadata?.["checkoutRequestId"];
        return {
          id: event.id,
          type: "checkout.completed",
          customerId: session.customer ? StripeSubscriptionMapper.idOf(session.customer) : null,
          subscriptionId: session.subscription ? StripeSubscriptionMapper.idOf(session.subscription) : null,
          clientReferenceId: session.client_reference_id ?? session.metadata?.["userId"] ?? null,
          ...(checkoutRequestId ? { checkoutRequestId } : {}),
        };
      }
      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.paused":
      case "customer.subscription.resumed":
        return { id: event.id, type: "subscription.changed", subscription: StripeSubscriptionMapper.map(event.data.object, priceIds) };
      case "customer.subscription.deleted":
        return { id: event.id, type: "subscription.deleted", subscription: StripeSubscriptionMapper.map(event.data.object, priceIds) };
      default:
        return { id: event.id, type: "ignored", rawType: event.type };
    }
  }
}
