import Stripe from "stripe";
import { HttpError } from "../http/HttpError.js";
import type { BillingEvent, CheckoutRequest, GatewaySubscription, StripeGateway } from "./StripeGateway.js";
import { StripeSubscriptionMapper } from "./StripeSubscriptionMapper.js";

export class StripeSdkGateway implements StripeGateway {
  readonly isConfigured = true;
  private readonly stripe: Stripe;

  constructor(
    secretKey: string,
    private readonly webhookSecret: string | undefined,
  ) {
    this.stripe = new Stripe(secretKey, { typescript: true });
  }

  async createCustomer(email: string, userId: string): Promise<string> {
    const customer = await this.stripe.customers.create({ email, metadata: { userId } });
    return customer.id;
  }

  async createCheckoutSession(request: CheckoutRequest): Promise<{ id: string; url: string }> {
    const session = await this.stripe.checkout.sessions.create({
      mode: "subscription",
      customer: request.customerId,
      client_reference_id: request.userId,
      line_items: [{ price: request.priceId, quantity: 1 }],
      success_url: request.successUrl,
      cancel_url: request.cancelUrl,
      allow_promotion_codes: true,
      subscription_data: { metadata: { userId: request.userId } },
      metadata: { userId: request.userId },
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
    return StripeSubscriptionMapper.map(subscription);
  }

  async parseWebhook(rawBody: string, signature: string | null): Promise<BillingEvent> {
    if (!this.webhookSecret) {
      throw new HttpError(503, "webhook_not_configured", "STRIPE_WEBHOOK_SECRET is not set.");
    }
    if (!signature) {
      throw new HttpError(400, "missing_signature", "Missing stripe-signature header.");
    }
    let event: Stripe.Event;
    try {
      event = await this.stripe.webhooks.constructEventAsync(rawBody, signature, this.webhookSecret);
    } catch (error) {
      throw new HttpError(400, "invalid_signature", `Webhook signature verification failed: ${(error as Error).message}`);
    }
    return StripeSdkGateway.toBillingEvent(event);
  }

  static toBillingEvent(event: Stripe.Event): BillingEvent {
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object;
        return {
          id: event.id,
          type: "checkout.completed",
          customerId: session.customer ? StripeSubscriptionMapper.idOf(session.customer) : null,
          subscriptionId: session.subscription ? StripeSubscriptionMapper.idOf(session.subscription) : null,
          clientReferenceId: session.client_reference_id ?? session.metadata?.["userId"] ?? null,
        };
      }
      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.paused":
      case "customer.subscription.resumed":
        return { id: event.id, type: "subscription.changed", subscription: StripeSubscriptionMapper.map(event.data.object) };
      case "customer.subscription.deleted":
        return { id: event.id, type: "subscription.deleted", subscription: StripeSubscriptionMapper.map(event.data.object) };
      default:
        return { id: event.id, type: "ignored", rawType: event.type };
    }
  }
}
