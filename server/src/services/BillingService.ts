import type { Plan } from "../domain/Subscription.js";
import { PlanCatalog } from "../domain/Subscription.js";
import type { User } from "../domain/User.js";
import { HttpError } from "../http/HttpError.js";
import type { AuditLogRepository } from "../repositories/AuditLogRepository.js";
import type { StripeEventRepository } from "../repositories/StripeEventRepository.js";
import type { SubscriptionRepository } from "../repositories/SubscriptionRepository.js";
import type { UserRepository } from "../repositories/UserRepository.js";
import type { BillingEvent, GatewaySubscription, StripeGateway } from "../stripe/StripeGateway.js";

export class BillingService {
  constructor(
    private readonly gateway: StripeGateway,
    private readonly catalog: PlanCatalog,
    private readonly users: UserRepository,
    private readonly subscriptions: SubscriptionRepository,
    private readonly events: StripeEventRepository,
    private readonly audit: AuditLogRepository,
    private readonly publicBaseUrl: string,
    private readonly clock: () => Date = () => new Date(),
  ) {}

  get isConfigured(): boolean {
    return this.gateway.isConfigured && this.catalog.isConfigured;
  }

  availablePlans(): Plan[] {
    return this.catalog.availablePlans();
  }

  async createCheckout(user: User, plan: Plan): Promise<{ url: string }> {
    this.requireConfigured();
    const priceId = this.catalog.priceId(plan);
    if (!priceId) throw new HttpError(400, "unknown_plan", `Plan '${plan}' is not available.`);
    const customerId = await this.ensureCustomer(user);
    const session = await this.gateway.createCheckoutSession({
      customerId,
      priceId,
      userId: user.id,
      successUrl: `${this.publicBaseUrl}/v1/billing/return?status=success&session_id={CHECKOUT_SESSION_ID}`,
      cancelUrl: `${this.publicBaseUrl}/v1/billing/return?status=cancel`,
    });
    this.audit.record({ actorUserId: user.id, action: "billing.checkout_started", targetUserId: user.id, details: { plan, sessionId: session.id } }, this.clock());
    return { url: session.url };
  }

  async createPortal(user: User): Promise<{ url: string }> {
    this.requireConfigured();
    const customerId = await this.ensureCustomer(user);
    return this.gateway.createPortalSession(customerId, `${this.publicBaseUrl}/v1/billing/return?status=portal`);
  }

  /** Verify, deduplicate, and apply one webhook delivery. */
  async handleWebhook(rawBody: string, signature: string | null): Promise<{ handled: boolean; type: string }> {
    const event = await this.gateway.parseWebhook(rawBody, signature);
    return this.applyEvent(event);
  }

  async applyEvent(event: BillingEvent): Promise<{ handled: boolean; type: string }> {
    if (event.type === "ignored") return { handled: false, type: event.rawType };
    if (!this.events.claim(event.id, event.type, this.clock())) return { handled: false, type: event.type };
    try {
      switch (event.type) {
        case "checkout.completed":
          await this.onCheckoutCompleted(event);
          break;
        case "subscription.changed": {
          // Deliveries are unordered; apply Stripe's current state, not the
          // snapshot inside this event, so a late "active" cannot revive a
          // subscription that was deleted in between.
          const fresh = await this.gateway.retrieveSubscription(event.subscription.id);
          this.syncSubscription({ ...fresh, metadataUserId: fresh.metadataUserId ?? event.subscription.metadataUserId }, fresh.status);
          break;
        }
        case "subscription.deleted":
          this.syncSubscription(event.subscription, "canceled");
          break;
      }
      this.events.markApplied(event.id, this.clock());
      return { handled: true, type: event.type };
    } catch (error) {
      this.events.release(event.id);
      throw error;
    }
  }

  private async onCheckoutCompleted(event: Extract<BillingEvent, { type: "checkout.completed" }>): Promise<void> {
    const user = (event.clientReferenceId ? this.users.findById(event.clientReferenceId) : null)
      ?? (event.customerId ? this.users.findByStripeCustomerId(event.customerId) : null);
    if (!user) throw new HttpError(422, "unknown_customer", "Checkout completed for an unknown user.");
    if (event.customerId && user.stripeCustomerId !== event.customerId) {
      this.users.update(user.id, { stripeCustomerId: event.customerId }, this.clock());
    }
    if (event.subscriptionId) {
      const subscription = await this.gateway.retrieveSubscription(event.subscriptionId);
      this.syncSubscription({ ...subscription, metadataUserId: subscription.metadataUserId ?? user.id }, subscription.status);
    }
    this.audit.record({ actorUserId: null, action: "billing.checkout_completed", targetUserId: user.id }, this.clock());
  }

  private syncSubscription(subscription: GatewaySubscription, status: GatewaySubscription["status"]): void {
    const user = (subscription.metadataUserId ? this.users.findById(subscription.metadataUserId) : null)
      ?? this.users.findByStripeCustomerId(subscription.customerId);
    if (!user) throw new HttpError(422, "unknown_customer", `No user for Stripe customer ${subscription.customerId}.`);
    this.subscriptions.upsert(
      {
        id: subscription.id,
        userId: user.id,
        status,
        priceId: subscription.priceId,
        plan: this.catalog.planFor(subscription.priceId),
        currentPeriodEnd: subscription.currentPeriodEnd,
        cancelAtPeriodEnd: subscription.cancelAtPeriodEnd,
      },
      this.clock(),
    );
    this.audit.record({ actorUserId: null, action: "billing.subscription_synced", targetUserId: user.id, details: { status, subscriptionId: subscription.id } }, this.clock());
  }

  private async ensureCustomer(user: User): Promise<string> {
    if (user.stripeCustomerId) return user.stripeCustomerId;
    const customerId = await this.gateway.createCustomer(user.email, user.id);
    this.users.update(user.id, { stripeCustomerId: customerId }, this.clock());
    return customerId;
  }

  private requireConfigured(): void {
    if (!this.isConfigured) {
      throw new HttpError(503, "billing_not_configured", "Billing is not configured on this server.");
    }
  }
}
