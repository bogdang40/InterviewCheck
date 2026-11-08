import type { BillingEvent, CheckoutRequest, GatewaySubscription, StripeGateway } from "../../src/stripe/StripeGateway.js";

/** Deterministic in-memory Stripe stand in. */
export class FakeStripeGateway implements StripeGateway {
  readonly isConfigured = true;
  readonly customers = new Map<string, { email: string; userId: string }>();
  readonly subscriptions = new Map<string, GatewaySubscription>();
  readonly checkouts: CheckoutRequest[] = [];
  nextEvent: BillingEvent | null = null;
  private counter = 0;

  async createCustomer(email: string, userId: string): Promise<string> {
    const id = `cus_${++this.counter}`;
    this.customers.set(id, { email, userId });
    return id;
  }

  async createCheckoutSession(request: CheckoutRequest): Promise<{ id: string; url: string }> {
    this.checkouts.push(request);
    return { id: `cs_${++this.counter}`, url: `https://checkout.stripe.test/${request.priceId}` };
  }

  async createPortalSession(customerId: string, returnUrl: string): Promise<{ url: string }> {
    return { url: `https://billing.stripe.test/${customerId}?return=${encodeURIComponent(returnUrl)}` };
  }

  async retrieveSubscription(subscriptionId: string): Promise<GatewaySubscription> {
    const subscription = this.subscriptions.get(subscriptionId);
    if (!subscription) throw new Error(`No fake subscription ${subscriptionId}`);
    return subscription;
  }

  async parseWebhook(): Promise<BillingEvent> {
    if (!this.nextEvent) throw new Error("No fake event queued");
    const event = this.nextEvent;
    this.nextEvent = null;
    return event;
  }

  seedSubscription(subscription: GatewaySubscription): void {
    this.subscriptions.set(subscription.id, subscription);
  }
}
